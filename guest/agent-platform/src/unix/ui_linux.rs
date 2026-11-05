//! Linux：无障碍树经 AT-SPI 读取，输入经 uinput，截屏经 DRM。
//! 代理是 root 系统服务，连不上用户的会话总线与无障碍总线（EXTERNAL 认证要 uid 相同），
//! 所以 AT-SPI 部分在以图形会话用户身份运行的子进程（`--ui-helper`）里做，一次请求一个子进程。
//! 元素编号是 AT-SPI 对象的总线名加路径，跨请求有效，到应用销毁该对象为止。
//! Wayland 下应用不知道自己窗口在屏幕上的位置，报的坐标相对窗口，所以只有 GNOME Shell 自己的界面给出 `bounds`。
//! shortcut: Wayland 下其他应用的元素没有屏幕坐标，GNOME 向辅助技术提供窗口位置后再补上。

use super::dbus::{Bus, Value};
use super::session::graphical_sessions;
use super::{drm, uinput};
use crate::{SNAPSHOT_BUDGET, SnapshotOptions};
use macvm_agent_protocol::{ElementAction, InputEvent, UiApp, UiNode, UiScreen, UiSnapshot, UiState};
use serde::{Deserialize, Serialize};
use std::io::{self, BufRead, Read, Write};
use std::process::{Command, Stdio};
use std::time::Instant;

pub fn ui_snapshot(options: &SnapshotOptions) -> io::Result<UiSnapshot> {
    let request = HelperRequest::Snapshot { app: options.app.map(str::to_owned), max_depth: options.max_depth, max_nodes: options.max_nodes };
    let mut snapshot = helper(&request)?.snapshot.unwrap_or_default();
    let (width, height) = drm::screen_size().unwrap_or_default();
    // 缩放倍数由会话里的 helper 读出。
    let scale = if snapshot.screen.scale > 0.0 { snapshot.screen.scale } else { 1.0 };
    snapshot.screen = UiScreen { width, height, scale };
    Ok(snapshot)
}

pub fn ui_action(element: &str, action: ElementAction, value: Option<&str>) -> io::Result<()> {
    helper(&HelperRequest::Action { element: element.into(), action, value: value.map(str::to_owned) }).map(|_| ())
}

pub fn ui_element_bounds(element: &str) -> io::Result<[i32; 4]> {
    helper(&HelperRequest::Bounds { element: element.into() })?
        .bounds
        .ok_or_else(|| io::Error::new(io::ErrorKind::Unsupported, format!("元素 {element} 没有位置")))
}

pub fn ui_input(events: &[InputEvent]) -> io::Result<()> {
    uinput::play(drm::screen_size()?, events)
}

/// 代理启动时建好输入用的虚拟设备。
pub fn prepare_ui_input() -> io::Result<()> {
    uinput::prepare()
}

pub fn ui_screenshot() -> io::Result<Vec<u8>> {
    let frame = drm::capture()?;
    crate::encode_png(frame.width, frame.height, &frame.rgb)
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
enum HelperRequest {
    Snapshot { app: Option<String>, max_depth: u32, max_nodes: u32 },
    Action { element: String, action: ElementAction, value: Option<String> },
    Bounds { element: String },
}

#[derive(Serialize, Deserialize, Default)]
struct HelperReply {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    /// 失败的 `io::ErrorKind`，只区分宿主要分开处理的几种。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    snapshot: Option<UiSnapshot>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    bounds: Option<[i32; 4]>,
}

fn kind_name(kind: io::ErrorKind) -> Option<&'static str> {
    Some(match kind {
        io::ErrorKind::NotFound => "not-found",
        io::ErrorKind::PermissionDenied => "permission",
        io::ErrorKind::Unsupported => "unsupported",
        io::ErrorKind::InvalidInput => "invalid-input",
        _ => return None,
    })
}

fn kind_from(name: Option<&str>) -> io::ErrorKind {
    match name {
        Some("not-found") => io::ErrorKind::NotFound,
        Some("permission") => io::ErrorKind::PermissionDenied,
        Some("unsupported") => io::ErrorKind::Unsupported,
        Some("invalid-input") => io::ErrorKind::InvalidInput,
        _ => io::ErrorKind::Other,
    }
}

/// 以前台图形会话的用户身份运行 `--ui-helper`。
fn helper(request: &HelperRequest) -> io::Result<HelperReply> {
    let sessions = graphical_sessions();
    let session = sessions
        .iter()
        .find(|s| s.active)
        .or(sessions.first())
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "客户机没有已登录的图形会话"))?;
    let exe = std::env::current_exe()?;
    let mut child = Command::new("runuser")
        .args(["-u", &session.user, "--", "env"])
        .args(session.bus_env())
        .arg(exe)
        .arg("--ui-helper")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut line = serde_json::to_vec(request).map_err(io::Error::other)?;
    line.push(b'\n');
    // 读写出错也要等子进程退出，不留僵尸进程。
    let mut out = Vec::new();
    let exchanged = child
        .stdin
        .take()
        .expect("piped")
        .write_all(&line)
        .and_then(|_| child.stdout.take().expect("piped").read_to_end(&mut out));
    let status = child.wait()?;
    exchanged?;
    let reply: HelperReply = serde_json::from_slice(&out)
        .map_err(|_| io::Error::other(format!("无障碍查询子进程异常退出（{status}）")))?;
    match reply.error {
        Some(message) => Err(io::Error::new(kind_from(reply.kind.as_deref()), message)),
        None => Ok(reply),
    }
}

/// `--ui-helper` 的入口：读一行请求，写一行结果，返回进程退出码。
pub fn run_ui_helper() -> i32 {
    let mut line = String::new();
    let result = io::stdin()
        .lock()
        .read_line(&mut line)
        .and_then(|_| serde_json::from_str::<HelperRequest>(&line).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e)))
        .and_then(|request| handle(&request));
    let reply = result.unwrap_or_else(|e| HelperReply {
        error: Some(e.to_string()),
        kind: kind_name(e.kind()).map(str::to_owned),
        ..Default::default()
    });
    let mut out = io::stdout().lock();
    let written = serde_json::to_writer(&mut out, &reply).map_err(io::Error::other).and_then(|_| out.write_all(b"\n"));
    if written.is_ok() { 0 } else { 1 }
}

fn handle(request: &HelperRequest) -> io::Result<HelperReply> {
    let mut atspi = Atspi::connect()?;
    Ok(match request {
        HelperRequest::Snapshot { app, max_depth, max_nodes } => {
            let mut snapshot = atspi.snapshot(app.as_deref(), *max_depth, *max_nodes)?;
            snapshot.screen.scale = atspi.scale;
            HelperReply { snapshot: Some(snapshot), ..Default::default() }
        }
        HelperRequest::Action { element, action, value } => {
            atspi.act(&Obj::parse(element)?, *action, value.as_deref())?;
            HelperReply::default()
        }
        HelperRequest::Bounds { element } => {
            let obj = Obj::parse(element)?;
            if !atspi.screen_coordinates(&obj.bus) {
                return Err(io::Error::new(
                    io::ErrorKind::Unsupported,
                    "Wayland 下应用不知道窗口在屏幕上的位置，拿不到元素坐标：改用 ui act，或按截图上的坐标点击",
                ));
            }
            HelperReply { bounds: atspi.extents(&obj)?, ..Default::default() }
        }
    })
}

/// mutter 主逻辑显示器的缩放倍数，取自 `org.gnome.Mutter.DisplayConfig.GetCurrentState`：
/// 返回值的第三项是逻辑显示器数组，每项为 (x, y, scale, transform, primary, monitors, properties)；
/// 第四项是全局属性，`layout-mode` 为 2（物理布局）时 mutter 的坐标本来就是像素，倍数按 1 算。
fn primary_monitor_scale(session: &mut Bus) -> Option<f64> {
    let reply = session
        .call("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig", "org.gnome.Mutter.DisplayConfig", "GetCurrentState", &[])
        .ok()?;
    let physical = reply.get(3).is_some_and(|properties| {
        properties.items().iter().any(|p| p.items().first().and_then(Value::str) == Some("layout-mode") && p.items().get(1).and_then(Value::int) == Some(2))
    });
    if physical {
        return Some(1.0);
    }
    let monitors = reply.get(2)?.items();
    let primary = monitors.iter().find(|m| matches!(m.items().get(4), Some(Value::Bool(true)))).or(monitors.first())?;
    primary.items().get(2)?.float().filter(|s| *s > 0.0)
}

/// 一个 AT-SPI 对象：所在应用的总线名与对象路径。
#[derive(Clone)]
struct Obj {
    bus: String,
    path: String,
}

const NULL_PATH: &str = "/org/a11y/atspi/null";
const ACCESSIBLE: &str = "org.a11y.atspi.Accessible";
const COMPONENT: &str = "org.a11y.atspi.Component";
const ACTION: &str = "org.a11y.atspi.Action";
const VALUE: &str = "org.a11y.atspi.Value";
const TEXT: &str = "org.a11y.atspi.Text";
const EDITABLE_TEXT: &str = "org.a11y.atspi.EditableText";
const SELECTION: &str = "org.a11y.atspi.Selection";
/// `AtspiCoordType` 的屏幕坐标。
const COORD_SCREEN: u32 = 0;
/// `AtspiScrollType` 的「滚到可见即可」。
const SCROLL_ANYWHERE: u32 = 6;
/// 文本元素的 `value` 最多取这么多字符。
const MAX_VALUE_CHARS: i32 = 2000;

impl Obj {
    fn id(&self) -> String {
        format!("{}{}", self.bus, self.path)
    }

    fn parse(id: &str) -> io::Result<Self> {
        let slash = id.find('/').filter(|&i| i > 0).ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("元素编号无效：{id}")))?;
        Ok(Self { bus: id[..slash].into(), path: id[slash..].into() })
    }

    fn from_value(v: &Value) -> Option<Self> {
        let [bus, path] = v.items() else { return None };
        let (bus, path) = (bus.str()?, path.str()?);
        (path != NULL_PATH && !bus.is_empty()).then(|| Self { bus: bus.into(), path: path.into() })
    }
}

/// `AtspiStateType` 中用到的位。
mod state {
    pub const ACTIVE: u32 = 1;
    pub const CHECKED: u32 = 4;
    pub const DEFUNCT: u32 = 6;
    pub const EDITABLE: u32 = 7;
    pub const ENABLED: u32 = 8;
    pub const EXPANDABLE: u32 = 9;
    pub const EXPANDED: u32 = 10;
    pub const FOCUSABLE: u32 = 11;
    pub const FOCUSED: u32 = 12;
    pub const PRESSED: u32 = 20;
    pub const SELECTABLE: u32 = 22;
    pub const SELECTED: u32 = 23;
    pub const SENSITIVE: u32 = 24;
    pub const SHOWING: u32 = 25;
}

struct States([u32; 2]);

impl States {
    fn has(&self, bit: u32) -> bool {
        self.0.get(bit as usize / 32).is_some_and(|w| w >> (bit % 32) & 1 == 1)
    }
}

/// 按名字认动作：键是 AT-SPI 动作名（小写），值是归一后的动作。
const ACTION_NAMES: [(&str, ElementAction); 10] = [
    ("click", ElementAction::Press),
    ("press", ElementAction::Press),
    ("activate", ElementAction::Press),
    ("jump", ElementAction::Press),
    ("open", ElementAction::Press),
    ("toggle", ElementAction::Toggle),
    ("expand or contract", ElementAction::Expand),
    ("expand or collapse", ElementAction::Expand),
    ("showmenu", ElementAction::ShowMenu),
    ("menu", ElementAction::ShowMenu),
];

struct Atspi {
    bus: Bus,
    wayland: bool,
    /// Wayland 下 AT-SPI 报逻辑坐标，乘上主显示器的缩放倍数才是截图像素。
    scale: f64,
}

/// 每个应用的根对象路径。
const ROOT_PATH: &str = "/org/a11y/atspi/accessible/root";

impl Atspi {
    /// 打开会话的无障碍支持（at-spi 把它同步进 gsettings，之后启动的应用都会导出无障碍树），再连上无障碍总线。
    fn connect() -> io::Result<Self> {
        let address = std::env::var("DBUS_SESSION_BUS_ADDRESS").map_err(|_| io::Error::new(io::ErrorKind::NotFound, "没有会话总线地址"))?;
        let mut session = Bus::connect(&address)?;
        let _ = session.call(
            "org.a11y.Bus",
            "/org/a11y/bus",
            "org.freedesktop.DBus.Properties",
            "Set",
            &[Value::Str("org.a11y.Status".into()), Value::Str("IsEnabled".into()), Value::Variant(Box::new(Value::Bool(true)))],
        );
        let reply = session.call("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress", &[])?;
        let a11y = reply.first().and_then(Value::str).ok_or_else(|| io::Error::other("无障碍总线没有地址"))?;
        let wayland = std::env::var("XDG_SESSION_TYPE").is_ok_and(|t| t == "wayland");
        let scale = if wayland { primary_monitor_scale(&mut session).unwrap_or(1.0) } else { 1.0 };
        Ok(Self { bus: Bus::connect(a11y)?, wayland, scale })
    }

    /// 总线名为 `bus` 的应用报的坐标是否是屏幕坐标。
    fn screen_coordinates(&mut self, bus: &str) -> bool {
        !self.wayland || self.name(&Obj { bus: bus.into(), path: ROOT_PATH.into() }).as_deref() == Some("gnome-shell")
    }

    fn call(&mut self, obj: &Obj, interface: &str, member: &str, args: &[Value]) -> io::Result<Vec<Value>> {
        self.bus.call(&obj.bus, &obj.path, interface, member, args)
    }

    fn first(&mut self, obj: &Obj, interface: &str, member: &str, args: &[Value]) -> io::Result<Value> {
        self.call(obj, interface, member, args)?.into_iter().next().ok_or_else(|| io::Error::other(format!("{member} 没有返回值")))
    }

    fn children(&mut self, obj: &Obj) -> io::Result<Vec<Obj>> {
        Ok(self.first(obj, ACCESSIBLE, "GetChildren", &[])?.items().iter().filter_map(Obj::from_value).collect())
    }

    fn states(&mut self, obj: &Obj) -> io::Result<States> {
        let words = self.first(obj, ACCESSIBLE, "GetState", &[])?;
        let mut out = [0u32; 2];
        for (slot, w) in out.iter_mut().zip(words.items()) {
            *slot = w.int().unwrap_or(0) as u32;
        }
        Ok(States(out))
    }

    fn name(&mut self, obj: &Obj) -> Option<String> {
        self.bus.property(&obj.bus, &obj.path, ACCESSIBLE, "Name").ok()?.str().map(str::to_owned).filter(|s| !s.is_empty())
    }

    fn interfaces(&mut self, obj: &Obj) -> Vec<String> {
        self.first(obj, ACCESSIBLE, "GetInterfaces", &[])
            .map(|v| v.items().iter().filter_map(|i| i.str().map(str::to_owned)).collect())
            .unwrap_or_default()
    }

    fn extents(&mut self, obj: &Obj) -> io::Result<Option<[i32; 4]>> {
        let rect = self.first(obj, COMPONENT, "GetExtents", &[Value::U32(COORD_SCREEN)])?;
        let v: Vec<i32> = rect.items().iter().filter_map(|n| n.int().map(|n| n as i32)).collect();
        let px = |n: i32| (f64::from(n) * self.scale).round() as i32;
        Ok(match v[..] {
            [x, y, w, h] if w > 0 && h > 0 => Some([px(x), px(y), px(w), px(h)]),
            _ => None,
        })
    }

    fn action_names(&mut self, obj: &Obj) -> Vec<String> {
        self.first(obj, ACTION, "GetActions", &[])
            .map(|v| v.items().iter().filter_map(|a| a.items().first()?.str().map(str::to_lowercase)).collect())
            .unwrap_or_default()
    }

    /// 有窗口的应用，及其对象。
    fn apps(&mut self) -> io::Result<Vec<(Obj, UiApp)>> {
        let root = Obj { bus: "org.a11y.atspi.Registry".into(), path: ROOT_PATH.into() };
        let mut apps = Vec::new();
        for app in self.children(&root)? {
            let Ok(windows) = self.children(&app) else { continue };
            if windows.is_empty() {
                continue;
            }
            let frontmost = windows.iter().any(|w| self.states(w).is_ok_and(|s| s.has(state::ACTIVE)));
            let pid = self
                .bus
                .call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID", &[Value::Str(app.bus.clone())])
                .ok()
                .and_then(|r| r.first()?.int())
                .unwrap_or(0) as u32;
            let name = self.name(&app).or_else(|| process_name(pid)).unwrap_or_default();
            apps.push((app, UiApp { pid, name, bundle: None, frontmost }));
        }
        Ok(apps)
    }

    fn snapshot(&mut self, query: Option<&str>, max_depth: u32, max_nodes: u32) -> io::Result<UiSnapshot> {
        let apps = self.apps()?;
        let target = match query {
            Some(q) => Some(find_app(&apps, q)?),
            None => apps.iter().find(|(_, a)| a.frontmost).cloned(),
        };
        let mut snapshot = UiSnapshot { apps: apps.iter().map(|(_, a)| a.clone()).collect(), ..Default::default() };
        let Some((root, app)) = target else { return Ok(snapshot) };
        snapshot.app = Some(app);
        let absolute = self.screen_coordinates(&root.bus);
        let mut stack = vec![(root, 0u32)];
        let started = Instant::now();
        while let Some((obj, depth)) = stack.pop() {
            if snapshot.nodes.len() >= max_nodes as usize || started.elapsed() > SNAPSHOT_BUDGET {
                snapshot.truncated = true;
                break;
            }
            let Ok(states) = self.states(&obj) else { continue };
            if states.has(state::DEFUNCT) {
                continue;
            }
            snapshot.nodes.push(self.describe(&obj, depth, &states, absolute));
            let children = self.children(&obj).unwrap_or_default();
            if !children.is_empty() {
                if depth >= max_depth {
                    snapshot.truncated = true;
                } else {
                    stack.extend(children.into_iter().rev().map(|c| (c, depth + 1)));
                }
            }
        }
        Ok(snapshot)
    }

    /// `absolute` 为假时应用报的是相对窗口的坐标，不给 `bounds`。
    fn describe(&mut self, obj: &Obj, depth: u32, states: &States, absolute: bool) -> UiNode {
        let role = self.first(obj, ACCESSIBLE, "GetRoleName", &[]).ok().and_then(|v| v.str().map(str::to_owned)).unwrap_or_else(|| "unknown".into());
        let description = self.bus.property(&obj.bus, &obj.path, ACCESSIBLE, "Description").ok().and_then(|v| v.str().map(str::to_owned)).filter(|s| !s.is_empty());
        let interfaces = self.interfaces(obj);
        let has = |name: &str| interfaces.iter().any(|i| i == name);
        let bounds = if absolute && has(COMPONENT) { self.extents(obj).ok().flatten() } else { None };
        let value = if has(VALUE) {
            self.bus.property(&obj.bus, &obj.path, VALUE, "CurrentValue").ok().and_then(|v| v.float()).map(|n| n.to_string())
        } else if has(TEXT) && (states.has(state::EDITABLE) || has(EDITABLE_TEXT)) {
            self.first(obj, TEXT, "GetText", &[Value::I32(0), Value::I32(MAX_VALUE_CHARS)]).ok().and_then(|v| v.str().map(str::to_owned))
        } else {
            None
        };

        let mut node_states = Vec::new();
        for (bit, s) in [(state::FOCUSED, UiState::Focused), (state::SELECTED, UiState::Selected), (state::EXPANDED, UiState::Expanded)] {
            if states.has(bit) {
                node_states.push(s);
            }
        }
        // 应用对象等不报任何状态，这时不据缺位推断不可用或不可见。
        let reported = states.0 != [0, 0];
        // GTK4 只用 SENSITIVE 表示可用。
        if reported && !states.has(state::ENABLED) && !states.has(state::SENSITIVE) {
            node_states.push(UiState::Disabled);
        }
        if states.has(state::CHECKED) || states.has(state::PRESSED) {
            node_states.push(UiState::Checked);
        }
        if reported && !states.has(state::SHOWING) {
            node_states.push(UiState::Offscreen);
        }

        let mut actions = Vec::new();
        let mut add = |a: ElementAction| {
            if !actions.contains(&a) {
                actions.push(a);
            }
        };
        if has(ACTION) {
            for name in self.action_names(obj) {
                if let Some((_, a)) = ACTION_NAMES.iter().find(|(n, _)| *n == name) {
                    add(*a);
                    if *a == ElementAction::Expand {
                        add(ElementAction::Collapse);
                    }
                }
            }
        }
        if has(COMPONENT) && states.has(state::FOCUSABLE) {
            add(ElementAction::Focus);
        }
        if has(EDITABLE_TEXT) || has(VALUE) {
            add(ElementAction::SetValue);
        }
        if states.has(state::SELECTABLE) {
            add(ElementAction::Select);
        }
        if states.has(state::EXPANDABLE) {
            add(ElementAction::Expand);
            add(ElementAction::Collapse);
        }

        UiNode {
            id: obj.id(),
            depth,
            role,
            subrole: None,
            name: self.name(obj),
            value,
            description,
            bounds,
            states: node_states,
            actions,
        }
    }

    fn do_named(&mut self, obj: &Obj, names: &[&str]) -> io::Result<()> {
        let available = self.action_names(obj);
        let index = names
            .iter()
            .find_map(|n| available.iter().position(|a| a == n))
            .ok_or_else(|| io::Error::new(io::ErrorKind::Unsupported, format!("元素 {} 没有动作 {}", obj.id(), names[0])))?;
        self.call(obj, ACTION, "DoAction", &[Value::I32(index as i32)]).map(|_| ())
    }

    fn act(&mut self, obj: &Obj, action: ElementAction, value: Option<&str>) -> io::Result<()> {
        match action {
            ElementAction::Press => self.do_named(obj, &["click", "press", "activate", "jump", "open", "toggle"]),
            ElementAction::Toggle => self.do_named(obj, &["toggle", "click", "press", "activate"]),
            ElementAction::ShowMenu => self.do_named(obj, &["showmenu", "menu"]),
            ElementAction::Expand | ElementAction::Collapse => {
                if self.states(obj)?.has(state::EXPANDED) == (action == ElementAction::Expand) {
                    return Ok(());
                }
                self.do_named(obj, &["expand or contract", "expand or collapse", action.name(), "toggle", "activate", "click"])
            }
            ElementAction::Focus | ElementAction::Raise => self.call(obj, COMPONENT, "GrabFocus", &[]).map(|_| ()),
            ElementAction::ScrollIntoView => self.call(obj, COMPONENT, "ScrollTo", &[Value::U32(SCROLL_ANYWHERE)]).map(|_| ()),
            ElementAction::Select => {
                let parent = self.bus.property(&obj.bus, &obj.path, ACCESSIBLE, "Parent").ok().and_then(|v| Obj::from_value(&v));
                let index = self.first(obj, ACCESSIBLE, "GetIndexInParent", &[])?.int().unwrap_or(-1);
                match parent {
                    Some(parent) if index >= 0 && self.interfaces(&parent).iter().any(|i| i == SELECTION) => {
                        self.call(&parent, SELECTION, "SelectChild", &[Value::I32(index as i32)]).map(|_| ())
                    }
                    _ => self.do_named(obj, &["select", "click", "activate"]),
                }
            }
            ElementAction::SetValue => {
                let value = value.ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "set-value 需要 value"))?;
                let interfaces = self.interfaces(obj);
                if interfaces.iter().any(|i| i == EDITABLE_TEXT) {
                    self.call(obj, EDITABLE_TEXT, "SetTextContents", &[Value::Str(value.into())]).map(|_| ())
                } else if interfaces.iter().any(|i| i == VALUE) {
                    let n: f64 = value.parse().map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, format!("这个元素的值是数字：{value}")))?;
                    self.call(
                        obj,
                        "org.freedesktop.DBus.Properties",
                        "Set",
                        &[Value::Str(VALUE.into()), Value::Str("CurrentValue".into()), Value::Variant(Box::new(Value::F64(n)))],
                    )
                    .map(|_| ())
                } else {
                    Err(io::Error::new(io::ErrorKind::Unsupported, format!("元素 {} 不能设值", obj.id())))
                }
            }
        }
        .map_err(|e| if e.kind() == io::ErrorKind::NotFound { crate::stale_element(&obj.id()) } else { e })
    }
}

fn process_name(pid: u32) -> Option<String> {
    (pid > 0).then(|| std::fs::read_to_string(format!("/proc/{pid}/comm")).ok()).flatten().map(|s| s.trim().to_owned())
}

/// 按 pid、无障碍名称或进程名（不区分大小写）找应用。
fn find_app(apps: &[(Obj, UiApp)], query: &str) -> io::Result<(Obj, UiApp)> {
    let pid = query.parse::<u32>().ok();
    apps.iter()
        .find(|(_, a)| Some(a.pid) == pid || a.name.eq_ignore_ascii_case(query) || process_name(a.pid).is_some_and(|n| n.eq_ignore_ascii_case(query)))
        .cloned()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("没有找到带窗口的应用 {query}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn element_ids_round_trip() {
        let obj = Obj::parse(":1.42/org/a11y/atspi/accessible/17").unwrap();
        assert_eq!((obj.bus.as_str(), obj.path.as_str()), (":1.42", "/org/a11y/atspi/accessible/17"));
        assert_eq!(obj.id(), ":1.42/org/a11y/atspi/accessible/17");
        assert!(Obj::parse("3.17").is_err());
    }

    #[test]
    fn state_bits_span_two_words() {
        let s = States([1 << state::FOCUSED, 1 << (35 - 32)]);
        assert!(s.has(state::FOCUSED));
        assert!(s.has(35));
        assert!(!s.has(state::ENABLED));
    }
}
