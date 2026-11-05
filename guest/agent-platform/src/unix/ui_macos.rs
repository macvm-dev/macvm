//! macOS：经 AX 读无障碍树、执行动作，经 CGEvent 注入输入，用 screencapture 截屏。
//! AX 与 CGEvent 都要求代理有「辅助功能」授权，截屏要求「屏幕录制」授权；授权跟着代理 App 的代码签名。

use crate::input::{self, Injector, Key};
use crate::{SnapshotOptions, stale_element};
use macvm_agent_protocol::{ElementAction, InputEvent, MouseButton, UiApp, UiNode, UiScreen, UiSnapshot, UiState};
use std::ffi::{c_char, c_void};
use std::io;
use std::process::Command;
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

type CFTypeRef = *const c_void;
type CFIndex = isize;
type CFTypeID = usize;
type AXError = i32;

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct CGPoint {
    x: f64,
    y: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct CGSize {
    width: f64,
    height: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct CGRect {
    origin: CGPoint,
    size: CGSize,
}

#[repr(C)]
struct Opaque {
    _private: [u8; 0],
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(cf: CFTypeRef);
    fn CFRetain(cf: CFTypeRef) -> CFTypeRef;
    fn CFGetTypeID(cf: CFTypeRef) -> CFTypeID;
    fn CFStringGetTypeID() -> CFTypeID;
    fn CFNumberGetTypeID() -> CFTypeID;
    fn CFBooleanGetTypeID() -> CFTypeID;
    fn CFArrayGetTypeID() -> CFTypeID;
    fn CFStringCreateWithBytes(alloc: CFTypeRef, bytes: *const u8, len: CFIndex, encoding: u32, external: u8) -> CFTypeRef;
    fn CFStringGetLength(s: CFTypeRef) -> CFIndex;
    fn CFStringGetMaximumSizeForEncoding(len: CFIndex, encoding: u32) -> CFIndex;
    fn CFStringGetCString(s: CFTypeRef, buf: *mut c_char, size: CFIndex, encoding: u32) -> u8;
    fn CFArrayCreate(alloc: CFTypeRef, values: *const CFTypeRef, count: CFIndex, callbacks: *const Opaque) -> CFTypeRef;
    fn CFArrayGetCount(a: CFTypeRef) -> CFIndex;
    fn CFArrayGetValueAtIndex(a: CFTypeRef, i: CFIndex) -> CFTypeRef;
    fn CFDictionaryCreate(
        alloc: CFTypeRef,
        keys: *const CFTypeRef,
        values: *const CFTypeRef,
        count: CFIndex,
        key_callbacks: *const Opaque,
        value_callbacks: *const Opaque,
    ) -> CFTypeRef;
    fn CFDictionaryGetValue(d: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
    fn CFNumberGetValue(n: CFTypeRef, kind: CFIndex, out: *mut c_void) -> u8;
    fn CFBooleanGetValue(b: CFTypeRef) -> u8;
    fn CFURLCreateFromFileSystemRepresentation(alloc: CFTypeRef, path: *const u8, len: CFIndex, is_dir: u8) -> CFTypeRef;
    fn CFBundleCreate(alloc: CFTypeRef, url: CFTypeRef) -> CFTypeRef;
    fn CFBundleGetIdentifier(bundle: CFTypeRef) -> CFTypeRef;
    static kCFTypeArrayCallBacks: Opaque;
    static kCFTypeDictionaryKeyCallBacks: Opaque;
    static kCFTypeDictionaryValueCallBacks: Opaque;
    static kCFBooleanTrue: CFTypeRef;
    static kCFBooleanFalse: CFTypeRef;
}

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXIsProcessTrustedWithOptions(options: CFTypeRef) -> u8;
    static kAXTrustedCheckOptionPrompt: CFTypeRef;
    fn AXUIElementCreateSystemWide() -> CFTypeRef;
    fn AXUIElementCreateApplication(pid: i32) -> CFTypeRef;
    fn AXUIElementCopyAttributeValue(element: CFTypeRef, attribute: CFTypeRef, value: *mut CFTypeRef) -> AXError;
    fn AXUIElementCopyMultipleAttributeValues(element: CFTypeRef, attributes: CFTypeRef, options: u32, values: *mut CFTypeRef) -> AXError;
    fn AXUIElementCopyActionNames(element: CFTypeRef, names: *mut CFTypeRef) -> AXError;
    fn AXUIElementPerformAction(element: CFTypeRef, action: CFTypeRef) -> AXError;
    fn AXUIElementSetAttributeValue(element: CFTypeRef, attribute: CFTypeRef, value: CFTypeRef) -> AXError;
    fn AXUIElementSetMessagingTimeout(element: CFTypeRef, seconds: f32) -> AXError;
    fn AXUIElementGetPid(element: CFTypeRef, pid: *mut i32) -> AXError;
    fn AXValueGetTypeID() -> CFTypeID;
    fn AXValueGetType(value: CFTypeRef) -> u32;
    fn AXValueGetValue(value: CFTypeRef, kind: u32, out: *mut c_void) -> u8;
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGMainDisplayID() -> u32;
    fn CGDisplayBounds(display: u32) -> CGRect;
    fn CGDisplayCopyDisplayMode(display: u32) -> CFTypeRef;
    fn CGDisplayModeGetPixelWidth(mode: CFTypeRef) -> usize;
    fn CGDisplayModeGetWidth(mode: CFTypeRef) -> usize;
    fn CGEventCreateMouseEvent(source: CFTypeRef, kind: u32, at: CGPoint, button: u32) -> CFTypeRef;
    fn CGEventCreateKeyboardEvent(source: CFTypeRef, keycode: u16, down: bool) -> CFTypeRef;
    fn CGEventCreateScrollWheelEvent2(source: CFTypeRef, units: u32, wheels: u32, wheel1: i32, wheel2: i32, wheel3: i32) -> CFTypeRef;
    fn CGEventPost(tap: u32, event: CFTypeRef);
    fn CGEventSetIntegerValueField(event: CFTypeRef, field: u32, value: i64);
    fn CGEventSetFlags(event: CFTypeRef, flags: u64);
    fn CGEventKeyboardSetUnicodeString(event: CFTypeRef, len: usize, chars: *const u16);
    fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) -> CFTypeRef;
    static kCGWindowOwnerPID: CFTypeRef;
    static kCGWindowOwnerName: CFTypeRef;
    static kCGWindowLayer: CFTypeRef;
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGRequestScreenCaptureAccess() -> bool;
}

const UTF8: u32 = 0x0800_0100;
const NUMBER_SINT64: CFIndex = 4;
const NUMBER_FLOAT64: CFIndex = 13;
const AX_VALUE_POINT: u32 = 1;
const AX_VALUE_SIZE: u32 = 2;
const AX_VALUE_ERROR: u32 = 5;
const AX_ERROR_ILLEGAL_ARGUMENT: AXError = -25201;
const AX_ERROR_INVALID_ELEMENT: AXError = -25202;
const AX_ERROR_CANNOT_COMPLETE: AXError = -25204;
const AX_ERROR_ATTRIBUTE_UNSUPPORTED: AXError = -25205;
const AX_ERROR_ACTION_UNSUPPORTED: AXError = -25206;
const AX_ERROR_API_DISABLED: AXError = -25211;
const AX_ERROR_NO_VALUE: AXError = -25212;
const WINDOW_LIST_ON_SCREEN: u32 = 1;
const WINDOW_LIST_EXCLUDE_DESKTOP: u32 = 1 << 4;
const HID_EVENT_TAP: u32 = 0;
const SCROLL_UNIT_LINE: u32 = 1;
const MOUSE_EVENT_CLICK_STATE: u32 = 1;

/// 一个持有的 CF 对象，析构时释放。
struct Cf(CFTypeRef);

// SAFETY: 这里持有的 CF 对象（字符串、数组、AXUIElement）创建后不再改动，CF 的引用计数是线程安全的。
unsafe impl Send for Cf {}

impl Cf {
    /// 接管 Create/Copy 规则返回的对象；空指针返回 None。
    fn own(cf: CFTypeRef) -> Option<Self> {
        (!cf.is_null()).then_some(Self(cf))
    }

    /// 持有 Get 规则拿到的对象。
    fn retain(cf: CFTypeRef) -> Option<Self> {
        // SAFETY: cf 非空，是有效的 CF 对象。
        (!cf.is_null()).then(|| Self(unsafe { CFRetain(cf) }))
    }

    fn str(s: &str) -> Self {
        // SAFETY: 按 UTF-8 字节创建字符串，失败时返回空指针，下面兜底为空串。
        let cf = unsafe { CFStringCreateWithBytes(std::ptr::null(), s.as_ptr(), s.len() as CFIndex, UTF8, 0) };
        Self::own(cf).unwrap_or_else(|| Self::str(""))
    }

    fn array(items: &[&Cf]) -> Self {
        let raw: Vec<CFTypeRef> = items.iter().map(|c| c.0).collect();
        // SAFETY: raw 里都是有效的 CF 对象，数组按 CF 规则持有它们。
        Self(unsafe { CFArrayCreate(std::ptr::null(), raw.as_ptr(), raw.len() as CFIndex, &kCFTypeArrayCallBacks) })
    }
}

impl Clone for Cf {
    fn clone(&self) -> Self {
        Self::retain(self.0).expect("非空")
    }
}

impl Drop for Cf {
    fn drop(&mut self) {
        // SAFETY: self.0 是本对象持有的一个引用。
        unsafe { CFRelease(self.0) }
    }
}

fn is_type(cf: CFTypeRef, id: CFTypeID) -> bool {
    // SAFETY: cf 非空时是有效 CF 对象。
    !cf.is_null() && unsafe { CFGetTypeID(cf) } == id
}

fn string(cf: CFTypeRef) -> Option<String> {
    // SAFETY: 先确认是 CFString，再按 UTF-8 最大长度分配缓冲取出。
    unsafe {
        if !is_type(cf, CFStringGetTypeID()) {
            return None;
        }
        let size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(cf), UTF8) + 1;
        let mut buf = vec![0u8; size as usize];
        if CFStringGetCString(cf, buf.as_mut_ptr() as *mut c_char, size, UTF8) == 0 {
            return None;
        }
        let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
        buf.truncate(end);
        String::from_utf8(buf).ok()
    }
}

fn number(cf: CFTypeRef) -> Option<f64> {
    let mut out = 0f64;
    // SAFETY: 先确认是 CFNumber，按双精度取值。
    (is_type(cf, unsafe { CFNumberGetTypeID() }) && unsafe { CFNumberGetValue(cf, NUMBER_FLOAT64, &mut out as *mut f64 as *mut c_void) } != 0)
        .then_some(out)
}

fn integer(cf: CFTypeRef) -> Option<i64> {
    let mut out = 0i64;
    // SAFETY: 先确认是 CFNumber，按 64 位整数取值。
    (is_type(cf, unsafe { CFNumberGetTypeID() }) && unsafe { CFNumberGetValue(cf, NUMBER_SINT64, &mut out as *mut i64 as *mut c_void) } != 0)
        .then_some(out)
}

fn boolean(cf: CFTypeRef) -> Option<bool> {
    // SAFETY: CFBoolean 直接取值；数字按非零算真（AXValue 的勾选状态是 0/1）。
    if is_type(cf, unsafe { CFBooleanGetTypeID() }) {
        return Some(unsafe { CFBooleanGetValue(cf) } != 0);
    }
    integer(cf).map(|n| n != 0)
}

/// CFArray 里的元素（Get 规则，不持有）。
fn items(cf: CFTypeRef) -> Vec<CFTypeRef> {
    // SAFETY: 先确认是 CFArray，下标在长度内。
    unsafe {
        if !is_type(cf, CFArrayGetTypeID()) {
            return Vec::new();
        }
        (0..CFArrayGetCount(cf)).map(|i| CFArrayGetValueAtIndex(cf, i)).collect()
    }
}

/// AXValue 里的点或尺寸；不是这种值时返回 None。
fn ax_value<T: Default>(cf: CFTypeRef, kind: u32) -> Option<T> {
    let mut out = T::default();
    // SAFETY: 先确认是 AXValue 且类型匹配，再按 T 的布局取出。
    unsafe {
        if !is_type(cf, AXValueGetTypeID()) || AXValueGetType(cf) != kind {
            return None;
        }
        (AXValueGetValue(cf, kind, &mut out as *mut T as *mut c_void) != 0).then_some(out)
    }
}

/// `AXUIElementCopyMultipleAttributeValues` 里缺失的属性是 AXError 类型的 AXValue。
fn present(cf: CFTypeRef) -> Option<CFTypeRef> {
    // SAFETY: 只读取类型。
    let missing = cf.is_null() || (is_type(cf, unsafe { AXValueGetTypeID() }) && unsafe { AXValueGetType(cf) } == AX_VALUE_ERROR);
    (!missing).then_some(cf)
}

fn permission_error() -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, "MacVM Agent 没有辅助功能权限：在客户机「系统设置 › 隐私与安全性 › 辅助功能」里允许 MacVM Agent 后重试")
}

/// 检查辅助功能授权；没有时让系统弹出授权提示。
fn require_trust() -> io::Result<()> {
    // SAFETY: 用系统提供的键与 kCFBooleanTrue 建一个字典传给 AXIsProcessTrustedWithOptions。
    let trusted = unsafe {
        let keys = [kAXTrustedCheckOptionPrompt];
        let values = [kCFBooleanTrue];
        let options = Cf::own(CFDictionaryCreate(
            std::ptr::null(),
            keys.as_ptr(),
            values.as_ptr(),
            1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        ));
        AXIsProcessTrustedWithOptions(options.as_ref().map_or(std::ptr::null(), |o| o.0)) != 0
    };
    if !trusted {
        return Err(permission_error());
    }
    limit_messaging();
    Ok(())
}

fn ax_result(code: AXError, what: &str, id: &str) -> io::Result<()> {
    match code {
        0 => Ok(()),
        AX_ERROR_API_DISABLED => Err(permission_error()),
        AX_ERROR_INVALID_ELEMENT => Err(stale_element(id)),
        AX_ERROR_ATTRIBUTE_UNSUPPORTED | AX_ERROR_ACTION_UNSUPPORTED | AX_ERROR_NO_VALUE | AX_ERROR_ILLEGAL_ARGUMENT => {
            Err(io::Error::new(io::ErrorKind::Unsupported, format!("元素 {id} 不支持 {what}")))
        }
        AX_ERROR_CANNOT_COMPLETE => Err(io::Error::new(io::ErrorKind::TimedOut, format!("应用没有响应 {what}"))),
        other => Err(io::Error::other(format!("{what} 失败：AXError {other}"))),
    }
}

fn copy_attribute(element: &Cf, name: &str) -> Option<Cf> {
    let mut out: CFTypeRef = std::ptr::null();
    // SAFETY: element 是 AXUIElement，成功时 out 按 Copy 规则归我们持有。
    let code = unsafe { AXUIElementCopyAttributeValue(element.0, Cf::str(name).0, &mut out) };
    if code == 0 { Cf::own(out) } else { None }
}

fn set_attribute(element: &Cf, name: &str, value: CFTypeRef, id: &str) -> io::Result<()> {
    // SAFETY: element 是 AXUIElement，value 是有效 CF 对象。
    ax_result(unsafe { AXUIElementSetAttributeValue(element.0, Cf::str(name).0, value) }, name, id)
}

fn perform(element: &Cf, action: &str, id: &str) -> io::Result<()> {
    // SAFETY: element 是 AXUIElement。
    ax_result(unsafe { AXUIElementPerformAction(element.0, Cf::str(action).0) }, action, id)
}

/// 主屏的点坐标范围与每点像素数。
struct Screen {
    points: CGRect,
    scale: f64,
}

impl Screen {
    fn main() -> Self {
        // SAFETY: 查询主屏；显示模式按 Copy 规则持有后释放。
        unsafe {
            let display = CGMainDisplayID();
            let points = CGDisplayBounds(display);
            let scale = Cf::own(CGDisplayCopyDisplayMode(display))
                .map(|mode| {
                    let (pixels, width) = (CGDisplayModeGetPixelWidth(mode.0), CGDisplayModeGetWidth(mode.0));
                    if width > 0 { pixels as f64 / width as f64 } else { 1.0 }
                })
                .unwrap_or(1.0);
            Self { points, scale }
        }
    }

    fn info(&self) -> UiScreen {
        UiScreen {
            width: (self.points.size.width * self.scale).round() as u32,
            height: (self.points.size.height * self.scale).round() as u32,
            scale: self.scale,
        }
    }

    fn to_points(&self, x: i32, y: i32) -> CGPoint {
        CGPoint { x: f64::from(x) / self.scale, y: f64::from(y) / self.scale }
    }

    fn to_pixels(&self, origin: CGPoint, size: CGSize) -> [i32; 4] {
        let px = |v: f64| (v * self.scale).round() as i32;
        [px(origin.x), px(origin.y), px(size.width), px(size.height)]
    }
}

/// 最近一次快照的元素，下标即编号里 `.` 之后的部分。
struct Cache {
    generation: u32,
    elements: Vec<Cf>,
}

static CACHE: Mutex<Cache> = Mutex::new(Cache { generation: 0, elements: Vec::new() });

fn lookup(id: &str) -> io::Result<Cf> {
    let cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    let (generation, index) = id.split_once('.').ok_or_else(|| stale_element(id))?;
    if generation.parse::<u32>().ok() != Some(cache.generation) {
        return Err(stale_element(id));
    }
    index.parse::<usize>().ok().and_then(|i| cache.elements.get(i)).cloned().ok_or_else(|| stale_element(id))
}

/// 本进程每次 AX 调用等应用回应的最长时间，避免卡在没有响应的应用上。
const MESSAGING_TIMEOUT: f32 = 2.0;

/// 把 `MESSAGING_TIMEOUT` 设在系统级元素上：只有这样才对本进程的所有元素生效。
fn limit_messaging() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        // SAFETY: 系统级元素按 Create 规则持有。
        if let Some(system) = Cf::own(unsafe { AXUIElementCreateSystemWide() }) {
            // SAFETY: system 是 AXUIElement。
            unsafe { AXUIElementSetMessagingTimeout(system.0, MESSAGING_TIMEOUT) };
        }
    });
}
/// 元素的 `value` 最多保留这么多字符（文本区可能是整篇文档）。
const MAX_VALUE_CHARS: usize = 2000;

const ATTRIBUTES: [&str; 13] = [
    "AXRole",
    "AXSubrole",
    "AXTitle",
    "AXDescription",
    "AXValue",
    "AXPosition",
    "AXSize",
    "AXFocused",
    "AXEnabled",
    "AXSelected",
    "AXExpanded",
    "AXDisclosing",
    "AXChildren",
];

/// 可编辑文本的角色：提供聚焦与设值。
const TEXT_ROLES: [&str; 3] = ["AXTextField", "AXTextArea", "AXComboBox"];
/// 带勾选状态、`AXValue` 是 0/1 的角色。
const CHECK_ROLES: [&str; 3] = ["AXCheckBox", "AXRadioButton", "AXMenuItemCheckbox"];
/// 可选中的行与单元格。
const SELECT_ROLES: [&str; 3] = ["AXRow", "AXCell", "AXTab"];

pub fn ui_snapshot(options: &SnapshotOptions) -> io::Result<UiSnapshot> {
    require_trust()?;
    let screen = Screen::main();
    let frontmost = frontmost_pid();
    let mut apps = running_apps();
    for app in &mut apps {
        app.frontmost = Some(app.pid) == frontmost;
    }
    let target = match options.app {
        Some(query) => Some(find_app(&apps, query)?),
        None => frontmost.map(|pid| apps.iter().find(|a| a.pid == pid).cloned().unwrap_or_else(|| describe_app(pid, true))),
    };
    let mut snapshot = UiSnapshot { screen: screen.info(), apps, app: target.clone(), ..Default::default() };
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    cache.generation = cache.generation.wrapping_add(1);
    cache.elements.clear();
    let Some(app) = target else { return Ok(snapshot) };
    // SAFETY: 为 pid 创建应用元素，按 Create 规则持有。
    let root = Cf::own(unsafe { AXUIElementCreateApplication(app.pid as i32) }).ok_or_else(|| io::Error::other("创建应用元素失败"))?;
    let names: Vec<Cf> = ATTRIBUTES.iter().map(|n| Cf::str(n)).collect();
    let attributes = Cf::array(&names.iter().collect::<Vec<_>>());
    let generation = cache.generation;
    let mut stack = vec![(root, 0u32)];
    let started = std::time::Instant::now();
    while let Some((element, depth)) = stack.pop() {
        if snapshot.nodes.len() >= options.max_nodes as usize || started.elapsed() > crate::SNAPSHOT_BUDGET {
            snapshot.truncated = true;
            break;
        }
        let mut values: CFTypeRef = std::ptr::null();
        // SAFETY: element 是 AXUIElement，attributes 是属性名数组，成功时 values 归我们持有。
        let code = unsafe { AXUIElementCopyMultipleAttributeValues(element.0, attributes.0, 0, &mut values) };
        if code == AX_ERROR_API_DISABLED {
            return Err(permission_error());
        }
        let Some(values) = (code == 0).then(|| Cf::own(values)).flatten() else { continue };
        let values = items(values.0);
        let attr = |name: &str| ATTRIBUTES.iter().position(|a| *a == name).and_then(|i| values.get(i).copied()).and_then(present);
        let id = format!("{generation}.{}", cache.elements.len());
        let node = describe(&element, &id, depth, &attr, &screen);
        let children = attr("AXChildren").map(items).unwrap_or_default();
        if !children.is_empty() {
            if depth >= options.max_depth {
                snapshot.truncated = true;
            } else {
                stack.extend(children.into_iter().rev().filter_map(Cf::retain).map(|c| (c, depth + 1)));
            }
        }
        cache.elements.push(element);
        snapshot.nodes.push(node);
    }
    Ok(snapshot)
}

fn describe(element: &Cf, id: &str, depth: u32, attr: &dyn Fn(&str) -> Option<CFTypeRef>, screen: &Screen) -> UiNode {
    let text = |name: &str| attr(name).and_then(string).filter(|s| !s.is_empty());
    let flag = |name: &str| attr(name).and_then(boolean);
    let role = text("AXRole").unwrap_or_else(|| "AXUnknown".into());
    let title = text("AXTitle");
    let description = text("AXDescription");
    let (name, description) = match title {
        Some(t) => (Some(t), description),
        None => (description, None),
    };
    let checkable = CHECK_ROLES.contains(&role.as_str());
    let raw_value = attr("AXValue");
    let value = if checkable {
        None
    } else {
        raw_value.and_then(|v| string(v).or_else(|| number(v).map(format_number))).map(|v| v.chars().take(MAX_VALUE_CHARS).collect())
    };
    let bounds = match (attr("AXPosition").and_then(|v| ax_value::<CGPoint>(v, AX_VALUE_POINT)), attr("AXSize").and_then(|v| ax_value::<CGSize>(v, AX_VALUE_SIZE))) {
        (Some(origin), Some(size)) => Some((origin, size)),
        _ => None,
    };

    let mut states = Vec::new();
    if flag("AXFocused") == Some(true) {
        states.push(UiState::Focused);
    }
    if flag("AXEnabled") == Some(false) {
        states.push(UiState::Disabled);
    }
    if flag("AXSelected") == Some(true) {
        states.push(UiState::Selected);
    }
    if checkable && raw_value.and_then(boolean) == Some(true) {
        states.push(UiState::Checked);
    }
    let expanded = flag("AXExpanded").or_else(|| flag("AXDisclosing"));
    if expanded == Some(true) {
        states.push(UiState::Expanded);
    }
    if let Some((origin, size)) = bounds {
        let p = screen.points;
        let outside = origin.x + size.width <= p.origin.x
            || origin.y + size.height <= p.origin.y
            || origin.x >= p.origin.x + p.size.width
            || origin.y >= p.origin.y + p.size.height;
        if outside {
            states.push(UiState::Offscreen);
        }
    }

    let mut actions = Vec::new();
    for action in action_names(element) {
        let mapped = match action.as_str() {
            "AXPress" => ElementAction::Press,
            "AXShowMenu" => ElementAction::ShowMenu,
            "AXRaise" => ElementAction::Raise,
            "AXScrollToVisible" => ElementAction::ScrollIntoView,
            _ => continue,
        };
        if !actions.contains(&mapped) {
            actions.push(mapped);
        }
    }
    if TEXT_ROLES.contains(&role.as_str()) {
        actions.extend([ElementAction::Focus, ElementAction::SetValue]);
    }
    if expanded.is_some() {
        actions.extend([ElementAction::Expand, ElementAction::Collapse]);
    }
    if SELECT_ROLES.contains(&role.as_str()) {
        actions.push(ElementAction::Select);
    }

    UiNode {
        id: id.to_string(),
        depth,
        role,
        subrole: text("AXSubrole"),
        name,
        value,
        description,
        bounds: bounds.map(|(origin, size)| screen.to_pixels(origin, size)),
        states,
        actions,
    }
}

fn format_number(n: f64) -> String {
    if n.fract() == 0.0 && n.abs() < 1e15 { format!("{}", n as i64) } else { n.to_string() }
}

fn action_names(element: &Cf) -> Vec<String> {
    let mut names: CFTypeRef = std::ptr::null();
    // SAFETY: element 是 AXUIElement，成功时 names 归我们持有。
    if unsafe { AXUIElementCopyActionNames(element.0, &mut names) } != 0 {
        return Vec::new();
    }
    Cf::own(names).map(|n| items(n.0).into_iter().filter_map(string).collect()).unwrap_or_default()
}

fn frontmost_pid() -> Option<u32> {
    // SAFETY: 系统级元素按 Create 规则持有；取它的焦点应用再读 pid。
    unsafe {
        let system = Cf::own(AXUIElementCreateSystemWide())?;
        let app = copy_attribute(&system, "AXFocusedApplication")?;
        let mut pid = 0;
        (AXUIElementGetPid(app.0, &mut pid) == 0 && pid > 0).then_some(pid as u32)
    }
}

/// 在屏幕上有普通窗口（layer 0）的应用，按窗口次序去重。读取属主不需要屏幕录制授权。
fn running_apps() -> Vec<UiApp> {
    // SAFETY: 窗口列表按 Copy 规则持有；字典与其中的值按 Get 规则读取。
    let Some(windows) = (unsafe { Cf::own(CGWindowListCopyWindowInfo(WINDOW_LIST_ON_SCREEN | WINDOW_LIST_EXCLUDE_DESKTOP, 0)) }) else {
        return Vec::new();
    };
    let mut apps: Vec<UiApp> = Vec::new();
    for window in items(windows.0) {
        // SAFETY: window 是窗口信息字典，键是系统常量。
        let (layer, pid, name) = unsafe {
            (
                integer(CFDictionaryGetValue(window, kCGWindowLayer)),
                integer(CFDictionaryGetValue(window, kCGWindowOwnerPID)),
                string(CFDictionaryGetValue(window, kCGWindowOwnerName)),
            )
        };
        let (Some(0), Some(pid)) = (layer, pid) else { continue };
        let pid = pid as u32;
        if apps.iter().all(|a| a.pid != pid) {
            apps.push(UiApp { pid, name: name.unwrap_or_default(), bundle: bundle_id(pid), frontmost: false });
        }
    }
    apps
}

fn describe_app(pid: u32, frontmost: bool) -> UiApp {
    let path = process_path(pid);
    let name = path.as_deref().and_then(|p| p.rsplit('/').next()).unwrap_or_default().to_string();
    UiApp { pid, name, bundle: bundle_id(pid), frontmost }
}

fn process_path(pid: u32) -> Option<String> {
    let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: buf 的长度是 proc_pidpath 要求的上限。
    let n = unsafe { libc::proc_pidpath(pid as i32, buf.as_mut_ptr() as *mut c_void, buf.len() as u32) };
    (n > 0).then(|| String::from_utf8_lossy(&buf[..n as usize]).into_owned())
}

/// 进程所在 App 包的 bundle id。
fn bundle_id(pid: u32) -> Option<String> {
    let path = process_path(pid)?;
    let end = path.find(".app/")? + ".app".len();
    let bundle_path = &path[..end];
    // SAFETY: 由路径建 URL 与 CFBundle，均按 Create 规则持有；标识符按 Get 规则读取。
    unsafe {
        let url = Cf::own(CFURLCreateFromFileSystemRepresentation(std::ptr::null(), bundle_path.as_ptr(), bundle_path.len() as CFIndex, 1))?;
        let bundle = Cf::own(CFBundleCreate(std::ptr::null(), url.0))?;
        string(CFBundleGetIdentifier(bundle.0))
    }
}

/// 按 pid、bundle id 或名称（不区分大小写）找应用；pid 不必有窗口。
fn find_app(apps: &[UiApp], query: &str) -> io::Result<UiApp> {
    if let Ok(pid) = query.parse::<u32>() {
        return Ok(apps.iter().find(|a| a.pid == pid).cloned().unwrap_or_else(|| describe_app(pid, false)));
    }
    let found = apps.iter().find(|a| a.bundle.as_deref().is_some_and(|b| b.eq_ignore_ascii_case(query)) || a.name.eq_ignore_ascii_case(query));
    found.cloned().ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("没有找到带窗口的应用 {query}")))
}

pub fn ui_action(id: &str, action: ElementAction, value: Option<&str>) -> io::Result<()> {
    require_trust()?;
    let element = lookup(id)?;
    // SAFETY: 读取系统提供的布尔常量。
    let (yes, no) = unsafe { (kCFBooleanTrue, kCFBooleanFalse) };
    match action {
        ElementAction::Press | ElementAction::Toggle => perform(&element, "AXPress", id),
        ElementAction::ShowMenu => perform(&element, "AXShowMenu", id),
        ElementAction::ScrollIntoView => perform(&element, "AXScrollToVisible", id),
        ElementAction::Raise => {
            let mut pid = 0;
            // SAFETY: element 是 AXUIElement。
            if unsafe { AXUIElementGetPid(element.0, &mut pid) } == 0
                && let Some(app) = Cf::own(unsafe { AXUIElementCreateApplication(pid) })
            {
                let _ = set_attribute(&app, "AXFrontmost", yes, id);
            }
            perform(&element, "AXRaise", id)
        }
        ElementAction::Focus => set_attribute(&element, "AXFocused", yes, id),
        ElementAction::Select => set_attribute(&element, "AXSelected", yes, id),
        ElementAction::Expand | ElementAction::Collapse => {
            let flag = if action == ElementAction::Expand { yes } else { no };
            set_attribute(&element, "AXDisclosing", flag, id).or_else(|_| set_attribute(&element, "AXExpanded", flag, id))
        }
        ElementAction::SetValue => {
            let value = value.ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "set-value 需要 value"))?;
            set_attribute(&element, "AXValue", Cf::str(value).0, id)
        }
    }
}

/// 元素当前的 [x, y, 宽, 高]（截图像素）。
pub fn ui_element_bounds(id: &str) -> io::Result<[i32; 4]> {
    require_trust()?;
    let element = lookup(id)?;
    let origin = copy_attribute(&element, "AXPosition").and_then(|v| ax_value::<CGPoint>(v.0, AX_VALUE_POINT));
    let size = copy_attribute(&element, "AXSize").and_then(|v| ax_value::<CGSize>(v.0, AX_VALUE_SIZE));
    match (origin, size) {
        (Some(origin), Some(size)) => Ok(Screen::main().to_pixels(origin, size)),
        _ => Err(io::Error::new(io::ErrorKind::Unsupported, format!("元素 {id} 没有位置"))),
    }
}

pub fn ui_input(events: &[InputEvent]) -> io::Result<()> {
    require_trust()?;
    input::play(&mut Events { screen: Screen::main(), held: None, modifiers: 0 }, events)
}

/// 经 HID 事件流注入：按住鼠标键时的移动发成拖动事件，键盘事件带上当前按住的修饰键。
struct Events {
    screen: Screen,
    held: Option<MouseButton>,
    modifiers: u64,
}

const FLAG_SHIFT: u64 = 0x0002_0000;
const FLAG_CONTROL: u64 = 0x0004_0000;
const FLAG_ALTERNATE: u64 = 0x0008_0000;
const FLAG_COMMAND: u64 = 0x0010_0000;
/// 一个 Unicode 文本事件最多带的 UTF-16 单元数。
const TEXT_CHUNK: usize = 20;
/// 相邻两个文本事件的间隔，太快时应用会丢字。
const TEXT_PAUSE: Duration = Duration::from_millis(4);

impl Events {
    fn post(&self, event: CFTypeRef) -> io::Result<()> {
        let event = Cf::own(event).ok_or_else(|| io::Error::other("创建输入事件失败"))?;
        // SAFETY: event 是有效 CGEvent。
        unsafe { CGEventPost(HID_EVENT_TAP, event.0) };
        Ok(())
    }

    fn mouse(&self, kind: u32, x: i32, y: i32, button: u32, clicks: u32) -> io::Result<()> {
        // SAFETY: 创建鼠标事件；连击序号写进 click state 字段。
        let event = unsafe { CGEventCreateMouseEvent(std::ptr::null(), kind, self.screen.to_points(x, y), button) };
        if !event.is_null() && clicks > 0 {
            unsafe { CGEventSetIntegerValueField(event, MOUSE_EVENT_CLICK_STATE, i64::from(clicks)) };
        }
        self.post(event)
    }
}

/// CGEventType 与 CGMouseButton：(按下, 抬起, 拖动, 按键号)。
fn mouse_kinds(button: MouseButton) -> (u32, u32, u32, u32) {
    match button {
        MouseButton::Left => (1, 2, 6, 0),
        MouseButton::Right => (3, 4, 7, 1),
        MouseButton::Middle => (25, 26, 27, 2),
    }
}

impl Injector for Events {
    fn move_to(&mut self, x: i32, y: i32) -> io::Result<()> {
        match self.held {
            Some(button) => {
                let (_, _, drag, number) = mouse_kinds(button);
                self.mouse(drag, x, y, number, 0)
            }
            None => self.mouse(5, x, y, 0, 0),
        }
    }

    fn button(&mut self, button: MouseButton, down: bool, x: i32, y: i32, clicks: u32) -> io::Result<()> {
        let (press, release, _, number) = mouse_kinds(button);
        self.held = down.then_some(button);
        self.mouse(if down { press } else { release }, x, y, number, clicks)
    }

    fn scroll(&mut self, _x: i32, _y: i32, dx: i32, dy: i32) -> io::Result<()> {
        // CG 的滚轮值正数向上、向左。
        // SAFETY: 创建按行计的双轴滚轮事件。
        self.post(unsafe { CGEventCreateScrollWheelEvent2(std::ptr::null(), SCROLL_UNIT_LINE, 2, -dy, -dx, 0) })
    }

    fn key(&mut self, key: Key, down: bool) -> io::Result<()> {
        let flag = match key {
            Key::Cmd => FLAG_COMMAND,
            Key::Ctrl => FLAG_CONTROL,
            Key::Alt => FLAG_ALTERNATE,
            Key::Shift => FLAG_SHIFT,
            _ => 0,
        };
        if down {
            self.modifiers |= flag;
        } else {
            self.modifiers &= !flag;
        }
        let code = keycode(key).ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, format!("macOS 上没有这个键：{key:?}")))?;
        // SAFETY: 创建键盘事件并设好修饰键。
        let event = unsafe { CGEventCreateKeyboardEvent(std::ptr::null(), code, down) };
        if !event.is_null() {
            unsafe { CGEventSetFlags(event, self.modifiers) };
        }
        self.post(event)
    }

    fn text(&mut self, text: &str) -> io::Result<()> {
        let units: Vec<u16> = text.encode_utf16().collect();
        for chunk in units.chunks(TEXT_CHUNK) {
            for down in [true, false] {
                // SAFETY: 键码 0 的键盘事件换成 chunk 里的 Unicode 文本。
                let event = unsafe { CGEventCreateKeyboardEvent(std::ptr::null(), 0, down) };
                if !event.is_null() {
                    unsafe { CGEventKeyboardSetUnicodeString(event, chunk.len(), chunk.as_ptr()) };
                }
                self.post(event)?;
            }
            thread::sleep(TEXT_PAUSE);
        }
        Ok(())
    }
}

/// 美式键盘的虚拟键码（Carbon `kVK_*`）。
fn keycode(key: Key) -> Option<u16> {
    Some(match key {
        Key::Cmd => 55,
        Key::Shift => 56,
        Key::Alt => 58,
        Key::Ctrl => 59,
        Key::Enter => 36,
        Key::Tab => 48,
        Key::Space => 49,
        Key::Backspace => 51,
        Key::Escape => 53,
        Key::Delete => 117,
        Key::Home => 115,
        Key::End => 119,
        Key::PageUp => 116,
        Key::PageDown => 121,
        Key::Left => 123,
        Key::Right => 124,
        Key::Down => 125,
        Key::Up => 126,
        Key::F(n) => [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111][usize::from(n).checked_sub(1)?],
        Key::Char(c) => {
            const CHARS: &str = "asdfhgzxcv?bqweryt123465=97-80]ou[ip?lj'k;\\,/nm.";
            if c == '`' {
                50
            } else {
                CHARS.find(c).filter(|_| c != '?')? as u16
            }
        }
    })
}

pub fn ui_screenshot() -> io::Result<Vec<u8>> {
    // SAFETY: 查询与申请屏幕录制授权，申请会在客户机里弹出系统提示。
    if !unsafe { CGPreflightScreenCaptureAccess() } {
        unsafe { CGRequestScreenCaptureAccess() };
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "MacVM Agent 没有屏幕录制权限：在客户机「系统设置 › 隐私与安全性 › 屏幕与系统录音」里允许 MacVM Agent 后重试",
        ));
    }
    let path = std::env::temp_dir().join(format!("macvm-screenshot-{}-{:?}.png", std::process::id(), thread::current().id()));
    let status = Command::new("/usr/sbin/screencapture").args(["-x", "-m", "-t", "png"]).arg(&path).status()?;
    let data = std::fs::read(&path);
    let _ = std::fs::remove_file(&path);
    if !status.success() {
        return Err(io::Error::other(format!("screencapture 退出码 {status}")));
    }
    data
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ansi_keycodes() {
        assert_eq!(keycode(Key::Char('a')), Some(0));
        assert_eq!(keycode(Key::Char('b')), Some(11));
        assert_eq!(keycode(Key::Char('q')), Some(12));
        assert_eq!(keycode(Key::Char('1')), Some(18));
        assert_eq!(keycode(Key::Char('5')), Some(23));
        assert_eq!(keycode(Key::Char('0')), Some(29));
        assert_eq!(keycode(Key::Char(']')), Some(30));
        assert_eq!(keycode(Key::Char('l')), Some(37));
        assert_eq!(keycode(Key::Char('\\')), Some(42));
        assert_eq!(keycode(Key::Char('.')), Some(47));
        assert_eq!(keycode(Key::Char('`')), Some(50));
        assert_eq!(keycode(Key::Char('?')), None);
        assert_eq!(keycode(Key::F(12)), Some(111));
    }

    /// 要运行测试的终端有辅助功能授权：`cargo test -- --ignored snapshot_frontmost`。
    #[test]
    #[ignore]
    fn snapshot_frontmost() {
        let snapshot = ui_snapshot(&SnapshotOptions { app: None, max_depth: 8, max_nodes: 200 }).unwrap();
        assert!(snapshot.screen.width > 0 && !snapshot.apps.is_empty());
        let id = &snapshot.nodes.last().unwrap().id;
        assert!(lookup(id).is_ok());
        println!("{}", serde_json::to_string_pretty(&snapshot).unwrap());
    }

    #[test]
    fn cf_strings_round_trip() {
        assert_eq!(string(Cf::str("辅助功能 AX").0).as_deref(), Some("辅助功能 AX"));
    }
}
