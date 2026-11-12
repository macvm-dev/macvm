# macvm-agent 协议

宿主连接客户机里的 `macvm-agent`。本文件是协议的唯一定义；`macvm-agent-protocol` 的 `fixtures/` 中的样例由 Rust（`macvm-agent-protocol`）测试全部校验；Swift（`AgentProtocol`）测试同样读取请求（`requests.jsonl`）、响应（`responses.jsonl`）、光标（`cursors.jsonl`）、UI 快照（`ui.jsonl`）与认证（`auth.jsonl`）样例，其中响应与快照只校验能否解码。

## 传输

- Linux、macOS 客户机：代理监听 vsock 端口 **6100**（CID 任意）。Linux 上没有 virtio vsock 设备时（QEMU 引擎）改为监听 TCP 端口 **6100**，规则同下面的 Windows，宿主经用户态网络转发连这个端口；有 vsock 设备时不监听 TCP。
- Windows 客户机：没有可用的 vsock 驱动，代理监听 TCP 端口 **6100**。安装时同时开放该端口的防火墙入站规则。
- 客户机里有共享令牌时，所有 TCP 连接（包括经 QEMU 用户态网络转发进来的）都先过下面的「认证」：默认网关就是宿主，宿主上任何进程（包括其他用户的）连进来都显示为来自网关，不能凭来源认出 MacVM。vsock 连接不认证。
- 客户机里没有令牌时，只受理源地址是客户机默认网关的 TCP 连接（VZ 的 NAT 网关、QEMU 用户态网络的网关都是宿主），其他来源直接关闭。
- 每个连接只承载一个请求。宿主先发一行 UTF-8 JSON（以 `\n` 结尾），代理回一行 JSON 响应。
- 响应 `{"ok":false,"error":"…"}` 表示失败，代理随后关闭连接。失败响应可以带机器可读的 `code`：`permission` 表示客户机系统没给代理所需的权限（如 macOS 的辅助功能、屏幕录制），要在客户机里授权；`restarting` 表示代理回完这个响应就退出、由客户机的服务管理器重新拉起，宿主等新代理上线后重试同一请求。
- 成功响应带 `size` 时，响应行之后紧跟 `size` 字节的正文，正文不超过 64 MiB。
- `exec` 与 `forward` 的成功响应之后，连接切换为下述各自的数据格式。

## 认证

宿主与代理共享一个令牌（64 位十六进制小写）。宿主存在包内 `agent-token`（0600）；客户机里在 Linux 是 `/etc/macvm-agent/token`（root，0600），Windows 是 `C:\ProgramData\macvm\agent-token`（所在目录归 Administrators，只有 SYSTEM 与 Administrators 能访问；安装时目录或其中某项的所有者不可信就整个挪开重建）。创建虚拟机与 `macvm agent install` 时写入两边。

1. 代理接受连接后先发一行 `{"challenge":"<64 位十六进制>"}`，内容每次随机。客户机里没有令牌时不发质询：来源是默认网关的连接直接按下文读请求，其他来源直接关闭。宿主包里有令牌而客户机里没有时，宿主等不到质询，要等到超时才失败。
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
| `clipboard-get` | — | `{"ok":true,"text":"…"}`；剪贴板里有文件时带 `files`（macOS、Windows） |
| `clipboard-set` | `text` | `{"ok":true}` |
| `mount` | `tag`，`path`，`read_only`（布尔） | `{"ok":true}`（仅 Linux：挂载 virtio-fs） |
| `display` | `width`，`height`（像素） | `{"ok":true}`（仅 Windows：设定主显示器与分辨率） |
| `display-scale` | `percent`（整数，100 为不缩放） | `{"ok":true}`（Windows、Linux：设定显示器的缩放比例；macOS 不支持） |
| `gpu-driver` | `sha256`（驱动包 zip 的 SHA-256，十六进制），`size`（字节数） | 已有同一个包时 `{"ok":true,"text":"current"}`；否则 `{"ok":true,"text":"send"}`，收下随后的 `size` 字节并安装后再回 `{"ok":true,"text":"installed"}` 或 `"unchanged"`（仅 Windows） |
| `trim-cache` | `keep`（字节数） | `{"ok":true}`（仅 Linux：把文件页缓存回收到约 `keep`） |
| `cursor-watch` | — | `{"ok":true}`，随后每当客户机光标变化发一行光标形状，直到连接关闭（仅 Windows） |
| `ui-snapshot` | `app`（pid、进程名，macOS 上也可以是 bundle id；省略时为前台应用），`max_depth`（默认 40），`max_nodes`（默认 2000） | `{"ok":true,"size":N}`，正文是 UI 快照的 JSON，见「UI 自动化」 |
| `ui-action` | `element`（快照里的元素编号），`action`，`value`（`set-value` 时必填） | `{"ok":true}` |
| `ui-input` | `events`（输入事件数组，按顺序注入） | `{"ok":true}` |
| `ui-screenshot` | — | `{"ok":true,"size":N}`，正文是主屏 PNG |
| `files-put` | `to`（`dir`、`drop`、`clipboard`），`path`（`to` 为 `dir` 时必填），`x`、`y`（`to` 为 `drop` 时可选） | `{"ok":true}`，随后宿主发文件流，代理收完再回 `{"ok":true,"files":[…]}`，见「复制文件」 |
| `files-get` | `paths`（客户机上的绝对路径数组） | `{"ok":true,"total":N}`，随后代理发这些路径的文件流 |
| `drag-files` | — | `{"ok":true,"files":[…],"serial":N}`，见「复制文件」（macOS、Windows） |

`info` 的内容：

```json
{"version":"0.1.0","os":"linux","hostname":"dev","ipv4":["192.168.64.3"],"mem_total":2073000000,"mem_available":1800000000,"uptime_ms":123456}
```

`os` 取值 `linux`、`macos`、`windows`。内存单位为字节。`exe_sha256` 是代理可执行文件的指纹（SHA-256 的小写十六进制，macOS 版是代理 App 包里的可执行文件），读不到自身时省略：带代码签名的 64 位 Mach-O 取 `LC_CODE_SIGNATURE` 指向的签名 SuperBlob 里 0 号槽 CodeDirectory 的 SHA-256（签名时间不在其中，同样的代码重签后不变），其余取整个文件的 SHA-256；宿主拿它比对随 App 分发的代理，不同或省略即为可更新。

更新经 `exec` 完成，不另设请求，旧代理也能这样更新：宿主执行更新脚本，标准输入送新代理（macOS 版是代理 App 包的 tar），脚本换掉文件后交给客户机的服务管理器重启代理（Linux 以 root 执行、`systemctl restart --no-block`；macOS 以登录用户执行、重新加载 LaunchAgent；Windows 交给以 SYSTEM 运行的一次性计划任务 `macvm-agent-update` 停下代理、重新注册并启动）。代理可能在发出 `exit` 帧之前就被重启，宿主据 `exe_sha256` 变成新值判断更新完成。`features` 列出可选能力，没有时省略；`ui` 表示支持 `ui-*` 请求，`files` 表示支持 `files-put`、`files-get` 与 `clipboard-get` 里的文件，`drag` 表示支持 `drag-files`。代理对不认识的 `op` 回失败响应，宿主按 `features` 判断代理是否支持某项能力。

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

## UI 自动化

`ui-*` 请求读客户机桌面的无障碍树（macOS 的 AX、Windows 的 UI Automation、Linux 的 AT-SPI）、对元素执行动作、注入鼠标键盘与截屏。坐标一律是 `ui-screenshot` 截图的像素，原点在主屏左上角，客户机坐标与像素之间的换算由代理负责。

`ui-snapshot` 的正文（样例在 `fixtures/ui.jsonl`）：

```json
{"screen":{"width":3840,"height":2400,"scale":2.0},
 "apps":[{"pid":412,"name":"Finder","bundle":"com.apple.finder","frontmost":true}],
 "app":{"pid":412,"name":"Finder","bundle":"com.apple.finder","frontmost":true},
 "nodes":[{"id":"3.0","depth":0,"role":"AXApplication","name":"Finder"},
          {"id":"3.2","depth":1,"role":"AXButton","subrole":"AXCloseButton","bounds":[220,120,28,28],"actions":["press"]}],
 "truncated":true}
```

- `screen.scale` 是每个客户机坐标单位（macOS 的点、Windows 的 96 DPI 像素、Wayland 下 GNOME 的逻辑像素）对应的截图像素数；`bounds` 已按它换算成截图像素。
- `apps` 是有窗口的应用；`app` 是本次快照的应用，没有前台应用时省略，`nodes` 为空。
- `nodes` 按先序排列，父子关系由 `depth` 表达；Windows 上应用的每个顶层窗口（含任务栏、桌面与对话框）各是一个 `depth` 为 0 的元素。遍历到 `max_depth` 或 `max_nodes` 时 `truncated` 为 true，否则省略。
- `id` 对宿主不透明，至少在同一代理的下一次快照之前有效；失效时 `ui-action` 回失败，要重新快照。
- `role` 是客户机系统的原名（AXButton、UIA 的 ControlType 名、AT-SPI 的 role 名），`subrole` 在 macOS 上是 AXSubrole、在 Windows 上是窗口类名。`name`、`value`、`description`、`bounds`（`[x,y,宽,高]`）没有时省略，`value` 最多 2000 个字符。
- `states` 取值 `focused`、`disabled`、`selected`、`checked`、`expanded`、`offscreen`，`actions` 是元素支持的动作，都没有时省略。

`ui-action` 的 `action` 取值：`press`、`focus`、`set-value`、`toggle`、`expand`、`collapse`、`select`、`scroll-into-view`、`show-menu`、`raise`。快照里没列出的动作也可以请求，元素不支持时回失败。

`ui-input` 的事件按 `type` 区分：

| `type` | 字段 |
| --- | --- |
| `move` | `x`，`y` |
| `click` | `x`、`y`，或 `element`（点元素当前位置的中心）；`button`（`left`、`right`、`middle`，默认 `left`），`count`（默认 1） |
| `drag` | `from`、`to`（`[x,y]`），`button` |
| `scroll` | `x`，`y`，`dx`、`dy`（滚轮格数，正值向右、向下，默认 0） |
| `key` | `keys`：组合键，如 `cmd+shift+t`、`enter`。修饰键 `cmd`（Windows 为 Win 键，Linux 为 Super）、`ctrl`、`alt`（`option`）、`shift` 在前，最后是主键：`enter`、`tab`、`esc`、`space`、`backspace`、`delete`、`up`、`down`、`left`、`right`、`home`、`end`、`pageup`、`pagedown`、`f1`–`f12`，或美式键盘上不按 Shift 时的字符 |
| `text` | `text`：逐字输入；Linux 上 ASCII 按美式布局按键，其余字符用 ctrl+shift+u 加十六进制码输入（GTK、IBus 支持的程序才认） |

各系统的前提：

- macOS：代理要有「辅助功能」权限才能读树、执行动作与注入输入，要有「屏幕录制」权限才能截屏；缺权限时回 `code` 为 `permission` 的失败响应，每个代理进程只在第一次缺权限时让客户机弹出系统的授权提示。代理进程看不到它启动后才授予的权限：这时它回 `code` 为 `restarting` 的失败响应并退出，由 launchd 重新拉起，宿主等新代理上线后自动重试一次。权限跟着代理 App 的代码签名，换了签名要重新授权。
- Windows：输入经 `SendInput`。代理以登录用户身份运行，碰不到 UAC 提示、锁屏与登录界面所在的安全桌面：输入桌面不是代理所在的桌面时，代理把 `ui-snapshot`、`ui-input`、`ui-screenshot` 转给以 SYSTEM 身份在控制台会话里运行的桌面助手，助手切到当时的输入桌面处理。助手给出的元素编号以 `s` 开头，对这些元素的请求也由助手处理。
- Linux：要有已登录的图形会话。代理以会话用户身份读 AT-SPI，并打开会话的无障碍支持，在此之前就已运行的部分应用要重启后才导出无障碍树；元素编号是 AT-SPI 对象的总线名加路径，跨快照有效，直到应用销毁该对象。输入经 uinput 虚拟设备（代理启动时建好），截屏经 DRM 读取扫描输出的帧缓冲，QEMU 开了 3D 加速时可能读不到画面。Wayland 下应用不知道自己窗口在屏幕上的位置，除 GNOME Shell 自己的界面外，元素都没有 `bounds`，按 `element` 点击回失败。

`exec` 经目标用户的登录 shell 执行 `argv`，环境与 SSH 登录一致；`user` 省略时为代理启动参数 `--user` 指定的用户，代理不是 root 时只能以自身身份执行。

## 复制文件

`files` 是文件与目录的数组，每项 `{"path":"C:\\Users\\me\\a.txt"}`，目录带 `"dir":true`；`path` 是客户机上的绝对路径。

`files-put` 的 `to`：

- `dir`：放进 `path` 指定的已有目录，不是目录时直接回失败。
- `drop`：放到投放点下的文件夹窗口里。`x`、`y` 是投放点占主屏宽、高的比例（0–1）。macOS 上点在访达窗口上时取该窗口的文件夹（读 AX 的 `AXDocument`，代理要有辅助功能权限），Windows 上点在资源管理器窗口上时取它当前标签页的文件夹；其他情况（点在桌面或别的程序上、省略 `x`、`y`、认不出、Linux）放到登录用户的桌面目录，没有桌面目录时放到用户目录。
- `clipboard`：放进新的暂存目录（客户机临时目录下的 `macvm-clipboard`，以前的暂存一并删掉），收完把剪贴板换成这些文件，在访达或资源管理器里粘贴即复制（Windows 上是 CF_HDROP，粘贴效果为复制）。Linux 回失败。

与目标目录里已有项重名的顶层项编号改名：`a.txt` → `a 2.txt`，Windows 上为 `a (2).txt`，目录与以点开头、没有其他点的名字不拆扩展名。Windows 上文件名里的 `<>:"|?*` 与控制字符换成 `_`，去掉末尾的点与空格，`CON`、`NUL` 一类设备名前加 `_`。Linux 上代理以 root 运行，新建的项归目标目录的所有者。收的过程中出错时代理删掉这次已建的顶层项，回失败响应并关闭连接。

`drag-files`：客户机里正在拖动的文件。macOS 版读拖放剪贴板，带 `serial`（拖放剪贴板的变更计数）与其中的文件，不判断拖动是否仍在进行：拖放结束后内容仍留着，宿主在按下鼠标时取一次 `serial`、拖出画面时再取，变了才说明这次按下开始了拖动。Windows 版在虚拟屏幕上临时铺一层几乎透明的投放窗口并把光标左右挪一个像素，让系统的拖放循环把数据交给它，读出 CF_HDROP 后总是拒绝投放，等不到时 `files` 省略；不带 `serial`。宿主接手后在客户机里按 Esc 取消原来的拖动。

### 文件流

帧格式与下文 exec 帧相同（`u8 类型 | u32 小端长度 | 载荷`，载荷不超过 1 MiB）：

| 类型 | 载荷 |
| --- | --- |
| 0 `entry` | JSON 条目，见下 |
| 1 `data` | 上一个 `file` 条目的内容，各帧合计正好 `size` 字节 |
| 2 `end` | 空，流正常结束 |
| 3 `error` | UTF-8 的原因，发送方中止 |

条目：`{"path":"目录/sub/a.txt","kind":"file","size":6,"mode":420,"mtime_ms":1793660000000}`。`path` 以 `/` 分隔，第一段是顶层项的名字，各段不能为空、`.`、`..`，不能含 `\` 或 NUL；`kind` 取 `dir`、`file`、`link`；`size` 是 `file` 的字节数，0 时省略；`mode` 是 Unix 权限位（`0o777` 以内），Windows 发送时省略、接收时忽略；`mtime_ms` 是修改时间（Unix 毫秒）；`link` 带 `target`，原样保存。条目先序排列，除顶层项外每项的上级必须是这次流里已收到的 `dir`，链接不能当上级，接收方据此保证写不到目标目录之外。发送方不跟随链接，Windows 上跳过链接，其余特殊文件都跳过；接收方是 Windows 时跳过 `link`。

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
