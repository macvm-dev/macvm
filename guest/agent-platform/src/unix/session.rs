//! Linux 上已登录的图形会话：代理是系统服务，要以会话用户身份才能接上它的会话总线。

pub(crate) struct Session {
    pub id: String,
    pub user: String,
    pub uid: String,
    /// 会话在前台（`STATE=active`），不是切到后台的另一个登录。
    pub active: bool,
    /// `wayland` 或 `x11`。
    pub kind: String,
}

impl Session {
    /// 接上这个会话的会话总线所需的环境变量（`KEY=VALUE`），连同会话类型 `XDG_SESSION_TYPE`。
    pub fn bus_env(&self) -> [String; 3] {
        [
            format!("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{}/bus", self.uid),
            format!("XDG_RUNTIME_DIR=/run/user/{}", self.uid),
            format!("XDG_SESSION_TYPE={}", self.kind),
        ]
    }
}

/// systemd-logind 在 `/run/systemd/sessions/<ID>` 里记录每个会话，格式为 KEY=VALUE 行。
pub(crate) fn graphical_sessions() -> Vec<Session> {
    let Ok(entries) = std::fs::read_dir("/run/systemd/sessions") else { return Vec::new() };
    entries
        .flatten()
        .filter_map(|entry| {
            let id = entry.file_name().into_string().ok()?;
            if id.contains('.') {
                return None;
            }
            parse(id, &std::fs::read_to_string(entry.path()).ok()?)
        })
        .collect()
}

fn parse(id: String, text: &str) -> Option<Session> {
    let field = |key: &str| text.lines().find_map(|l| l.strip_prefix(key)?.strip_prefix('=')).map(str::to_owned);
    let kind = field("TYPE").filter(|t| t == "wayland" || t == "x11")?;
    let user_class = field("CLASS").as_deref() == Some("user");
    let state = field("STATE");
    if !user_class || state.as_deref() == Some("closing") {
        return None;
    }
    Some(Session { id, user: field("USER")?, uid: field("UID")?, active: state.as_deref() == Some("active"), kind })
}

#[cfg(test)]
mod tests {
    #[test]
    fn parses_logind_session() {
        let text = "UID=1000\nUSER=ethan\nACTIVE=1\nSTATE=active\nTYPE=wayland\nCLASS=user\n";
        let s = super::parse("2".into(), text).unwrap();
        assert_eq!((s.user.as_str(), s.uid.as_str(), s.active), ("ethan", "1000", true));
        assert!(super::parse("3".into(), &text.replace("wayland", "tty")).is_none());
        assert!(super::parse("4".into(), &text.replace("active", "closing")).is_none());
    }
}
