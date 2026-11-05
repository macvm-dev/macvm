//! `ui-*` 请求的参数与 `ui-snapshot` 的正文。坐标一律是截图像素，原点在主屏左上角。

use serde::{Deserialize, Serialize};

/// 快照不指定时的遍历深度上限。
pub const DEFAULT_UI_DEPTH: u32 = 40;
/// 快照不指定时的节点数上限。
pub const DEFAULT_UI_NODES: u32 = 2000;

/// 各系统无障碍动作归一后的名称。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ElementAction {
    Press,
    Focus,
    /// 需要 `value`。
    SetValue,
    Toggle,
    Expand,
    Collapse,
    Select,
    ScrollIntoView,
    ShowMenu,
    Raise,
}

impl ElementAction {
    pub fn name(self) -> &'static str {
        match self {
            Self::Press => "press",
            Self::Focus => "focus",
            Self::SetValue => "set-value",
            Self::Toggle => "toggle",
            Self::Expand => "expand",
            Self::Collapse => "collapse",
            Self::Select => "select",
            Self::ScrollIntoView => "scroll-into-view",
            Self::ShowMenu => "show-menu",
            Self::Raise => "raise",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum MouseButton {
    #[default]
    Left,
    Right,
    Middle,
}

impl MouseButton {
    fn is_left(&self) -> bool {
        *self == Self::Left
    }
}

/// 输入事件。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum InputEvent {
    Move { x: i32, y: i32 },
    /// 给 `element` 时点它的中心，否则点 (`x`, `y`)。
    Click {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        x: Option<i32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        y: Option<i32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        element: Option<String>,
        #[serde(default, skip_serializing_if = "MouseButton::is_left")]
        button: MouseButton,
        #[serde(default = "one", skip_serializing_if = "is_one")]
        count: u32,
    },
    Drag {
        from: [i32; 2],
        to: [i32; 2],
        #[serde(default, skip_serializing_if = "MouseButton::is_left")]
        button: MouseButton,
    },
    /// 在 (`x`, `y`) 处滚动，单位是滚轮格；正值向右、向下。
    Scroll {
        x: i32,
        y: i32,
        #[serde(default)]
        dx: i32,
        #[serde(default)]
        dy: i32,
    },
    /// 组合键，如 `cmd+shift+t`、`enter`。
    Key { keys: String },
    Text { text: String },
}

fn one() -> u32 {
    1
}

fn is_one(n: &u32) -> bool {
    *n == 1
}

fn is_false(b: &bool) -> bool {
    !*b
}

/// `ui-snapshot` 的正文。
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct UiSnapshot {
    pub screen: UiScreen,
    /// 有窗口的应用。
    pub apps: Vec<UiApp>,
    /// 本次快照的应用；没有前台应用时为空。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<UiApp>,
    /// 先序遍历的元素，父子关系由 `depth` 表达。
    pub nodes: Vec<UiNode>,
    /// 达到深度或节点数上限，树不完整。
    #[serde(default, skip_serializing_if = "is_false")]
    pub truncated: bool,
}

/// 主屏：`width`、`height` 是截图像素，`scale` 是每个系统坐标单位对应的像素数。
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct UiScreen {
    pub width: u32,
    pub height: u32,
    pub scale: f64,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct UiApp {
    pub pid: u32,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle: Option<String>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub frontmost: bool,
}

/// 无障碍树的一个元素。`id` 不透明，在下一次快照之前有效；`role` 是客户机系统的原名；
/// `bounds` 是 [x, y, 宽, 高]。
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct UiNode {
    pub id: String,
    pub depth: u32,
    pub role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subrole: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bounds: Option<[i32; 4]>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub states: Vec<UiState>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub actions: Vec<ElementAction>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum UiState {
    Focused,
    Disabled,
    Selected,
    Checked,
    Expanded,
    Offscreen,
}
