# macvm-agent 协议

宿主连接客户机里的 `macvm-agent`。本文件是协议的唯一定义；`macvm-agent-protocol` 的 `fixtures/` 中的样例由 Swift（`AgentProtocol`）与 Rust（`macvm-agent-protocol`）两侧测试共同校验。

## 传输

- Linux、macOS 客户机：代理监听 vsock 端口 **6100**（CID 任意）。Linux 上没有 virtio vsock 设备时（QEMU 引擎）改为监听 TCP 端口 **6100**，规则同下面的 Windows，宿主经用户态网络转发连这个端口；有 vsock 设备时不监听 TCP。
- Windows 客户机：没有可用的 vsock 驱动，代理监听 TCP 端口 **6100**。安装时同时开放该端口的防火墙入站规则。
- 客户机里有共享令牌时，所有 TCP 连接（包括经 QEMU 用户态网络转发进来的）都先过下面的「认证」：桥接网络下默认网关是局域网路由器，它的地址也可能被局域网里的机器冒用，不能凭来源认出宿主。vsock 连接不认证。
- 客户机里没有令牌时，只受理源地址是客户机默认网关的 TCP 连接（VZ 的 NAT 网关、QEMU 用户态网络的网关都是宿主），其他来源直接关闭。
- 每个连接只承载一个请求。宿主先发一行 UTF-8 JSON（以 `\n` 结尾），代理回一行 JSON 响应。
- 响应 `{"ok":false,"error":"…"}` 表示失败，代理随后关闭连接。
- `exec` 与 `forward` 的成功响应之后，连接切换为下述各自的数据格式。

## 认证

宿主与代理共享一个令牌（64 位十六进制小写）。宿主存在包内 `agent-token`（0600）；客户机里在 Linux 是 `/etc/macvm-agent/token`（root，0600），Windows 是 `C:\ProgramData\macvm\agent-token`（所在目录归 Administrators，只有 SYSTEM 与 Administrators 能访问；安装时目录或其中某项的所有者不可信就整个挪开重建）。创建虚拟机与 `macvm agent install` 时写入两边。

1. 代理接受连接后先发一行 `{"challenge":"<64 位十六进制>"}`，内容每次随机。客户机里没有令牌时不发，直接关闭连接。
2. 宿主回一行 `{"auth":"<HMAC-SHA256>"}`：以令牌的 UTF-8 字节为密钥、对 `challenge` 字符串的 UTF-8 字节计算，十六进制小写。
3. 应答不对时代理回 `{"ok":false,"error":"认证失败"}` 后关闭；对了不回，接着按下文读请求。代理等应答最多 10 秒。

样例在 `fixtures/auth.jsonl`（`token`、`challenge`、`auth`）。

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
| `display-scale` | `percent`（整数，100 为不缩放） | `{"ok":true}`（Windows、Linux：设定显示器的缩放比例；macOS 不支持） |
| `gpu-driver` | `sha256`（驱动包 zip 的 SHA-256，十六进制），`size`（字节数） | 已有同一个包时 `{"ok":true,"text":"current"}`；否则 `{"ok":true,"text":"send"}`，收下随后的 `size` 字节并安装后再回 `{"ok":true,"text":"installed"}` 或 `"unchanged"`（仅 Windows） |
| `trim-cache` | `keep`（字节数） | `{"ok":true}`（仅 Linux：把文件页缓存回收到约 `keep`） |
| `cursor-watch` | — | `{"ok":true}`，随后每当客户机光标变化发一行光标形状，直到连接关闭（仅 Windows） |

`info` 的内容：

```json
{"version":"0.1.0","os":"linux","hostname":"dev","ipv4":["192.168.64.3"],"mem_total":2073000000,"mem_available":1800000000,"uptime_ms":123456}
```

`os` 取值 `linux`、`macos`、`windows`。内存单位为字节。

`display`：只用于 Windows。代理把 virtio-gpu 设为唯一的主显示器并切到该尺寸（引导垫片的帧缓冲在 Windows 里是另一块显示器，一并卸下），设置写入显示配置数据库。宿主在开机后代理上线时发送；VZ 下分辨率固定，见 `WindowsSupport.displaySize`。

`display-scale`：Windows 上代理把每个活动显示器的缩放比例设为 Windows 支持的档位里不超过 `percent` 的最大一档，立即生效并记入当前用户的设置。Linux 上代理把 `percent` 四舍五入成 1–4 倍，写进每个图形会话用户的 GNOME 设置 `org.gnome.desktop.interface scaling-factor`，并用 `gdctl` 立即应用（没有 `gdctl` 的旧版 GNOME 在下次分辨率变化时生效）；之后登录的会话也会补上。宿主在高分辨率（Retina）画面下按窗口所在屏幕的像素倍数发送，关掉时发 100。

`trim-cache`：代理经 cgroup v2 根组的 `memory.reclaim` 按 LRU 回收文件页（`Active(file)` 与 `Inactive(file)`），回收到约 `keep` 字节为止，超出不足 64 MiB 时不回收；内核支持 `swappiness=0` 参数时不换出匿名页，否则按系统的 swappiness 回收。内核回收不到要求的量时仍回成功。QEMU 下自带的 QEMU 把客户机经气球上报的空闲页还给宿主，页缓存不算空闲，宿主为装有代理的 Linux 客户机定期发送这个请求，腾出的页随之上报；代理回错误后不再发送。

`cursor-watch`：QEMU 下宿主按代理推送的光标显示宿主光标。系统光标只推种类（`system`），宿主换成自己的同类光标；其余光标在客户机用硬件光标（viogpudo）时推图像。客户机没有硬件光标（viogpu3d）时，连接期间代理把系统光标换成透明的，其余光标推送 `hidden`、由客户机画，最后一个连接关闭时恢复系统光标。连上后先发当前光标，之后只在光标句柄或显隐变化时发：

```json
{"width":32,"height":32,"hot_x":0,"hot_y":0,"bgra":"…"}
{"hidden":true,"width":0,"height":0,"hot_x":0,"hot_y":0}
{"width":0,"height":0,"hot_x":0,"hot_y":0,"system":"ibeam"}
```

`bgra` 为逐像素 B G R A（非预乘 alpha）、自上而下的 Base64；`hidden` 为 true 时其余字段无意义，省略时为 false。`system` 取值：`arrow`、`ibeam`、`wait`、`crosshair`、`uparrow`、`sizenwse`、`sizenesw`、`sizewe`、`sizens`、`sizeall`、`no`、`hand`、`appstarting`、`help`、`pin`，宿主不认识的种类按箭头显示。VZ 下回错误响应；用硬件光标时运行中换上 viogpu3d，连接随即关闭，宿主重连后按 viogpu3d 的方式推送。

Windows 3D 显卡驱动：宿主把 viogpu3d 驱动包平铺放在 `C:\ProgramData\macvm\viogpu3d`（含 `viogpu3d.inf`）。代理在非 VZ 下启动时，若在场 virtio-gpu 当前驱动的 INF 与包里的不同，就把包里的强制装上（驱动要与宿主的图形组件配套，降级也装）。开了 3D 加速的虚拟机每次开机后，宿主经 `gpu-driver` 把自带的驱动包推过来，代理替换该目录并立即安装，目录里的 `.macvm-package` 记着包的 SHA-256；换了驱动时宿主随即请代理重启客户机，桌面合成重启后才用上新驱动。

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
