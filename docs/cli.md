# macvm CLI 契约

供脚本与其他程序（如 runode）调用。退出码表与错误码以 `macvm --help` 输出为准，由 `MacVMError` 生成。

## 输出

- 加 `--json` 时标准输出恰好一行：成功 `{"schemaVersion":1,"result":…}`，失败 `{"schemaVersion":1,"error":{"code":"…","message":"…"}}`。
- 不加 `--json` 时输出面向人阅读，格式不保证稳定。
- `exec`、`ssh`、`proxy` 不支持 `--json`：它们的标准输入输出属于客户机命令，`exec` 的退出码就是客户机命令的退出码。

## 命令

| 命令 | 作用 |
| --- | --- |
| `create <名> [--image ID \| --desktop ID [--manual-install] \| --iso 文件] [--os linux\|windows] [--engine vz\|qemu] [--network nat\|bridged[:网卡]] [--password 密码] [--product-key 密钥]` | 创建 Linux / Windows 虚拟机；`--network` 见下文「网络」，Windows 只能用 NAT 安装，且不接受 `--share`、`--rosetta`、`--headless`、`--console`、`--manual-install`；`--share 路径[:名称][:ro]` 的名称规则与 `set --add-share` 相同，不能与 `--engine qemu` 同用；`--user` 设置云镜像、自动安装的 Ubuntu 桌面版或 Windows 的登录用户名（默认与主机用户同名，主机用户名不合下列规则时须自己指定；用户名须为 1–20 个小写字母、数字或 `_ . -`、以字母或 `_` 开头，且不能是 root、administrator 等系统账户），`--password` 设置云镜像、自动安装的 Ubuntu 桌面版或 Windows 的登录密码（不能为空、首尾不能有空格、不能含换行等控制字符）并存进包内 `guest-password`（云镜像省略时只能用 SSH 密钥登录，Ubuntu 桌面版与 Windows 省略时随机生成），云镜像与 Windows 的 SSH 始终只认密钥，时区与主机相同；`--image` 的云镜像下载解包后缓存在下载目录的 `images/`，之后一直用这份、不再检查发行方是否更新，要换新版须删掉那里对应的 `.raw`；`--desktop ubuntu-desktop\|fedora-workstation` 下载发行方最新的 arm64 桌面版安装 ISO（校验 SHA-256，缓存在下载目录的 `iso/`）：Ubuntu 默认无人值守安装（缓存里另存一份内核参数带 `autoinstall` 的引导副本 `<名>.autoinstall.iso`，安装环境里关掉网络、只用安装盘里的软件包离线安装，不装更新；命令开机后等到装好的系统里的客户机代理响应才返回，安装盘与种子盘下次开机时卸下；需要随程序分发的 Linux 版客户机代理；装好即带登录用户、macvm 专用 SSH 公钥、免密 sudo 与客户机代理，系统语言为英文（en_US.UTF-8）、时区同主机、键盘为美式，之后卸下安装盘），加 `--manual-install` 则和 Fedora 一样开机后在窗口里完成图形安装；Windows 从原版 ISO 无人值守部署，不给 `--iso` 时从微软下载 Windows 11 ARM64 ISO（语言取系统首选语言里微软提供的第一个，都没有时用英语；缓存在下载目录的 `windows/`，下完新版后删掉旧的，仍被还没装完的虚拟机当安装介质的除外；问不到微软或微软拒绝时用缓存里的，缓存里也没有时报错，可到 https://www.microsoft.com/software-download/windows11arm64 手动下载后用 `--iso` 指定），给了 `--product-key` 则首次登录后用它联网激活（不给就停在通用密钥的未激活状态） |
| `set <名> [--engine vz\|qemu] [--cpus N] [--memory 8G] [--network nat\|bridged[:网卡]] [--display 宽x高] [--retina on\|off] [--clipboard on\|off] [--disk-size 256G] [--add-share 路径[:名称][:ro]]… [--remove-share 路径或名称]…` | 修改已关机虚拟机的配置，可切换引擎；运行中报 `already_running`，挂起时报 `invalid_config`。只改 `--retina` 时运行中也可，应用的画面窗口下次调整尺寸时生效（在应用里切换则立即生效）。`--clipboard` 开关应用窗口与客户机之间的文本剪贴板同步（默认开，客户机里的程序都能读到宿主上复制的内容）：macOS、Windows 客户机经客户机代理同步，窗口成为主窗口时交出宿主剪贴板、离开时取回客户机的，运行中也可修改；Linux 客户机经 spice-vdagent 同步（vz 引擎有画面时、自带的 QEMU），要关机后修改。`--disk-size` 只扩大系统盘镜像、不能缩小，客户机里的分区要另行扩展（云镜像建的 Linux 下次开机自动扩展）。共享目录只用于 vz 引擎的 macOS、Linux 客户机，名称缺省取目录名（Linux 只留 ASCII 字母数字与 `._-`，重名加 `-2`…），不超过 36 字节；先执行 `--remove-share` 再执行 `--add-share`，移除后加回即可改只读。有共享目录或开着 Rosetta 时不能切到 qemu（报 `unsupported`） |
| `screenshot <名> <文件>` | 保存画面为 PNG（QEMU 引擎；VZ 引擎报 `unsupported`）。自带的 QEMU 读画面的 IOSurface，要有过 GL 画面输出（开机早期的固件画面截不到） |
| `display <名> <宽>x<高>` | 调整运行中虚拟机的显示尺寸（VZ 引擎与自带的 QEMU；VZ 下 Windows 分辨率固定为 1024x768，不支持） |
| `install-macos <名> [--ipsw 文件] [--user 用户] [--password 密码] [--no-tune]` | 安装 macOS 虚拟机并开通 SSH 与代理，主机名设为虚拟机名、时区与主机相同，再执行 `tune` 的全部项；`--user` 的规则与 `create` 相同，`--password` 省略时随机生成，存在包内 `guest-password`；结果里的 `tuning` 是调优报告，跳过或出错时没有该字段，出错原因在 `tuningError`，安装本身仍算成功 |
| `ls` / `status <名>` | 列出 / 查看状态，结果为 `VMSummary` |
| `start <名>` / `run <名>` | 后台启动并在就绪后返回 / 前台运行到关机 |
| `wait <名>` | 等到代理（或 SSH）可用，未运行时自动启动 |
| `stop <名> [--force]` / `suspend <名>` | 关机 / 挂起 |
| `exec <名> [-t] [--cwd 目录] [--user 用户] -- 命令…` | 在客户机执行；`--user` 要经客户机代理，未装代理的虚拟机报 `unsupported` |
| `ssh <名>` / `proxy <名> [--port N]` | 登录 shell / ssh ProxyCommand |
| `ssh-config [--install]` | 生成 `~/.config/macvm/ssh_config`，主机名即虚拟机名 |
| `clone <源> <名>` / `snapshot save\|restore\|ls\|rm` | 克隆 / 快照 |
| `template save <虚拟机> [<模板>]` / `template ls` / `template rm <模板>` | 把已关机的虚拟机存为模板（模板名缺省与虚拟机同名；运行中报 `already_running`，挂起时报 `invalid_config`；不含快照）/ 列出模板，结果为 `TemplateSummary` 数组（`name`、`os`、`engine`、`cpuCount`、`memorySize`、`diskSize`、`path`）/ 删除模板。找不到模板报 `template_not_found` |
| `create <名> --template <模板> [--os 系统] [--cpus N] [--memory 8G] [--disk 128G] [--network nat\|bridged[:网卡]] [--engine vz\|qemu]` | 从模板新建任何系统的虚拟机（含 macOS）：复制模板的磁盘、配置、客户机密码与代理令牌，换新的机器标识与 MAC，云镜像建的 Linux 以新主机名重新初始化；`--disk` 只能比模板的大；给了 `--os` 而与模板不符时报 `invalid_config`；不能与 `--image`、`--desktop`、`--iso`、`--user`、`--password` 等决定系统与账户的选项同用 |
| `tune <名> [--skip 项]… [--revert] [--password 密码]` | 经 SSH 调整 macOS 客户机设置以降低空闲占用，项为 `spotlight`、`sleep`、`screensaver`、`updates`、`animations`、`transparency`；其中 `spotlight`、`sleep`、`updates` 要 root，用包内的客户机密码 sudo。结果为 `{applied, failed, reverted}`，单项失败只记进 `failed`，sudo 认证失败才整体报错；`--revert` 恢复系统默认 |
| `agent install\|info <名>` | 安装 / 查询客户机代理；用 qemu 引擎的 Windows 一并放进 3D 显卡驱动（需自带的 QEMU）。`info` 的 `features` 列出代理的可选能力（如 `ui`），旧代理没有这个字段 |
| `ui snapshot <名> [--app 应用] [--depth N] [--limit N]` | 读客户机桌面的无障碍树，见下文「UI 自动化」；结果为 `UISnapshot`（`screen`、`apps`、`app`、`nodes`、`truncated`），格式见代理协议的 `ui-snapshot` |
| `ui act <名> <元素> <动作> [--value 文本]` | 对快照里的元素执行动作：`press`、`focus`、`set-value`、`toggle`、`expand`、`collapse`、`select`、`scroll-into-view`、`show-menu`、`raise`；编号已失效或元素不支持该动作时报 `engine` |
| `ui click <名> (<x> <y> \| --element 元素) [--button left\|right\|middle] [--count N]` / `ui move <名> <x> <y>` / `ui drag <名> <x1> <y1> <x2> <y2> [--button …]` / `ui scroll <名> <x> <y> [--dx N] [--dy N]` | 注入鼠标；`--element` 点元素当前位置的中心，滚动单位是滚轮格，正值向右、向下 |
| `ui type <名> <文本>` / `ui key <名> <组合键>` | 输入文本 / 按组合键，如 `cmd+shift+t`、`enter` |
| `ui screenshot <名> <文件>` | 在客户机里截主屏存为 PNG，结果为 `{path, width, height}`；任何引擎都可用 |
| `ip <名>` / `rm <名>` / `doctor` | IP / 删除 / 检查本机能力 |

## 目录

虚拟机目录、下载目录与模板目录在 App 设置里更改，存在 `~/Library/Application Support/MacVM/settings.json`（字段 `libraryPath`、`downloadPath`、`templatePath`，缺省即默认），CLI 读同一个文件。

| 目录 | 默认 | 覆盖顺序 |
| --- | --- | --- |
| 虚拟机 | `~/Library/Application Support/MacVM/VMs` | 环境变量 `MACVM_HOME` > `libraryPath` > 默认 |
| 下载（`ipsw/`、`images/`、`iso/`、`windows/`、`virtio-win/`） | `~/Library/Caches/MacVM` | `downloadPath` > 默认 |
| 模板 | `~/Library/Application Support/MacVM/Templates` | `templatePath` > 默认 |

模板目录与虚拟机目录在同一 APFS 卷上时，存模板与从模板新建都是零拷贝；不在同一卷时整盘复制。

`doctor --json` 的结果里有 `libraryPath`、`downloadPath` 与 `templatePath`，是当前实际生效的位置。

## 引擎

| | vz（默认） | qemu |
| --- | --- | --- |
| 依赖 | 无 | App 自带（macOS 27 起）；否则 `brew install qemu` |
| 资源占用 | 最低 | 多一个 QEMU 进程 |
| macOS 客户机 | 支持 | 不支持 |
| Windows 声音 | 无 | 有 |
| 挂起 | macOS；Linux 只在无画面时 | 只有 Homebrew 的 QEMU：自带的 QEMU 显卡用 virgl，QEMU 不能迁移它的状态，挂起报 `unsupported` |
| 共享目录（virtio-fs） | 支持 | 不支持 |
| 客户机端口访问 | vsock、客户机 IP | NAT 下只有 22 与代理端口，经 Unix socket 转发；桥接下直连客户机 IP |
| 画面 | 只能在运行它的进程里显示 | 经 Unix socket 提供，应用可接上 `macvm start` 启动的虚拟机。自带的 QEMU 用 SPICE + GL（画面经 IOSurface 共享，`screenshot` 读这块 IOSurface）；Homebrew 的用 VNC，`run --display` 另开 QEMU 窗口 |
| Linux 分辨率 | 跟随窗口大小（按点数，最小 800x600，画面放大显示；`--retina on` 时按屏幕像素，有客户机代理时把 GNOME 的缩放倍数调到屏幕倍数，没有代理时 Retina 屏上界面会变小，要在客户机里调缩放） | 自带的 QEMU 下与 Windows 一样跟随窗口，有客户机代理时同样调 GNOME 的缩放倍数；Homebrew 的 QEMU 由客户机设定 |
| Windows 分辨率 | 固定 1024x768，随窗口缩放 | 自带的 QEMU 装了 viogpu3d 时跟随窗口大小（按点数，最小 800x600；`--retina on` 时按屏幕像素，并把 Windows 缩放比例调到相同倍数，新装的 Windows 带代理与 viogpu3d 时默认开；总像素不超过约 780 万）；否则由客户机设定 |
| Windows 光标 | 客户机自绘 | 宿主的 macOS 光标，跟手无延迟：Windows 的系统光标换成 macOS 的同类光标（输入、手形、调整大小等，没有同类的用箭头）。viogpu3d 不支持硬件光标，代理在画面打开期间把客户机的系统光标换成透明的；程序自带的光标仍由客户机画（viogpudo 下按原图显示） |
| Windows 3D | 无 | 自带的 QEMU 下装 viogpu3d（Direct3D 11.1，桌面合成用 GPU）；装上后只能用自带的 QEMU 运行，不能再改用 vz。驱动要与 App 自带的图形组件配套，每次开机后自动推送，换了驱动就自动重启客户机 |

Windows 总是先用 qemu 部署，装好后可 `macvm set win --engine vz` 改用 vz 运行。

## 网络

| 模式 | 写法 | 说明 |
| --- | --- | --- |
| NAT（默认） | `nat` | 客户机在主机内置的 NAT 网络里，IP 从主机 DHCP 服务的租约里查 |
| 桥接 | `bridged[:网卡]` | 客户机直接接入主机网卡（BSD 名，如 `en0`，可用的见 `doctor`）所在的局域网，从局域网的路由器取得地址；不写网卡时开机桥接到第一块可桥接的网卡。两种引擎都支持 |

桥接要用到随 App 安装的网络辅助程序 macvm-netd：在 App 的设置里启用，再到「系统设置 › 通用 › 登录项与扩展」里允许 MacVM；`doctor` 的 `bridgedNetworking` 为 true 时可用。没启用就开机报 `unsupported`。macvm-netd 只接受同一个 App 包里的 App 与自带的 `macvm`（App 里 `Contents/Resources/bin/macvm`，或指向它的链接），另行构建的 `macvm` 连不上它，用不了桥接。桥接下宿主不是客户机的默认网关，Linux（QEMU 引擎）与 Windows 的客户机代理要靠共享令牌认证宿主：新建的虚拟机自带令牌，之前建的要先运行一次 `macvm agent install <名>` 更新代理并写入令牌，否则桥接下 `exec` 等经代理的操作会被拒绝（SSH 不受影响）。客户机里有令牌后，代理经 TCP 的连接不论哪种网络都要认证。桥接下 IP 是从客户机发出的 ARP 里认出来的，客户机开机拿到地址前 `ip` 查不到。改网络只能在关机时；MAC 地址保持不变。

## UI 自动化

`ui` 子命令经客户机代理操作客户机桌面，三种客户机系统、两种引擎都可用，适合给 computer-use 一类的代理程序调用：先 `ui snapshot` 拿到元素编号与位置，再用 `ui act` 或 `ui click --element` 操作，`ui screenshot` 核对结果。

- 坐标一律是 `ui screenshot` 截图的像素，原点在主屏左上角；`snapshot` 里的 `bounds` 用同一套坐标，`screen.scale` 是客户机坐标单位到像素的倍数。
- 元素编号至少在下一次 `snapshot` 之前有效；失效后操作报 `engine`，要重新快照。
- 虚拟机要在运行，不会自动开机；没装代理或代理版本过旧（`agent info` 里的 `features` 没有 `ui`）时报 `unsupported`，运行 `macvm agent install <名>` 更新。
- macOS 客户机要在「系统设置 › 隐私与安全性」里给 MacVM Agent「辅助功能」（快照、动作、输入）与「屏幕录制」（截屏）权限；没给时报 `permission_denied`（退出码 22），代理每次启动后第一次缺权限时让客户机弹出系统的授权提示。授权后第一次调用回「正在重启以载入授权」：代理进程看不到启动后才授予的权限，会自行重启（中断当时的 exec 与端口转发），几秒后重试即可；系统设置里的「退出并重新打开」不起作用，点「稍后」。权限跟着代理的代码签名：同一团队 ID 签名的代理更新后授权保留，ad-hoc 签名的每次重编后要重新授权。代理注入的输入不算用户活动，客户机显示器仍按节能设置休眠；快照、输入与截屏会先唤醒显示器并等画面亮起来（约两秒）。
- Linux 客户机要有已登录的图形会话；第一次快照时代理打开会话的无障碍支持，之前已在运行的部分应用要重启后才看得到。`type` 里的非 ASCII 字符用 ctrl+shift+u 加十六进制码输入，GTK、Qt（经 IBus）程序、终端与浏览器认，别的程序要用 `act --value`。Wayland 下除 GNOME Shell 自己的界面（顶栏、程序坞）外元素没有 `bounds`，`click --element` 报 `engine`，要用 `act` 或按截图坐标点击。自带的 QEMU 用 virgl 时画面在宿主 GPU 上，`screenshot` 改由运行 QEMU 的进程从画面的 IOSurface 截取。客户机闲置息屏时 `screenshot` 报错，先用 `key` 或 `move` 唤醒；息屏期间输入坐标仍按显示器的首选分辨率换算。
- Windows 客户机：UAC 等安全桌面上的窗口收不到输入。

## 与 runode 配合

- 把虚拟机当远端主机：`macvm ssh-config --install`，runode 读取 `~/.ssh/config` 后列出各虚拟机名。连接经 `macvm proxy` 走 vsock，虚拟机未运行时自动启动。
- 在面板里开客户机 shell：`runode open --right -- macvm exec dev -t`。
- 任务板的 agent 前缀：`macvm exec dev -t --cwd <客户机路径> --`，配合 `create --share 目录` 让项目目录在客户机里可见。`--cwd` 原样交给客户机，不做路径换算：共享目录在 Linux 客户机里挂在 `/mnt/<名称>`（创建时就有的共享目录开机自动挂载），macOS 客户机里在 `/Volumes/My Shared Files/<名称>`，与宿主上的路径不同，不能直接写 `"$PWD"`。
