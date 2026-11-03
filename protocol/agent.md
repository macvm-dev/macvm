# macvm-agent 协议

宿主连接客户机里的 `macvm-agent`。本文件是协议的唯一定义；`fixtures/` 中的样例由 Swift（`AgentProtocol`）与 Rust（`macvm-agent-protocol`）两侧测试共同校验。

## 传输

- Linux、macOS 客户机：代理监听 vsock 端口 **6100**（CID 任意）。
- Windows 客户机：没有可用的 vsock 驱动，代理监听 TCP 端口 **6100**，只接受源地址是客户机默认网关的连接（VZ 的 NAT 网关、QEMU 用户态网络的网关都是宿主）。安装时同时开放该端口的防火墙入站规则。
- 每个连接只承载一个请求。宿主先发一行 UTF-8 JSON（以 `\n` 结尾），代理回一行 JSON 响应。
- 响应 `{"ok":false,"error":"…"}` 表示失败，代理随后关闭连接。
- `exec` 与 `forward` 的成功响应之后，连接切换为下述各自的数据格式。

## 请求

所有请求都有字符串字段 `op`。

| op | 字段 | 成功响应 |
| --- | --- | --- |
| `info` | — | `{"ok":true,"info":{…}}`，见下 |
| `exec` | `argv`（字符串数组，必填），`user`，`cwd`，`env`（对象），`tty`（布尔），`cols`，`rows` | `{"ok":true}`，随后进入帧模式 |
| `forward` | `port`（客户机本地 TCP 端口） | `{"ok":true}`，随后为原始字节双向转发 |
| `shutdown` | `reboot`（布尔，默认 false） | `{"ok":true}` |
| `set-time` | `unix_ms`（整数） | `{"ok":true}` |
| `clipboard-get` | — | `{"ok":true,"text":"…"}` |
| `clipboard-set` | `text` | `{"ok":true}` |
| `mount` | `tag`，`path`，`read_only`（布尔） | `{"ok":true}`（仅 Linux：挂载 virtio-fs） |
| `display` | `width`，`height`（像素） | `{"ok":true}`（仅 Windows：设定主显示器与分辨率） |
| `cursor-watch` | — | `{"ok":true}`，随后每当客户机光标变化发一行光标形状，直到连接关闭（仅 Windows） |

`info` 的内容：

```json
{"version":"0.1.0","os":"linux","hostname":"dev","ipv4":["192.168.64.3"],"mem_total":2073000000,"mem_available":1800000000,"uptime_ms":123456}
```

`os` 取值 `linux`、`macos`、`windows`。内存单位为字节。

`display`：只用于 Windows。代理把 virtio-gpu 设为唯一的主显示器并切到该尺寸（引导垫片的帧缓冲在 Windows 里是另一块显示器，一并卸下），设置写入显示配置数据库。宿主在开机后代理上线时发送；VZ 下分辨率固定，见 `WindowsSupport.displaySize`。

`cursor-watch`：客户机用硬件光标时（QEMU 的 virtio-gpu），宿主用代理推送的形状作宿主光标。连上后先发当前光标，之后只在光标句柄或显隐变化时发：

```json
{"width":32,"height":32,"hot_x":0,"hot_y":0,"bgra":"…"}
{"hidden":true,"width":0,"height":0,"hot_x":0,"hot_y":0}
```

`bgra` 为逐像素 B G R A（非预乘 alpha）、自上而下的 Base64；`hidden` 为 true 时其余字段无意义，省略时为 false。客户机本次开机自绘光标（VZ 下，或未开硬件光标）时回错误响应。

Windows 3D 显卡驱动：宿主把 viogpu3d 驱动包平铺放在 `C:\ProgramData\macvm\viogpu3d`（含 `viogpu3d.inf`）。代理在非 VZ 下启动时，把它装到在场且还没用上 3D 驱动的 virtio-gpu 上，不经协议请求。

`exec` 经目标用户的登录 shell 执行 `argv`，环境与 SSH 登录一致；`user` 省略时为代理启动参数 `--user` 指定的用户，代理不是 root 时只能以自身身份执行。

## exec 帧模式

成功响应之后，双方以帧通信，直到代理发送 `exit` 帧并关闭连接：

```
u8 类型 | u32 小端长度 | 载荷
```

| 类型 | 方向 | 载荷 |
| --- | --- | --- |
| 0 `stdin` | 宿主 → 客户机 | 原始字节 |
| 1 `stdout` | 客户机 → 宿主 | 原始字节（`tty` 时也含 stderr） |
| 2 `stderr` | 客户机 → 宿主 | 原始字节 |
| 3 `resize` | 宿主 → 客户机 | JSON `{"cols":80,"rows":24}` |
| 4 `exit` | 客户机 → 宿主 | JSON `{"code":0}`；被信号终止时 `{"code":128+信号,"signal":9}` |
| 5 `stdin-eof` | 宿主 → 客户机 | 空 |

单帧载荷不超过 1 MiB。
