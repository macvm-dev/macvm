# macvm CLI 契约

供脚本与其他程序（如 runode）调用。退出码表与错误码以 `macvm --help` 输出为准，由 `MacVMError` 生成。

## 输出

- 加 `--json` 时标准输出恰好一行：成功 `{"schemaVersion":1,"result":…}`，失败 `{"schemaVersion":1,"error":{"code":"…","message":"…"}}`。
- 不加 `--json` 时输出面向人阅读，格式不保证稳定。
- `exec`、`ssh`、`proxy` 不支持 `--json`：它们的标准输入输出属于客户机命令，`exec` 的退出码就是客户机命令的退出码。

## 命令

| 命令 | 作用 |
| --- | --- |
| `create <名> [--image ID \| --iso 文件] [--os linux\|windows] [--engine vz\|qemu] [--product-key 密钥]` | 创建 Linux / Windows 虚拟机；Windows 从原版 ISO 无人值守部署，给了 `--product-key` 则首次登录后用它联网激活（不给就停在通用密钥的未激活状态） |
| `set <名> [--engine vz\|qemu] [--cpus N] [--memory 8G] [--display 宽x高] [--retina on\|off]` | 修改已停止虚拟机的配置，可切换引擎；只改 `--retina` 时运行中也可，应用的画面窗口下次调整尺寸时生效（在应用里切换则立即生效） |
| `screenshot <名> <文件>` | 保存画面为 PNG（QEMU 引擎） |
| `display <名> <宽>x<高>` | 调整运行中虚拟机的显示尺寸（VZ 引擎与自带的 QEMU；VZ 下 Windows 分辨率固定为 1024x768，不支持） |
| `install-macos <名> [--ipsw 文件]` | 安装 macOS 虚拟机并开通 SSH 与代理 |
| `ls` / `status <名>` | 列出 / 查看状态，结果为 `VMSummary` |
| `start <名>` / `run <名>` | 后台启动并在就绪后返回 / 前台运行到关机 |
| `wait <名>` | 等到代理（或 SSH）可用，未运行时自动启动 |
| `stop <名> [--force]` / `suspend <名>` | 关机 / 挂起 |
| `exec <名> [-t] [--cwd 目录] [--user 用户] -- 命令…` | 在客户机执行 |
| `ssh <名>` / `proxy <名> [--port N]` | 登录 shell / ssh ProxyCommand |
| `ssh-config [--install]` | 生成 `~/.config/macvm/ssh_config`，主机名即虚拟机名 |
| `clone <源> <名>` / `snapshot save\|restore\|ls\|rm` | 克隆 / 快照 |
| `agent install\|info <名>` | 安装 / 查询客户机代理；用 qemu 引擎的 Windows 一并放进 3D 显卡驱动（需自带的 QEMU） |
| `ip <名>` / `rm <名>` / `doctor` | IP / 删除 / 检查本机能力 |

## 引擎

| | vz（默认） | qemu |
| --- | --- | --- |
| 依赖 | 无 | App 自带（macOS 27 起）；否则 `brew install qemu` |
| 资源占用 | 最低 | 多一个 QEMU 进程 |
| macOS 客户机 | 支持 | 不支持 |
| Windows 声音 / 挂起 | 无 | 有 |
| 共享目录（virtio-fs） | 支持 | 不支持 |
| 客户机端口访问 | vsock、NAT IP | 只有 22 与代理端口，经 Unix socket 转发 |
| 画面 | 只能在运行它的进程里显示 | 经 Unix socket 提供，应用可接上 `macvm start` 启动的虚拟机。自带的 QEMU 用 SPICE + GL（画面经 IOSurface 共享，`screenshot` 截不到）；Homebrew 的用 VNC，`run --display` 另开 QEMU 窗口 |
| Windows 分辨率 | 固定 1024x768，随窗口缩放 | 自带的 QEMU 装了 viogpu3d 时跟随窗口大小（按点数，最小 800x600；`--retina on` 时按屏幕像素，并把 Windows 缩放比例调到相同倍数；总像素不超过约 780 万）；否则由客户机设定 |
| Windows 光标 | 客户机自绘 | 宿主的 macOS 光标，跟手无延迟：Windows 的系统光标换成 macOS 的同类光标（输入、手形、调整大小等，没有同类的用箭头）。viogpu3d 不支持硬件光标，代理在画面打开期间把客户机的系统光标换成透明的；程序自带的光标仍由客户机画（viogpudo 下按原图显示） |
| Windows 3D | 无 | 自带的 QEMU 下装 viogpu3d（Direct3D 11.1，桌面合成用 GPU）；装上后只能用自带的 QEMU 运行，不能再改用 vz。驱动要与 App 自带的图形组件配套，每次开机后自动推送，换了驱动就自动重启客户机 |

Windows 总是先用 qemu 部署，装好后可 `macvm set win --engine vz` 改用 vz 运行。

## 与 runode 配合

- 把虚拟机当远端主机：`macvm ssh-config --install`，runode 读取 `~/.ssh/config` 后列出各虚拟机名。连接经 `macvm proxy` 走 vsock，虚拟机未运行时自动启动。
- 在面板里开客户机 shell：`runode open --right -- macvm exec dev -t`。
- 任务板的 agent 前缀：`macvm exec dev -t --cwd "$PWD" --`，配合 `create --share 目录` 让项目目录在客户机里可见。
