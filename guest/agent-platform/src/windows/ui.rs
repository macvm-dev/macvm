//! Windows：经 UI Automation 读无障碍树、执行动作，经 SendInput 注入输入，用 GDI 截屏。
//! 每个请求在自己的连接线程上进 COM 多线程套间并按每显示器 DPI 感知运行，坐标都是物理像素。

use super::{capture, dpi, sendinput, until_nul};
use crate::{SnapshotOptions, stale_element};
use macvm_agent_protocol::{ElementAction, InputEvent, MouseButton, UiApp, UiNode, UiScreen, UiSnapshot, UiState};
use std::io;
use std::sync::Mutex;
use windows::Win32::Foundation::RECT;
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx};
use windows::Win32::System::Variant::VARIANT;
use windows::Win32::UI::Accessibility::*;
use windows::core::{BSTR, Interface};
use windows_sys::Win32::Foundation::CloseHandle;
use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW};
use windows_sys::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId, SetForegroundWindow};

/// 当前线程进 COM 多线程套间，按物理像素工作，返回 UIA 根对象。
fn automation() -> io::Result<IUIAutomation> {
    dpi::per_monitor_thread();
    // SAFETY: 本线程进多线程套间；已在其中时返回 S_FALSE，也算成功。
    unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED).ok().map_err(com)?;
        CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER).map_err(com)
    }
}

fn com(e: windows::core::Error) -> io::Error {
    io::Error::other(format!("UI Automation：{}", e.message()))
}

/// 快照里缓存的属性。
const PROPERTIES: [UIA_PROPERTY_ID; 21] = [
    UIA_ProcessIdPropertyId,
    UIA_ControlTypePropertyId,
    UIA_NamePropertyId,
    UIA_ClassNamePropertyId,
    UIA_HelpTextPropertyId,
    UIA_BoundingRectanglePropertyId,
    UIA_IsEnabledPropertyId,
    UIA_HasKeyboardFocusPropertyId,
    UIA_IsKeyboardFocusablePropertyId,
    UIA_IsOffscreenPropertyId,
    UIA_ValueValuePropertyId,
    UIA_ValueIsReadOnlyPropertyId,
    UIA_ToggleToggleStatePropertyId,
    UIA_ExpandCollapseExpandCollapseStatePropertyId,
    UIA_SelectionItemIsSelectedPropertyId,
    UIA_IsInvokePatternAvailablePropertyId,
    UIA_IsValuePatternAvailablePropertyId,
    UIA_IsTogglePatternAvailablePropertyId,
    UIA_IsExpandCollapsePatternAvailablePropertyId,
    UIA_IsSelectionItemPatternAvailablePropertyId,
    UIA_IsScrollItemPatternAvailablePropertyId,
];

/// 元素的 `value` 最多保留这么多字符。
const MAX_VALUE_CHARS: usize = 2000;

struct Element(IUIAutomationElement);

// SAFETY: 元素来自多线程套间里创建的 UIA 对象，任何同样在多线程套间里的线程都能调用。
unsafe impl Send for Element {}

struct Cache {
    generation: u32,
    elements: Vec<Element>,
}

static CACHE: Mutex<Cache> = Mutex::new(Cache { generation: 0, elements: Vec::new() });

fn lookup(id: &str) -> io::Result<IUIAutomationElement> {
    let cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    let (generation, index) = id.split_once('.').ok_or_else(|| stale_element(id))?;
    if generation.parse::<u32>().ok() != Some(cache.generation) {
        return Err(stale_element(id));
    }
    index.parse::<usize>().ok().and_then(|i| cache.elements.get(i)).map(|e| e.0.clone()).ok_or_else(|| stale_element(id))
}

pub fn ui_snapshot(options: &SnapshotOptions) -> io::Result<UiSnapshot> {
    let automation = automation()?;
    let (width, height, scale) = dpi::primary_screen();
    // SAFETY: 以下都是 UIA 的 COM 调用，参数都是有效对象。
    unsafe {
        let request = automation.CreateCacheRequest().map_err(com)?;
        for property in PROPERTIES {
            request.AddProperty(property).map_err(com)?;
        }
        let walker = automation.ControlViewWalker().map_err(com)?;
        // 桌面根元素的子元素就是各个顶层窗口（含任务栏、桌面与有属主的对话框），按 Z 序排列。
        let root = automation.GetRootElement().map_err(com)?;
        let mut windows: Vec<(IUIAutomationElement, u32)> = Vec::new();
        let mut child = walker.GetFirstChildElementBuildCache(&root, &request).ok();
        while let Some(c) = child {
            child = walker.GetNextSiblingElementBuildCache(&c, &request).ok();
            if let Some(pid) = cached_int(&c, UIA_ProcessIdPropertyId) {
                windows.push((c, pid as u32));
            }
        }
        let foreground = window_pid(GetForegroundWindow() as isize);
        let mut apps: Vec<UiApp> = Vec::new();
        for &(_, pid) in &windows {
            if apps.iter().all(|a| a.pid != pid) {
                apps.push(UiApp { pid, name: process_name(pid).unwrap_or_default(), bundle: None, frontmost: Some(pid) == foreground });
            }
        }
        let target = match options.app {
            Some(query) => Some(find_app(&apps, query)?),
            None => apps.iter().find(|a| a.frontmost).cloned(),
        };
        let mut snapshot = UiSnapshot { screen: UiScreen { width, height, scale }, apps, app: target.clone(), ..Default::default() };
        let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
        cache.generation = cache.generation.wrapping_add(1);
        cache.elements.clear();
        let Some(app) = target else { return Ok(snapshot) };
        let generation = cache.generation;
        let mut stack: Vec<(IUIAutomationElement, u32)> =
            windows.into_iter().rev().filter(|(_, pid)| *pid == app.pid).map(|(e, _)| (e, 0)).collect();
        let started = std::time::Instant::now();
        while let Some((element, depth)) = stack.pop() {
            if snapshot.nodes.len() >= options.max_nodes as usize || started.elapsed() > crate::SNAPSHOT_BUDGET {
                snapshot.truncated = true;
                break;
            }
            let id = format!("{generation}.{}", cache.elements.len());
            snapshot.nodes.push(describe(&element, id, depth));
            let mut children = Vec::new();
            let mut child = walker.GetFirstChildElementBuildCache(&element, &request).ok();
            while let Some(c) = child {
                child = walker.GetNextSiblingElementBuildCache(&c, &request).ok();
                children.push(c);
            }
            if !children.is_empty() {
                if depth >= options.max_depth {
                    snapshot.truncated = true;
                } else {
                    stack.extend(children.into_iter().rev().map(|c| (c, depth + 1)));
                }
            }
            cache.elements.push(Element(element));
        }
        Ok(snapshot)
    }
}

fn cached(element: &IUIAutomationElement, property: UIA_PROPERTY_ID) -> Option<VARIANT> {
    // SAFETY: 读取快照时缓存的属性。
    unsafe { element.GetCachedPropertyValue(property) }.ok()
}

fn cached_bool(element: &IUIAutomationElement, property: UIA_PROPERTY_ID) -> bool {
    cached(element, property).and_then(|v| bool::try_from(&v).ok()).unwrap_or(false)
}

fn cached_int(element: &IUIAutomationElement, property: UIA_PROPERTY_ID) -> Option<i32> {
    cached(element, property).and_then(|v| i32::try_from(&v).ok())
}

fn cached_text(element: &IUIAutomationElement, property: UIA_PROPERTY_ID) -> Option<String> {
    cached(element, property).and_then(|v| BSTR::try_from(&v).ok()).map(|s| s.to_string()).filter(|s| !s.is_empty())
}

fn bounds(rect: RECT) -> Option<[i32; 4]> {
    let (w, h) = (rect.right - rect.left, rect.bottom - rect.top);
    (w > 0 && h > 0).then_some([rect.left, rect.top, w, h])
}

fn describe(element: &IUIAutomationElement, id: String, depth: u32) -> UiNode {
    let control = cached_int(element, UIA_ControlTypePropertyId).unwrap_or(0);
    // SAFETY: 读取缓存的边框。
    let rect = unsafe { element.CachedBoundingRectangle() }.ok().and_then(bounds);
    let available = |p| cached_bool(element, p);

    let mut states = Vec::new();
    if available(UIA_HasKeyboardFocusPropertyId) {
        states.push(UiState::Focused);
    }
    if !available(UIA_IsEnabledPropertyId) {
        states.push(UiState::Disabled);
    }
    if available(UIA_SelectionItemIsSelectedPropertyId) {
        states.push(UiState::Selected);
    }
    if cached_int(element, UIA_ToggleToggleStatePropertyId) == Some(ToggleState_On.0) {
        states.push(UiState::Checked);
    }
    if cached_int(element, UIA_ExpandCollapseExpandCollapseStatePropertyId) == Some(ExpandCollapseState_Expanded.0) {
        states.push(UiState::Expanded);
    }
    if available(UIA_IsOffscreenPropertyId) {
        states.push(UiState::Offscreen);
    }

    let mut actions = Vec::new();
    if available(UIA_IsInvokePatternAvailablePropertyId) {
        actions.push(ElementAction::Press);
    }
    if available(UIA_IsTogglePatternAvailablePropertyId) {
        actions.push(ElementAction::Toggle);
    }
    if available(UIA_IsExpandCollapsePatternAvailablePropertyId) {
        actions.extend([ElementAction::Expand, ElementAction::Collapse]);
    }
    if available(UIA_IsSelectionItemPatternAvailablePropertyId) {
        actions.push(ElementAction::Select);
    }
    if available(UIA_IsScrollItemPatternAvailablePropertyId) {
        actions.push(ElementAction::ScrollIntoView);
    }
    let has_value = available(UIA_IsValuePatternAvailablePropertyId);
    if has_value && !available(UIA_ValueIsReadOnlyPropertyId) {
        actions.push(ElementAction::SetValue);
    }
    if available(UIA_IsKeyboardFocusablePropertyId) {
        actions.push(ElementAction::Focus);
    }
    if control == UIA_WindowControlTypeId.0 {
        actions.push(ElementAction::Raise);
    }

    UiNode {
        id,
        depth,
        role: control_type_name(control).to_string(),
        subrole: cached_text(element, UIA_ClassNamePropertyId),
        name: cached_text(element, UIA_NamePropertyId),
        value: if has_value { cached_text(element, UIA_ValueValuePropertyId).map(|v| v.chars().take(MAX_VALUE_CHARS).collect()) } else { None },
        description: cached_text(element, UIA_HelpTextPropertyId),
        bounds: rect,
        states,
        actions,
    }
}

/// `UIA_*ControlTypeId`（50000 起）的名称。
fn control_type_name(id: i32) -> &'static str {
    const NAMES: [&str; 41] = [
        "Button", "Calendar", "CheckBox", "ComboBox", "Edit", "Hyperlink", "Image", "ListItem", "List", "Menu", "MenuBar", "MenuItem",
        "ProgressBar", "RadioButton", "ScrollBar", "Slider", "Spinner", "StatusBar", "Tab", "TabItem", "Text", "ToolBar", "ToolTip", "Tree",
        "TreeItem", "Custom", "Group", "Thumb", "DataGrid", "DataItem", "Document", "SplitButton", "Window", "Pane", "Header", "HeaderItem",
        "Table", "TitleBar", "Separator", "SemanticZoom", "AppBar",
    ];
    id.checked_sub(50000).and_then(|i| NAMES.get(i as usize)).copied().unwrap_or("Unknown")
}

fn pattern<T: Interface>(element: &IUIAutomationElement, id: UIA_PATTERN_ID, what: &str) -> io::Result<T> {
    // SAFETY: 向元素要指定的控件模式。
    unsafe { element.GetCurrentPatternAs::<T>(id) }.map_err(|_| io::Error::new(io::ErrorKind::Unsupported, format!("元素不支持 {what}")))
}

pub fn ui_action(id: &str, action: ElementAction, value: Option<&str>) -> io::Result<()> {
    let _automation = automation()?;
    let element = lookup(id)?;
    // SAFETY: 以下都是对有效元素与控件模式的 COM 调用。
    let result = unsafe {
        match action {
            ElementAction::Press => match pattern::<IUIAutomationInvokePattern>(&element, UIA_InvokePatternId, "press") {
                Ok(p) => p.Invoke(),
                Err(_) => match pattern::<IUIAutomationTogglePattern>(&element, UIA_TogglePatternId, "press") {
                    Ok(p) => p.Toggle(),
                    Err(_) => pattern::<IUIAutomationLegacyIAccessiblePattern>(&element, UIA_LegacyIAccessiblePatternId, "press")?.DoDefaultAction(),
                },
            },
            ElementAction::Toggle => pattern::<IUIAutomationTogglePattern>(&element, UIA_TogglePatternId, "toggle")?.Toggle(),
            ElementAction::Expand => pattern::<IUIAutomationExpandCollapsePattern>(&element, UIA_ExpandCollapsePatternId, "expand")?.Expand(),
            ElementAction::Collapse => pattern::<IUIAutomationExpandCollapsePattern>(&element, UIA_ExpandCollapsePatternId, "collapse")?.Collapse(),
            ElementAction::Select => pattern::<IUIAutomationSelectionItemPattern>(&element, UIA_SelectionItemPatternId, "select")?.Select(),
            ElementAction::ScrollIntoView => {
                pattern::<IUIAutomationScrollItemPattern>(&element, UIA_ScrollItemPatternId, "scroll-into-view")?.ScrollIntoView()
            }
            ElementAction::SetValue => {
                let value = value.ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "set-value 需要 value"))?;
                pattern::<IUIAutomationValuePattern>(&element, UIA_ValuePatternId, "set-value")?.SetValue(&BSTR::from(value))
            }
            ElementAction::Focus => element.SetFocus(),
            ElementAction::Raise => {
                if let Ok(hwnd) = element.CurrentNativeWindowHandle()
                    && !hwnd.0.is_null()
                {
                    SetForegroundWindow(hwnd.0 as _);
                }
                element.SetFocus()
            }
            ElementAction::ShowMenu => {
                // UIA 没有弹出右键菜单的模式，在元素中心点右键。
                let rect = element.CurrentBoundingRectangle().map_err(com)?;
                let [x, y, w, h] = bounds(rect).ok_or_else(|| io::Error::new(io::ErrorKind::Unsupported, format!("元素 {id} 没有位置")))?;
                let click = InputEvent::Click { x: Some(x + w / 2), y: Some(y + h / 2), element: None, button: MouseButton::Right, count: 1 };
                return sendinput::play(&[click]);
            }
        }
    };
    result.map_err(|e| if e.code().0 as u32 == UIA_E_ELEMENTNOTAVAILABLE { stale_element(id) } else { com(e) })
}

pub fn ui_element_bounds(id: &str) -> io::Result<[i32; 4]> {
    let _automation = automation()?;
    let element = lookup(id)?;
    // SAFETY: 读取有效元素的当前边框。
    let rect = unsafe { element.CurrentBoundingRectangle() }.map_err(com)?;
    bounds(rect).ok_or_else(|| io::Error::new(io::ErrorKind::Unsupported, format!("元素 {id} 没有位置")))
}

pub fn ui_input(events: &[InputEvent]) -> io::Result<()> {
    dpi::per_monitor_thread();
    sendinput::play(events)
}

pub fn ui_screenshot() -> io::Result<Vec<u8>> {
    dpi::per_monitor_thread();
    let (width, height, _) = dpi::primary_screen();
    capture::png(width, height)
}

fn window_pid(hwnd: isize) -> Option<u32> {
    let mut pid = 0u32;
    // SAFETY: 只查询窗口所属进程。
    unsafe { GetWindowThreadProcessId(hwnd as _, &mut pid) };
    (pid != 0).then_some(pid)
}

/// 进程的可执行文件名，去掉 `.exe`。
fn process_name(pid: u32) -> Option<String> {
    // SAFETY: 以受限查询权限打开进程、读路径后关闭。
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return None;
        }
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, buf.as_mut_ptr(), &mut len) != 0;
        CloseHandle(process);
        if !ok {
            return None;
        }
        let path = String::from_utf16_lossy(until_nul(&buf[..len as usize]));
        let file = path.rsplit('\\').next().unwrap_or(&path);
        Some(file.strip_suffix(".exe").or_else(|| file.strip_suffix(".EXE")).unwrap_or(file).to_string())
    }
}

/// 按 pid 或进程名（不区分大小写，可带 `.exe`）找应用。
fn find_app(apps: &[UiApp], query: &str) -> io::Result<UiApp> {
    let pid = query.parse::<u32>().ok();
    let name = query.strip_suffix(".exe").unwrap_or(query);
    apps.iter()
        .find(|a| Some(a.pid) == pid || a.name.eq_ignore_ascii_case(name))
        .cloned()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("没有找到带窗口的应用 {query}")))
}
