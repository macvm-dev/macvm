//! 把 `InputEvent` 拆成各平台注入器的基本动作，并解析组合键。

use macvm_agent_protocol::{InputEvent, MouseButton};
use std::io;
use std::thread;
use std::time::Duration;

/// 与布局无关的键。`Char` 是美式键盘上不按 Shift 时的 ASCII 字符。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    /// macOS 的 Command，Windows 的 Win，Linux 的 Super。
    Cmd,
    Ctrl,
    Alt,
    Shift,
    Enter,
    Tab,
    Escape,
    Space,
    Backspace,
    /// 向前删除。
    Delete,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    /// F1–F12。
    F(u8),
    Char(char),
}

impl Key {
    fn is_modifier(self) -> bool {
        matches!(self, Self::Cmd | Self::Ctrl | Self::Alt | Self::Shift)
    }

    fn parse(name: &str) -> Option<Self> {
        let lower = name.to_ascii_lowercase();
        Some(match lower.as_str() {
            "cmd" | "command" | "meta" | "super" | "win" => Self::Cmd,
            "ctrl" | "control" => Self::Ctrl,
            "alt" | "option" | "opt" => Self::Alt,
            "shift" => Self::Shift,
            "enter" | "return" => Self::Enter,
            "tab" => Self::Tab,
            "esc" | "escape" => Self::Escape,
            "space" => Self::Space,
            "backspace" => Self::Backspace,
            "delete" | "del" => Self::Delete,
            "up" => Self::Up,
            "down" => Self::Down,
            "left" => Self::Left,
            "right" => Self::Right,
            "home" => Self::Home,
            "end" => Self::End,
            "pageup" | "pgup" => Self::PageUp,
            "pagedown" | "pgdn" => Self::PageDown,
            "plus" => Self::Char('='),
            _ => {
                if let Some(n) = lower.strip_prefix('f').and_then(|n| n.parse::<u8>().ok()) {
                    return (1..=12).contains(&n).then_some(Self::F(n));
                }
                let mut chars = lower.chars();
                let c = chars.next()?;
                if chars.next().is_some() || !c.is_ascii_graphic() {
                    return None;
                }
                Self::Char(unshifted(c).0)
            }
        })
    }
}

/// 美式键盘上打出 `c` 用的键，以及是否要按 Shift。
pub fn unshifted(c: char) -> (char, bool) {
    const SHIFTED: &str = "~!@#$%^&*()_+{}|:\"<>?";
    const PLAIN: &str = "`1234567890-=[]\\;',./";
    if c.is_ascii_uppercase() {
        return (c.to_ascii_lowercase(), true);
    }
    match SHIFTED.find(c) {
        Some(i) => (PLAIN.as_bytes()[i] as char, true),
        None => (c, false),
    }
}

/// 解析 `cmd+shift+t` 这样的组合键：修饰键在前，最后一个是主键（也可以只有一个修饰键）。
/// 主键是要按 Shift 才打得出的符号（如 `?`）时补上 Shift；字母不区分大小写。
pub fn parse_combo(text: &str) -> io::Result<Vec<Key>> {
    let invalid = || io::Error::new(io::ErrorKind::InvalidInput, format!("Unknown key: {text}"));
    let parts: Vec<&str> = text.split('+').map(str::trim).collect();
    let mut keys: Vec<Key> = parts.iter().map(|part| Key::parse(part)).collect::<Option<_>>().ok_or_else(invalid)?;
    let (last, modifiers) = keys.split_last().ok_or_else(invalid)?;
    if modifiers.iter().any(|k| !k.is_modifier()) || (keys.len() > 1 && last.is_modifier()) {
        return Err(invalid());
    }
    let mut symbol = parts.last().unwrap_or(&"").chars();
    if let (Some(c), None) = (symbol.next(), symbol.next())
        && !c.is_ascii_alphabetic()
        && unshifted(c).1
        && !keys.contains(&Key::Shift)
    {
        keys.insert(keys.len() - 1, Key::Shift);
    }
    Ok(keys)
}

/// 平台的输入注入。坐标是截图像素。
pub trait Injector {
    fn move_to(&mut self, x: i32, y: i32) -> io::Result<()>;
    /// `clicks` 是这次按下在连击里的序号，从 1 起。
    fn button(&mut self, button: MouseButton, down: bool, x: i32, y: i32, clicks: u32) -> io::Result<()>;
    fn scroll(&mut self, x: i32, y: i32, dx: i32, dy: i32) -> io::Result<()>;
    fn key(&mut self, key: Key, down: bool) -> io::Result<()>;
    fn text(&mut self, text: &str) -> io::Result<()>;
}

/// 拖动途中插入的移动次数：只收到起止两点时，有的应用不认为是拖动。
const DRAG_STEPS: i32 = 12;
/// 拖动中相邻两次移动的间隔。
const DRAG_PAUSE: Duration = Duration::from_millis(8);

/// 按顺序注入 `events`；`Click` 必须已带坐标。中途出错时已按下的键与鼠标键照样抬起，客户机里不留按住的键。
pub fn play(injector: &mut impl Injector, events: &[InputEvent]) -> io::Result<()> {
    for event in events {
        match event {
            InputEvent::Move { x, y } => injector.move_to(*x, *y)?,
            InputEvent::Click { x: Some(x), y: Some(y), button, count, .. } => {
                injector.move_to(*x, *y)?;
                for n in 1..=(*count).max(1) {
                    injector.button(*button, true, *x, *y, n)?;
                    injector.button(*button, false, *x, *y, n)?;
                }
            }
            InputEvent::Click { .. } => return Err(io::Error::new(io::ErrorKind::InvalidInput, "click needs x and y, or element")),
            InputEvent::Drag { from, to, button } => {
                injector.move_to(from[0], from[1])?;
                injector.button(*button, true, from[0], from[1], 1)?;
                let moved = (1..=DRAG_STEPS).try_for_each(|step| {
                    thread::sleep(DRAG_PAUSE);
                    let x = from[0] + (to[0] - from[0]) * step / DRAG_STEPS;
                    let y = from[1] + (to[1] - from[1]) * step / DRAG_STEPS;
                    injector.move_to(x, y)
                });
                let released = injector.button(*button, false, to[0], to[1], 1);
                moved.and(released)?;
            }
            InputEvent::Scroll { x, y, dx, dy } => {
                injector.move_to(*x, *y)?;
                injector.scroll(*x, *y, *dx, *dy)?;
            }
            InputEvent::Key { keys } => press(injector, &parse_combo(keys)?)?,
            InputEvent::Text { text } => injector.text(text)?,
        }
    }
    Ok(())
}

/// 依次按下 `keys` 再倒序抬起；中途出错时已按下的键照样抬起。
fn press(injector: &mut impl Injector, keys: &[Key]) -> io::Result<()> {
    let mut pressed = 0;
    let mut result = Ok(());
    for &key in keys {
        result = injector.key(key, true);
        if result.is_err() {
            break;
        }
        pressed += 1;
    }
    for &key in keys[..pressed].iter().rev() {
        let up = injector.key(key, false);
        result = result.and(up);
    }
    result
}

/// 逐字按键打出文本，供没有 Unicode 输入通道的平台用：ASCII 按美式布局打，其余字符用 GTK 与 IBus 的
/// Unicode 输入（ctrl+shift+u、十六进制码、空格），GNOME 里的 GTK、Qt 程序、终端与浏览器都认。
#[cfg_attr(not(any(target_os = "linux", test)), allow(dead_code))]
pub fn type_with_keys(injector: &mut impl Injector, text: &str) -> io::Result<()> {
    for c in text.chars() {
        let key = match c {
            '\n' => Key::Enter,
            '\t' => Key::Tab,
            ' ' => Key::Space,
            c if c.is_ascii_graphic() => Key::Char(unshifted(c).0),
            c => {
                type_code_point(injector, c)?;
                continue;
            }
        };
        if c.is_ascii_graphic() && unshifted(c).1 {
            press(injector, &[Key::Shift, key])?;
        } else {
            press(injector, &[key])?;
        }
    }
    Ok(())
}

/// 按下 ctrl+shift+u 后输入法要这么久才进入 Unicode 输入状态，之前的按键会被当成普通输入。
const UNICODE_ENTRY_PAUSE: Duration = Duration::from_millis(50);

fn type_code_point(injector: &mut impl Injector, c: char) -> io::Result<()> {
    press(injector, &[Key::Ctrl, Key::Shift, Key::Char('u')])?;
    thread::sleep(UNICODE_ENTRY_PAUSE);
    for digit in format!("{:x}", u32::from(c)).chars() {
        press(injector, &[Key::Char(digit)])?;
    }
    press(injector, &[Key::Space])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Recorder(Vec<String>);

    impl Injector for Recorder {
        fn move_to(&mut self, x: i32, y: i32) -> io::Result<()> {
            self.0.push(format!("move {x},{y}"));
            Ok(())
        }
        fn button(&mut self, button: MouseButton, down: bool, x: i32, y: i32, clicks: u32) -> io::Result<()> {
            self.0.push(format!("{button:?} {} {x},{y} #{clicks}", if down { "down" } else { "up" }));
            Ok(())
        }
        fn scroll(&mut self, _x: i32, _y: i32, dx: i32, dy: i32) -> io::Result<()> {
            self.0.push(format!("scroll {dx},{dy}"));
            Ok(())
        }
        fn key(&mut self, key: Key, down: bool) -> io::Result<()> {
            self.0.push(format!("{key:?} {}", if down { "down" } else { "up" }));
            Ok(())
        }
        fn text(&mut self, text: &str) -> io::Result<()> {
            self.0.push(format!("text {text}"));
            Ok(())
        }
    }

    #[test]
    fn combos() {
        assert_eq!(parse_combo("cmd+shift+t").unwrap(), [Key::Cmd, Key::Shift, Key::Char('t')]);
        assert_eq!(parse_combo("Enter").unwrap(), [Key::Enter]);
        assert_eq!(parse_combo("ctrl+F4").unwrap(), [Key::Ctrl, Key::F(4)]);
        assert_eq!(parse_combo("shift").unwrap(), [Key::Shift]);
        assert_eq!(parse_combo("cmd+plus").unwrap(), [Key::Cmd, Key::Char('=')]);
        assert_eq!(parse_combo("alt+?").unwrap(), [Key::Alt, Key::Shift, Key::Char('/')]);
        assert_eq!(parse_combo("cmd+shift+?").unwrap(), [Key::Cmd, Key::Shift, Key::Char('/')]);
        assert_eq!(parse_combo("cmd+T").unwrap(), [Key::Cmd, Key::Char('t')]);
        assert!(parse_combo("t+cmd").is_err());
        assert!(parse_combo("cmd+a+b").is_err());
        assert!(parse_combo("f13").is_err());
        assert!(parse_combo("cmd+").is_err());
        assert!(parse_combo("你").is_err());
    }

    #[test]
    fn double_click_counts_up() {
        let mut r = Recorder::default();
        play(&mut r, &[InputEvent::Click { x: Some(5), y: Some(6), element: None, button: MouseButton::Left, count: 2 }]).unwrap();
        assert_eq!(r.0, ["move 5,6", "Left down 5,6 #1", "Left up 5,6 #1", "Left down 5,6 #2", "Left up 5,6 #2"]);
    }

    #[test]
    fn combo_releases_in_reverse() {
        let mut r = Recorder::default();
        play(&mut r, &[InputEvent::Key { keys: "ctrl+shift+z".into() }]).unwrap();
        assert_eq!(r.0, ["Ctrl down", "Shift down", "Char('z') down", "Char('z') up", "Shift up", "Ctrl up"]);
    }

    /// 按下 `fails` 时报错，其余照记。
    struct FailsOn(Key, Recorder);

    impl Injector for FailsOn {
        fn move_to(&mut self, x: i32, y: i32) -> io::Result<()> {
            self.1.move_to(x, y)
        }
        fn button(&mut self, button: MouseButton, down: bool, x: i32, y: i32, clicks: u32) -> io::Result<()> {
            self.1.button(button, down, x, y, clicks)
        }
        fn scroll(&mut self, x: i32, y: i32, dx: i32, dy: i32) -> io::Result<()> {
            self.1.scroll(x, y, dx, dy)
        }
        fn key(&mut self, key: Key, down: bool) -> io::Result<()> {
            if down && key == self.0 {
                return Err(io::Error::other("blocked"));
            }
            self.1.key(key, down)
        }
        fn text(&mut self, text: &str) -> io::Result<()> {
            self.1.text(text)
        }
    }

    #[test]
    fn failed_combo_releases_pressed_keys() {
        let mut r = FailsOn(Key::Char('z'), Recorder::default());
        assert!(play(&mut r, &[InputEvent::Key { keys: "ctrl+shift+z".into() }]).is_err());
        assert_eq!(r.1.0, ["Ctrl down", "Shift down", "Shift up", "Ctrl up"]);
    }

    #[test]
    fn drag_ends_at_target() {
        let mut r = Recorder::default();
        play(&mut r, &[InputEvent::Drag { from: [0, 0], to: [120, 24], button: MouseButton::Right }]).unwrap();
        assert_eq!(r.0.first().unwrap(), "move 0,0");
        assert_eq!(r.0[1], "Right down 0,0 #1");
        assert_eq!(&r.0[r.0.len() - 2..], ["move 120,24", "Right up 120,24 #1"]);
    }

    #[test]
    fn click_without_target_is_rejected() {
        let mut r = Recorder::default();
        let click = InputEvent::Click { x: None, y: None, element: Some("1.2".into()), button: MouseButton::Left, count: 1 };
        assert!(play(&mut r, &[click]).is_err());
    }

    #[test]
    fn ascii_typing_uses_shift() {
        let mut r = Recorder::default();
        type_with_keys(&mut r, "A!").unwrap();
        assert_eq!(
            r.0,
            ["Shift down", "Char('a') down", "Char('a') up", "Shift up", "Shift down", "Char('1') down", "Char('1') up", "Shift up"]
        );
    }

    #[test]
    fn non_ascii_typing_uses_unicode_entry() {
        let mut r = Recorder::default();
        type_with_keys(&mut r, "é").unwrap();
        assert_eq!(
            r.0,
            [
                "Ctrl down", "Shift down", "Char('u') down", "Char('u') up", "Shift up", "Ctrl up",
                "Char('e') down", "Char('e') up", "Char('9') down", "Char('9') up", "Space down", "Space up"
            ]
        );
    }
}
