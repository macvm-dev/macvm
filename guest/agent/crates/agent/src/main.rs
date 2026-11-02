//! macvm-agent：在客户机内监听 vsock，为宿主提供执行、端口转发、系统信息与管理操作。

use macvm_agent_platform::{exec, system, vsock};
use macvm_agent_protocol::{self as proto, ExecRequest, ExitStatus, FrameKind, Info, Request, Response, WindowSize};
use std::fs::File;
use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::sync::{Arc, Mutex};
use std::thread;

struct Config {
    port: u32,
    /// 未指定 `user` 的 exec 以该用户执行。
    default_user: Option<String>,
}

fn main() {
    let config = parse_args();
    let listener = match vsock::Listener::bind(config.port) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("macvm-agent: 监听 vsock 端口 {} 失败：{e}", config.port);
            std::process::exit(1);
        }
    };
    let config = Arc::new(config);
    loop {
        match listener.accept() {
            Ok(conn) => {
                let config = config.clone();
                thread::spawn(move || {
                    if let Err(e) = serve(conn, &config) {
                        eprintln!("macvm-agent: {e}");
                    }
                });
            }
            Err(e) => eprintln!("macvm-agent: accept 失败：{e}"),
        }
    }
}

fn parse_args() -> Config {
    let mut config = Config { port: proto::PORT, default_user: None };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--port" => config.port = args.next().and_then(|v| v.parse().ok()).unwrap_or(proto::PORT),
            "--user" => config.default_user = args.next(),
            "--version" => {
                println!("{}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            other => {
                eprintln!("macvm-agent: 未知参数 {other}");
                std::process::exit(2);
            }
        }
    }
    config
}

fn serve(mut conn: File, config: &Config) -> io::Result<()> {
    let line = proto::read_line(&mut conn)?;
    let request: Request = match serde_json::from_slice(&line) {
        Ok(r) => r,
        Err(e) => return proto::write_json_line(&mut conn, &Response::error(format!("无法解析请求：{e}"))),
    };
    let reply = |conn: &mut File, result: io::Result<Response>| {
        let resp = result.unwrap_or_else(|e| Response::error(e.to_string()));
        proto::write_json_line(conn, &resp)
    };
    match request {
        Request::Info => reply(&mut conn, Ok(Response { info: Some(info()), ..Response::ok() })),
        Request::Shutdown { reboot } => {
            proto::write_json_line(&mut conn, &Response::ok())?;
            drop(conn);
            system::shutdown(reboot)
        }
        Request::SetTime { unix_ms } => reply(&mut conn, system::set_time(unix_ms).map(|_| Response::ok())),
        Request::ClipboardGet => reply(&mut conn, system::clipboard_get().map(|text| Response { text: Some(text), ..Response::ok() })),
        Request::ClipboardSet { text } => reply(&mut conn, system::clipboard_set(&text).map(|_| Response::ok())),
        Request::Mount { tag, path, read_only } => reply(&mut conn, system::mount_virtiofs(&tag, &path, read_only).map(|_| Response::ok())),
        Request::Forward { port } => match TcpStream::connect(("127.0.0.1", port)) {
            Ok(tcp) => {
                tcp.set_nodelay(true).ok();
                proto::write_json_line(&mut conn, &Response::ok())?;
                forward(conn, tcp)
            }
            Err(e) => reply(&mut conn, Err(io::Error::new(e.kind(), format!("连接 127.0.0.1:{port} 失败：{e}")))),
        },
        Request::Exec(req) => run_exec(conn, req, config),
    }
}

fn info() -> Info {
    let (mem_total, mem_available) = system::memory();
    Info {
        version: env!("CARGO_PKG_VERSION").to_string(),
        os: system::os_name().to_string(),
        hostname: system::hostname(),
        ipv4: system::ipv4_addresses(),
        mem_total,
        mem_available,
        uptime_ms: system::uptime_ms(),
    }
}

fn forward(conn: File, tcp: TcpStream) -> io::Result<()> {
    let mut conn_read = conn.try_clone()?;
    let mut tcp_write = tcp.try_clone()?;
    let upstream = thread::spawn(move || {
        let _ = io::copy(&mut conn_read, &mut tcp_write);
        let _ = tcp_write.shutdown(std::net::Shutdown::Write);
    });
    let mut tcp_read = tcp;
    let mut conn_write = conn;
    let _ = io::copy(&mut tcp_read, &mut conn_write);
    drop(conn_write);
    let _ = upstream.join();
    Ok(())
}

fn run_exec(mut conn: File, req: ExecRequest, config: &Config) -> io::Result<()> {
    if req.argv.is_empty() {
        return proto::write_json_line(&mut conn, &Response::error("argv 为空"));
    }
    let root = system::is_root();
    let identity = match req.user.as_deref().or(config.default_user.as_deref()) {
        Some(name) if root => exec::Identity::lookup(name),
        Some(name) => exec::Identity::current().and_then(|me| {
            if me.name == name { Ok(me) } else { Err(io::Error::new(io::ErrorKind::PermissionDenied, format!("代理不是 root，无法以 {name} 执行"))) }
        }),
        None => exec::Identity::current(),
    };
    let identity = match identity {
        Ok(id) => id,
        Err(e) => return proto::write_json_line(&mut conn, &Response::error(e.to_string())),
    };
    let env: Vec<(String, String)> = req.env.into_iter().collect();
    let tty = req.tty.then(|| (req.cols.unwrap_or(80), req.rows.unwrap_or(24)));
    let spawned = exec::spawn(exec::Options {
        argv: &req.argv,
        cwd: req.cwd.as_deref(),
        env: &env,
        tty,
        identity: &identity,
        switch_user: root && identity.uid != 0,
    });
    let mut spawned = match spawned {
        Ok(s) => s,
        Err(e) => return proto::write_json_line(&mut conn, &Response::error(format!("无法执行 {}：{e}", req.argv[0]))),
    };
    proto::write_json_line(&mut conn, &Response::ok())?;

    let writer = Arc::new(Mutex::new(conn.try_clone()?));
    let mut pumps = Vec::new();
    let mut input: Option<File>;
    let pty: Option<File>;
    match spawned.io {
        exec::SpawnedIo::Pty(master) => {
            pumps.push(pump_output(master.try_clone()?, FrameKind::Stdout, writer.clone()));
            input = Some(master.try_clone()?);
            pty = Some(master);
        }
        exec::SpawnedIo::Pipes { stdin, stdout, stderr } => {
            pumps.push(pump_output(stdout, FrameKind::Stdout, writer.clone()));
            pumps.push(pump_output(stderr, FrameKind::Stderr, writer.clone()));
            input = Some(stdin);
            pty = None;
        }
    }

    // 宿主输入：在独立线程读帧，子进程退出后连接关闭使它结束。
    let mut reader = conn;
    let input_thread = thread::spawn(move || {
        while let Ok(Some((kind, payload))) = proto::read_frame(&mut reader) {
            match kind {
                FrameKind::Stdin => {
                    if let Some(w) = input.as_mut() {
                        if w.write_all(&payload).is_err() {
                            input = None;
                        }
                    }
                }
                FrameKind::StdinEof => {
                    // PTY 没有半关闭，发送 EOT 让行规程向程序报告文件结束。
                    if pty.is_some() {
                        if let Some(w) = input.as_mut() {
                            let _ = w.write_all(&[4]);
                        }
                    } else {
                        input = None;
                    }
                }
                FrameKind::Resize => {
                    if let (Some(p), Ok(size)) = (pty.as_ref(), serde_json::from_slice::<WindowSize>(&payload)) {
                        exec::resize(p, size.cols, size.rows);
                    }
                }
                _ => {}
            }
        }
    });

    let status = spawned.child.wait()?;
    for p in pumps {
        let _ = p.join();
    }
    let exit = exit_status(status);
    {
        let mut w = writer.lock().unwrap();
        proto::write_frame(&mut *w, FrameKind::Exit, &serde_json::to_vec(&exit).map_err(io::Error::other)?)?;
        let _ = w.flush();
    }
    drop(writer);
    drop(input_thread);
    Ok(())
}

/// 把子进程输出转成帧。PTY 主端在子进程及其后代都退出后返回 EIO，视为结束。
fn pump_output(mut source: File, kind: FrameKind, writer: Arc<Mutex<File>>) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            match source.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let mut w = writer.lock().unwrap();
                    if proto::write_frame(&mut *w, kind, &buf[..n]).is_err() {
                        break;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
    })
}

fn exit_status(status: std::process::ExitStatus) -> ExitStatus {
    use std::os::unix::process::ExitStatusExt;
    match (status.code(), status.signal()) {
        (Some(code), _) => ExitStatus { code, signal: None },
        (None, Some(sig)) => ExitStatus { code: 128 + sig, signal: Some(sig) },
        _ => ExitStatus { code: 1, signal: None },
    }
}
