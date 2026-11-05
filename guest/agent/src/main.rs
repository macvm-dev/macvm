//! macvm-agent：在客户机内监听宿主连接，为宿主提供执行、端口转发、系统信息与管理操作。

// Windows 上由登录时的计划任务启动，不需要也不应弹出控制台窗口。
#![cfg_attr(windows, windows_subsystem = "windows")]

use macvm_agent_platform::{self as platform, Conn, ExecOptions, GuestCursor, Origin, SnapshotOptions, SpawnedIo};
use macvm_agent_protocol::{self as proto, ExecRequest, ExitStatus, FrameKind, Info, Request, Response, WindowSize};
use std::fs::File;
use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, mpsc};
use std::thread;
use std::time::{Duration, Instant};

struct Config {
    port: u32,
    /// 未指定 `user` 的 exec 以该用户执行。
    default_user: Option<String>,
}

fn main() {
    let config = parse_args();
    exe_sha256();
    let listener = match platform::Listener::bind(config.port) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("macvm-agent: 监听端口 {} 失败：{e}", config.port);
            std::process::exit(1);
        }
    };
    #[cfg(target_os = "linux")]
    std::thread::spawn(|| {
        if let Err(e) = platform::prepare_ui_input() {
            eprintln!("macvm-agent: 创建虚拟输入设备失败：{e}");
        }
    });
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
            Ok((conn, origin)) => {
                let config = config.clone();
                thread::spawn(move || {
                    if let Err(e) = serve(conn, origin, &config) {
                        eprintln!("macvm-agent: {e}");
                    }
                });
            }
            Err(e) => {
                eprintln!("macvm-agent: accept 失败：{e}");
                // fd 耗尽一类错误下连接仍留在队列里，监听立刻又就绪，不等一下就会空转刷屏。
                thread::sleep(ACCEPT_RETRY_DELAY);
            }
        }
    }
}

/// accept 出错后等这么久再重试。
const ACCEPT_RETRY_DELAY: Duration = Duration::from_millis(100);

fn parse_args() -> Config {
    let mut config = Config { port: proto::PORT, default_user: None };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--port" => config.port = args.next().and_then(|v| v.parse().ok()).unwrap_or(proto::PORT),
            "--user" => config.default_user = args.next(),
            // 同步写好显卡 udev 规则后退出，不监听。
            #[cfg(target_os = "linux")]
            "--ignore-firmware-framebuffer" => match platform::ignore_firmware_framebuffer() {
                Ok(()) => std::process::exit(0),
                Err(e) => {
                    eprintln!("macvm-agent: 写显卡 udev 规则失败：{e}");
                    std::process::exit(1);
                }
            },
            // 代理以图形会话用户身份运行的无障碍查询：标准输入一行请求，标准输出一行结果。
            #[cfg(target_os = "linux")]
            "--ui-helper" => std::process::exit(platform::run_ui_helper()),
            // 开机时以 SYSTEM 运行，在控制台会话里保持安全桌面助手。
            #[cfg(windows)]
            platform::DESKTOP_SUPERVISOR_ARG => std::process::exit(platform::run_desktop_supervisor()),
            // 安全桌面助手，参数是守护进程的 pid。
            #[cfg(windows)]
            platform::DESKTOP_HELPER_ARG => std::process::exit(serve_desktop_helper(args.next().and_then(|v| v.parse().ok()))),
            // 在新进程里查一项 TCC 授权，结果用退出码表示。
            #[cfg(target_os = "macos")]
            platform::UI_GRANT_ARG => std::process::exit(platform::run_ui_grant_check(&args.next().unwrap_or_default())),
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

/// 从发出质询起，认证要在这么久之内答完。
const AUTH_TIMEOUT: Duration = Duration::from_secs(10);

/// 以共享令牌 `token` 发质询、验应答，返回是否通过。
fn authenticate(conn: &mut Conn, token: &str) -> io::Result<bool> {
    let mut nonce = [0u8; proto::auth::CHALLENGE_BYTES];
    getrandom::fill(&mut nonce).map_err(|e| io::Error::other(format!("取随机数失败：{e}")))?;
    let challenge = proto::auth::hex(&nonce);
    let deadline = Instant::now() + AUTH_TIMEOUT;
    proto::write_json_line(conn, &proto::auth::Challenge { challenge: challenge.clone() })?;
    let line = read_answer_line(conn, deadline)?;
    let ok = serde_json::from_slice::<proto::auth::Answer>(&line).is_ok_and(|a| proto::auth::verify(token, &challenge, &a.auth));
    if !ok {
        proto::write_json_line(conn, &Response::error("认证失败"))?;
        return Ok(false);
    }
    platform::set_read_timeout(conn, None)?;
    Ok(true)
}

/// 应答行的长度上限，远大于 `{"auth":"<64 位十六进制>"}`。
const MAX_ANSWER: usize = 256;

/// 在 `deadline` 前读完应答行：每次读都按剩余时间设超时，对方逐字节慢慢发也占不住线程。
fn read_answer_line(conn: &mut Conn, deadline: Instant) -> io::Result<Vec<u8>> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "认证应答超时"));
        }
        // 零超时在 SO_RCVTIMEO 里表示不限时，Windows 上则直接报错。
        platform::set_read_timeout(conn, Some(left.max(Duration::from_millis(1))))?;
        if conn.read(&mut byte)? == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "连接在认证应答结束前关闭"));
        }
        if byte[0] == b'\n' {
            return Ok(line);
        }
        line.push(byte[0]);
        if line.len() > MAX_ANSWER {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "认证应答过长"));
        }
    }
}

/// 连接在读请求之前的处置。
#[derive(Debug, PartialEq, Eq)]
enum Admission {
    Accept,
    /// 以这个令牌发质询，答对才读请求。
    Challenge(String),
    /// 直接断开、不回应。
    Drop,
}

/// vsock 连接直接受理。TCP 连接在客户机里有令牌 `token` 时都要过质询：单凭来源认不出宿主；
/// 没有令牌时只受理来自默认网关的连接。
fn admission(origin: Origin, token: Option<String>) -> Admission {
    match (origin, token) {
        (Origin::Vsock, _) => Admission::Accept,
        (_, Some(token)) => Admission::Challenge(token),
        (Origin::Gateway, None) => Admission::Accept,
        (Origin::Network, None) => Admission::Drop,
    }
}

fn serve(mut conn: Conn, origin: Origin, config: &Config) -> io::Result<()> {
    let token = if origin == Origin::Vsock { None } else { platform::agent_token() };
    match admission(origin, token) {
        Admission::Accept => {}
        Admission::Challenge(token) => {
            if !authenticate(&mut conn, &token)? {
                return Ok(());
            }
        }
        Admission::Drop => return Ok(()),
    }
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
        Request::TrimCache { keep } => reply(&mut conn, platform::trim_page_cache(keep).map(|_| Response::ok())),
        Request::CursorWatch => watch_cursor(conn),
        Request::GpuDriver { sha256, size } => receive_gpu_driver(conn, &sha256, size),
        Request::Forward { port } => match TcpStream::connect(("127.0.0.1", port)) {
            Ok(tcp) => {
                tcp.set_nodelay(true).ok();
                proto::write_json_line(&mut conn, &Response::ok())?;
                forward(conn, tcp)
            }
            Err(e) => reply(&mut conn, Err(io::Error::new(e.kind(), format!("连接 127.0.0.1:{port} 失败：{e}")))),
        },
        Request::Exec(req) => run_exec(conn, req, config),
        #[cfg(windows)]
        ui if platform::ui_request_for_desktop_helper(&ui) => forward_to_desktop_helper(&mut conn, &ui),
        ui @ (Request::UiSnapshot { .. } | Request::UiAction { .. } | Request::UiInput { .. } | Request::UiScreenshot) => serve_ui(&mut conn, ui),
    }
}

/// 处理 `ui-*` 请求；其他请求回失败。
fn serve_ui(conn: &mut impl Write, request: Request) -> io::Result<()> {
    match request {
        Request::UiSnapshot { app, max_depth, max_nodes } => {
            let options = SnapshotOptions {
                app: app.as_deref(),
                max_depth: max_depth.unwrap_or(proto::DEFAULT_UI_DEPTH),
                max_nodes: max_nodes.unwrap_or(proto::DEFAULT_UI_NODES),
            };
            let body = platform::ui_snapshot(&options).and_then(|s| serde_json::to_vec(&s).map_err(io::Error::other));
            reply_body(conn, body)
        }
        Request::UiAction { element, action, value } => {
            let result = platform::ui_action(&element, action, value.as_deref()).map(|_| Response::ok());
            reply_ui(conn, result)
        }
        Request::UiInput { mut events } => {
            let result = resolve_clicks(&mut events).and_then(|_| platform::ui_input(&events)).map(|_| Response::ok());
            reply_ui(conn, result)
        }
        Request::UiScreenshot => reply_body(conn, platform::ui_screenshot()),
        _ => proto::write_json_line(conn, &Response::error("只受理 UI 请求")),
    }
}

/// 把请求原样交给安全桌面助手，再把它的响应原样交回宿主。
#[cfg(windows)]
fn forward_to_desktop_helper(conn: &mut Conn, request: &Request) -> io::Result<()> {
    let mut helper = match platform::connect_desktop_helper() {
        Ok(h) => h,
        Err(e) => return reply_ui(conn, Err(e)),
    };
    proto::write_json_line(&mut helper, request)?;
    io::copy(&mut helper, conn)?;
    Ok(())
}

/// 安全桌面助手：每个连接一个 UI 请求，在当时的输入桌面上处理。
#[cfg(windows)]
fn serve_desktop_helper(supervisor: Option<u32>) -> i32 {
    let Some(supervisor) = supervisor else {
        eprintln!("macvm-agent: {} 需要守护进程的 pid", platform::DESKTOP_HELPER_ARG);
        return 2;
    };
    if let Err(e) = platform::become_desktop_helper(supervisor) {
        eprintln!("macvm-agent: 找不到守护进程 {supervisor}：{e}");
        return 1;
    }
    let mut listener = match platform::DesktopHelperListener::bind() {
        Ok(l) => l,
        Err(e) => {
            eprintln!("macvm-agent: 建立桌面助手管道失败：{e}");
            return 1;
        }
    };
    loop {
        match listener.accept() {
            Ok(conn) => {
                thread::spawn(move || {
                    if let Err(e) = serve_desktop_request(conn) {
                        eprintln!("macvm-agent: {e}");
                    }
                });
            }
            Err(e) => {
                eprintln!("macvm-agent: 桌面助手 accept 失败：{e}");
                thread::sleep(ACCEPT_RETRY_DELAY);
            }
        }
    }
}

#[cfg(windows)]
fn serve_desktop_request(mut conn: platform::HelperConn) -> io::Result<()> {
    let line = proto::read_line(&mut conn)?;
    let request: Request = match serde_json::from_slice(&line) {
        Ok(r) => r,
        Err(e) => return proto::write_json_line(&mut conn, &Response::error(format!("无法解析请求：{e}"))),
    };
    let _desktop = match platform::enter_input_desktop() {
        Ok(d) => d,
        Err(e) => return proto::write_json_line(&mut conn, &Response::error(format!("切换到输入桌面失败：{e}"))),
    };
    serve_ui(&mut conn, request)
}

/// UI 请求的响应：权限不足时带上 `code`，宿主据此提示授权。
fn reply_ui(conn: &mut impl Write, result: io::Result<Response>) -> io::Result<()> {
    proto::write_json_line(conn, &result.unwrap_or_else(|e| Response::from_error(&e)))
}

fn reply_body(conn: &mut impl Write, body: io::Result<Vec<u8>>) -> io::Result<()> {
    match body {
        Ok(body) => proto::write_body(conn, &body),
        Err(e) => reply_ui(conn, Err(e)),
    }
}

/// 把按元素给出的点击换成元素中心的坐标。
fn resolve_clicks(events: &mut [proto::InputEvent]) -> io::Result<()> {
    for event in events {
        if let proto::InputEvent::Click { x, y, element: Some(id), .. } = event {
            let [left, top, width, height] = platform::ui_element_bounds(id)?;
            *x = Some(left + width / 2);
            *y = Some(top + height / 2);
        }
    }
    Ok(())
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
        features: vec![proto::FEATURE_UI.to_string()],
        exe_sha256: exe_sha256(),
    }
}

/// 本进程可执行文件的 SHA-256，`main` 启动时算出后缓存：更新时文件会先于进程被换掉，晚算会报出新文件的值。
fn exe_sha256() -> Option<String> {
    static HASH: OnceLock<Option<String>> = OnceLock::new();
    HASH.get_or_init(|| {
        use sha2::{Digest, Sha256};
        let bytes = std::fs::read(std::env::current_exe().ok()?).ok()?;
        Some(proto::auth::hex(&Sha256::digest(bytes)))
    })
    .clone()
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

/// 驱动包的大小上限，防止宿主传错长度时按它分配内存。
const MAX_GPU_DRIVER_PACKAGE: u64 = 256 << 20;

fn receive_gpu_driver(mut conn: Conn, sha256: &str, size: u64) -> io::Result<()> {
    let reply = |text: &str| Response { text: Some(text.to_string()), ..Response::ok() };
    if platform::gpu_driver_package_is(sha256) {
        return proto::write_json_line(&mut conn, &reply("current"));
    }
    if size > MAX_GPU_DRIVER_PACKAGE {
        return proto::write_json_line(&mut conn, &Response::error(format!("驱动包过大：{size} 字节")));
    }
    proto::write_json_line(&mut conn, &reply("send"))?;
    let mut zip = vec![0u8; size as usize];
    conn.read_exact(&mut zip)?;
    let result = platform::replace_gpu_driver(&zip, sha256).map(|changed| reply(if changed { "installed" } else { "unchanged" }));
    proto::write_json_line(&mut conn, &result.unwrap_or_else(|e| Response::error(e.to_string())))
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
    let input: File;
    let resize: Option<Box<dyn Fn(u16, u16) + Send + Sync>>;
    let is_pty;
    match spawned.io {
        SpawnedIo::Pty { input: pty_in, output, resize: r } => {
            pumps.push(pump_output(output, FrameKind::Stdout, writer.clone()));
            input = pty_in;
            resize = Some(r);
            is_pty = true;
        }
        SpawnedIo::Pipes { stdin, stdout, stderr } => {
            pumps.push(pump_output(stdout, FrameKind::Stdout, writer.clone()));
            pumps.push(pump_output(stderr, FrameKind::Stderr, writer.clone()));
            input = stdin;
            resize = None;
            is_pty = false;
        }
    }

    let hangup = spawned.child.hangup().ok();
    let stdin = spawn_stdin_writer(input, is_pty);
    // 宿主输入：在独立线程读帧，连接关闭使它结束。宿主收到 exit 帧之前不关连接，所以那之前读到结束就是宿主已断开：
    // 挂断子进程，否则不读不写的子进程会连同输出泵一直留着。
    let mut reader = conn;
    let input_thread = thread::spawn(move || {
        while let Ok(Some((kind, payload))) = proto::read_frame(&mut reader) {
            match kind {
                FrameKind::Stdin => {
                    if !forward_stdin(&stdin, &reader, StdinChunk::Data(payload)) {
                        break;
                    }
                }
                FrameKind::StdinEof => {
                    if !forward_stdin(&stdin, &reader, StdinChunk::Eof) {
                        break;
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
        if let Some(hangup) = hangup {
            hangup();
        }
    });

    let exit = spawned.child.wait()?;
    for p in pumps {
        let _ = p.join();
    }
    // 先释放子进程再发 exit 帧：宿主收到后关连接，输入线程随即调用的挂断函数此时已不起作用，不会误伤留在后台的进程。
    drop(spawned.child);
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

enum StdinChunk {
    Data(Vec<u8>),
    Eof,
}

/// 在独立线程把宿主输入写给子进程：子进程不读输入时写会阻塞，读帧的线程不能因此察觉不到宿主断开。
/// 写失败后丢弃之后的输入。
fn spawn_stdin_writer(input: File, is_pty: bool) -> mpsc::SyncSender<StdinChunk> {
    let (tx, rx) = mpsc::sync_channel::<StdinChunk>(STDIN_QUEUE);
    thread::spawn(move || {
        let mut input = Some(input);
        for chunk in rx {
            match chunk {
                StdinChunk::Data(data) => {
                    if let Some(w) = input.as_mut()
                        && w.write_all(&data).is_err()
                    {
                        input = None;
                    }
                }
                // 终端没有半关闭，发送 EOT 让行规程向程序报告文件结束。
                StdinChunk::Eof if is_pty => {
                    if let Some(w) = input.as_mut() {
                        let _ = w.write_all(&[4]);
                    }
                }
                StdinChunk::Eof => input = None,
            }
        }
    });
    tx
}

/// 写 stdin 的线程积压的输入块上限；积满时读帧的线程停下来，宿主那端随之受阻。
const STDIN_QUEUE: usize = 16;

/// 交给写 stdin 的线程；队列满时等它腾出位置，其间宿主断开则返回 false。
/// 等待间隔从短到长：子进程读得比宿主送得慢时，腾出位置后要尽快补上，吞吐才不被等待间隔卡住。
fn forward_stdin(stdin: &mpsc::SyncSender<StdinChunk>, conn: &Conn, mut chunk: StdinChunk) -> bool {
    let mut pause = Duration::from_millis(1);
    loop {
        match stdin.try_send(chunk) {
            Ok(()) | Err(mpsc::TrySendError::Disconnected(_)) => return true,
            Err(mpsc::TrySendError::Full(back)) => {
                if platform::peer_closed(conn) {
                    return false;
                }
                chunk = back;
                thread::sleep(pause);
                pause = (pause * 2).min(STDIN_MAX_PAUSE);
            }
        }
    }
}

/// 队列满时两次检查之间最长的间隔，也是宿主断开后最晚多久察觉。
const STDIN_MAX_PAUSE: Duration = Duration::from_millis(100);

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn admission_policy() {
        let token = || Some("t".to_string());
        assert_eq!(admission(Origin::Vsock, None), Admission::Accept);
        assert_eq!(admission(Origin::Vsock, token()), Admission::Accept);
        assert_eq!(admission(Origin::Gateway, token()), Admission::Challenge("t".to_string()));
        assert_eq!(admission(Origin::Network, token()), Admission::Challenge("t".to_string()));
        assert_eq!(admission(Origin::Gateway, None), Admission::Accept);
        assert_eq!(admission(Origin::Network, None), Admission::Drop);
    }

    #[cfg(unix)]
    fn socket_pair() -> (Conn, std::os::unix::net::UnixStream) {
        let (conn, peer) = std::os::unix::net::UnixStream::pair().unwrap();
        (File::from(std::os::fd::OwnedFd::from(conn)), peer)
    }

    #[cfg(unix)]
    #[test]
    fn answer_line_stops_at_newline() {
        let (mut conn, mut peer) = socket_pair();
        peer.write_all(b"{\"auth\":\"ab\"}\n{\"op\":\"info\"}\n").unwrap();
        let line = read_answer_line(&mut conn, Instant::now() + Duration::from_secs(5)).unwrap();
        assert_eq!(line, b"{\"auth\":\"ab\"}");
        assert_eq!(proto::read_line(&mut conn).unwrap(), b"{\"op\":\"info\"}");
    }

    #[cfg(unix)]
    #[test]
    fn answer_line_rejects_long_line() {
        let (mut conn, mut peer) = socket_pair();
        peer.write_all(&[b'a'; MAX_ANSWER + 1]).unwrap();
        let err = read_answer_line(&mut conn, Instant::now() + Duration::from_secs(5)).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[cfg(unix)]
    #[test]
    fn answer_line_gives_up_at_deadline() {
        let (mut conn, _peer) = socket_pair();
        let started = Instant::now();
        assert!(read_answer_line(&mut conn, started + Duration::from_millis(50)).is_err());
        assert!(started.elapsed() < Duration::from_secs(5));
        let err = read_answer_line(&mut conn, started).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::TimedOut);
    }
}
