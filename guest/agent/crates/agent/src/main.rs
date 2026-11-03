//! macvm-agent：在客户机内监听宿主连接，为宿主提供执行、端口转发、系统信息与管理操作。

// Windows 上由登录时的计划任务启动，不需要也不应弹出控制台窗口。
#![cfg_attr(windows, windows_subsystem = "windows")]

use macvm_agent_platform::{self as platform, Conn, ExecOptions, GuestCursor, SpawnedIo};
use macvm_agent_protocol::{self as proto, ExecRequest, ExitStatus, FrameKind, Info, Request, Response, WindowSize};
use std::fs::File;
use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

struct Config {
    port: u32,
    /// 未指定 `user` 的 exec 以该用户执行。
    default_user: Option<String>,
}

fn main() {
    let config = parse_args();
    let listener = match platform::Listener::bind(config.port) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("macvm-agent: 监听端口 {} 失败：{e}", config.port);
            std::process::exit(1);
        }
    };
    #[cfg(windows)]
    {
        platform::configure_hardware_cursor();
        platform::restore_system_cursors();
        platform::configure_rtc_utc();
        // 换显卡驱动要十几秒，不挡住监听；光标开关已按换之前的驱动设好，换上的驱动下次开机读到。
        std::thread::spawn(|| {
            if let Err(e) = platform::install_gpu_driver() {
                eprintln!("macvm-agent: 安装 3D 显卡驱动失败：{e}");
            }
        });
    }
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

fn serve(mut conn: Conn, config: &Config) -> io::Result<()> {
    let line = proto::read_line(&mut conn)?;
    let request: Request = match serde_json::from_slice(&line) {
        Ok(r) => r,
        Err(e) => return proto::write_json_line(&mut conn, &Response::error(format!("无法解析请求：{e}"))),
    };
    let reply = |conn: &mut Conn, result: io::Result<Response>| {
        let resp = result.unwrap_or_else(|e| Response::error(e.to_string()));
        proto::write_json_line(conn, &resp)
    };
    match request {
        Request::Info => reply(&mut conn, Ok(Response { info: Some(info()), ..Response::ok() })),
        Request::Shutdown { reboot } => {
            proto::write_json_line(&mut conn, &Response::ok())?;
            drop(conn);
            platform::shutdown(reboot)
        }
        Request::SetTime { unix_ms } => reply(&mut conn, platform::set_time(unix_ms).map(|_| Response::ok())),
        Request::ClipboardGet => reply(&mut conn, platform::clipboard_get().map(|text| Response { text: Some(text), ..Response::ok() })),
        Request::ClipboardSet { text } => reply(&mut conn, platform::clipboard_set(&text).map(|_| Response::ok())),
        Request::Mount { tag, path, read_only } => reply(&mut conn, platform::mount_virtiofs(&tag, &path, read_only).map(|_| Response::ok())),
        Request::Display { width, height } => reply(&mut conn, platform::set_display(width, height).map(|_| Response::ok())),
        Request::DisplayScale { percent } => reply(&mut conn, platform::set_display_scale(percent).map(|_| Response::ok())),
        Request::CursorWatch => watch_cursor(conn),
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
    let (mem_total, mem_available) = platform::memory();
    Info {
        version: env!("CARGO_PKG_VERSION").to_string(),
        os: platform::os_name().to_string(),
        hostname: platform::hostname(),
        ipv4: platform::ipv4_addresses(),
        mem_total,
        mem_available,
        uptime_ms: platform::uptime_ms(),
    }
}

/// 首个形状之前先回 ok；平台不支持时回错误。之后每行一个 `CursorShape`，宿主断开即结束。
fn watch_cursor(mut conn: Conn) -> io::Result<()> {
    // 宿主不在这条连接上发送，读到结束就是已断开；光标不变时没有写入，只能靠读发现。
    let closed = Arc::new(AtomicBool::new(false));
    let mut reader = conn.try_clone()?;
    let reader_closed = closed.clone();
    thread::spawn(move || {
        let mut buf = [0u8; 64];
        while matches!(reader.read(&mut buf), Ok(n) if n > 0) {}
        reader_closed.store(true, Ordering::Relaxed);
    });
    let mut started = false;
    let result = platform::watch_cursor(|| !closed.load(Ordering::Relaxed), |image| {
        if !started {
            proto::write_json_line(&mut conn, &Response::ok())?;
            started = true;
        }
        let shape = match image {
            GuestCursor::Hidden => proto::CursorShape { hidden: true, ..Default::default() },
            GuestCursor::System(kind) => proto::CursorShape { system: Some(kind.to_string()), ..Default::default() },
            GuestCursor::Image(i) => proto::CursorShape { width: i.width, height: i.height, hot_x: i.hot_x, hot_y: i.hot_y, bgra: proto::base64(&i.bgra), ..Default::default() },
        };
        proto::write_json_line(&mut conn, &shape)
    });
    let written = match result {
        Err(e) if !started => proto::write_json_line(&mut conn, &Response::error(e.to_string())),
        _ => Ok(()),
    };
    // 读线程还持有连接的克隆，只 drop 不会让宿主看到结束。
    platform::shutdown_write(&conn);
    written
}

fn forward(conn: Conn, tcp: TcpStream) -> io::Result<()> {
    let mut conn_read = conn.try_clone()?;
    let mut tcp_write = tcp.try_clone()?;
    let upstream = thread::spawn(move || {
        let _ = io::copy(&mut conn_read, &mut tcp_write);
        let _ = tcp_write.shutdown(std::net::Shutdown::Write);
    });
    let mut tcp_read = tcp;
    let mut conn_write = conn;
    let _ = io::copy(&mut tcp_read, &mut conn_write);
    // 上行线程还持有连接的克隆，只 drop 不会让宿主看到结束。
    platform::shutdown_write(&conn_write);
    drop(conn_write);
    let _ = upstream.join();
    Ok(())
}

fn run_exec(mut conn: Conn, req: ExecRequest, config: &Config) -> io::Result<()> {
    if req.argv.is_empty() {
        return proto::write_json_line(&mut conn, &Response::error("argv 为空"));
    }
    let env: Vec<(String, String)> = req.env.into_iter().collect();
    let options = ExecOptions {
        argv: &req.argv,
        cwd: req.cwd.as_deref(),
        env: &env,
        tty: req.tty.then(|| (req.cols.unwrap_or(80), req.rows.unwrap_or(24))),
        user: req.user.as_deref(),
        default_user: config.default_user.as_deref(),
    };
    let mut spawned = match platform::spawn(&options) {
        Ok(s) => s,
        Err(e) => return proto::write_json_line(&mut conn, &Response::error(format!("无法执行 {}：{e}", req.argv[0]))),
    };
    proto::write_json_line(&mut conn, &Response::ok())?;

    let writer = Arc::new(Mutex::new(conn.try_clone()?));
    let mut pumps = Vec::new();
    let mut input: Option<File>;
    let resize: Option<Box<dyn Fn(u16, u16) + Send + Sync>>;
    let is_pty;
    match spawned.io {
        SpawnedIo::Pty { input: pty_in, output, resize: r } => {
            pumps.push(pump_output(output, FrameKind::Stdout, writer.clone()));
            input = Some(pty_in);
            resize = Some(r);
            is_pty = true;
        }
        SpawnedIo::Pipes { stdin, stdout, stderr } => {
            pumps.push(pump_output(stdout, FrameKind::Stdout, writer.clone()));
            pumps.push(pump_output(stderr, FrameKind::Stderr, writer.clone()));
            input = Some(stdin);
            resize = None;
            is_pty = false;
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
                    // 终端没有半关闭，发送 EOT 让行规程向程序报告文件结束。
                    if is_pty {
                        if let Some(w) = input.as_mut() {
                            let _ = w.write_all(&[4]);
                        }
                    } else {
                        input = None;
                    }
                }
                FrameKind::Resize => {
                    if let (Some(r), Ok(size)) = (resize.as_ref(), serde_json::from_slice::<WindowSize>(&payload)) {
                        r(size.cols, size.rows);
                    }
                }
                _ => {}
            }
        }
    });

    let exit = spawned.child.wait()?;
    for p in pumps {
        let _ = p.join();
    }
    let status = ExitStatus { code: exit.code, signal: exit.signal };
    {
        let mut w = writer.lock().unwrap();
        proto::write_frame(&mut *w, FrameKind::Exit, &serde_json::to_vec(&status).map_err(io::Error::other)?)?;
        let _ = w.flush();
    }
    drop(writer);
    drop(input_thread);
    Ok(())
}

/// 把子进程输出转成帧。PTY 主端在子进程及其后代都退出后返回 EIO，视为结束。
fn pump_output(mut source: File, kind: FrameKind, writer: Arc<Mutex<Conn>>) -> thread::JoinHandle<()> {
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
