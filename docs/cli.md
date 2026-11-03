# macvm CLI 契约

供脚本与其他程序（如 runode）调用。退出码表与错误码以 `macvm --help` 输出为准，由 `MacVMError` 生成。

## 输出

- 加 `--json` 时标准输出恰好一行：成功 `{"schemaVersion":1,"result":…}`，失败 `{"schemaVersion":1,"error":{"code":"…","message":"…"}}`。
- 不加 `--json` 时输出面向人阅读，格式不保证稳定。
- `exec`、`ssh`、`proxy` 不支持 `--json`：它们的标准输入输出属于客户机命令，`exec` 的退出码就是客户机命令的退出码。

## 命令

| 命令 | 作用 |
| --- | --- |
| `create <名> [--image ID \| --iso 文件] [--os linux\|windows] [--engine vz\|qemu]` | 创建 Linux / Windows 虚拟机；Windows 从原版 ISO 无人值守部署 |
| `set <名> [--engine vz\|qemu] [--cpus N] [--memory 8G] [--display 宽x高]` | 修改已停止虚拟机的配置，可切换引擎 |
| `screenshot <名> <文件>` | 保存画面为 PNG（QEMU 引擎） |
| `display <名> <宽>x<高>` | 调整运行中虚拟机的显示尺寸（VZ 引擎；VZ 下 Windows 分辨率固定为 1024x768，不支持） |
| `install-macos <名> [--ipsw 文件]` | 安装 macOS 虚拟机并开通 SSH 与代理 |
| `ls` / `status <名>` | 列出 / 查看状态，结果为 `VMSummary` |
| `start <名>` / `run <名>` | 后台启动并在就绪后返回 / 前台运行到关机 |
| `wait <名>` | 等到代理（或 SSH）可用，未运行时自动启动 |
| `stop <名> [--force]` / `suspend <名>` | 关机 / 挂起 |
| `exec <名> [-t] [--cwd 目录] [--user 用户] -- 命令…` | 在客户机执行 |
| `ssh <名>` / `proxy <名> [--port N]` | 登录 shell / ssh ProxyCommand |
| `ssh-config [--install]` | 生成 `~/.config/macvm/ssh_config`，主机名 `macvm-<名>` |
| `clone <源> <名>` / `snapshot save\|restore\|ls\|rm` | 克隆 / 快照 |
| `agent install\|info <名>` | 安装 / 查询客户机代理 |
| `ip <名>` / `rm <名>` / `doctor` | IP / 删除 / 检查本机能力 |

## 引擎

| | vz（默认） | qemu |
| --- | --- | --- |
| 依赖 | 无 | `brew install qemu` |
| 资源占用 | 最低 | 多一个 QEMU 进程 |
| macOS 客户机 | 支持 | 不支持 |
| Windows 声音 / 挂起 | 无 | 有 |
| 共享目录（virtio-fs） | 支持 | 不支持 |
| 客户机端口访问 | vsock、NAT IP | 只有 22 与代理端口，经 Unix socket 转发 |
| 画面 | 只能在运行它的进程里显示 | 经 Unix socket 上的 VNC，应用可接上 `macvm start` 启动的虚拟机；`run --display` 另开 QEMU 窗口 |
| Windows 分辨率 | 固定 1024x768，随窗口缩放 | 由客户机设定 |

Windows 总是先用 qemu 部署，装好后可 `macvm set win --engine vz` 改用 vz 运行。

## 与 runode 配合

- 把虚拟机当远端主机：`macvm ssh-config --install`，runode 读取 `~/.ssh/config` 后列出 `macvm-<名>`。连接经 `macvm proxy` 走 vsock，虚拟机未运行时自动启动。
- 在面板里开客户机 shell：`runode open --right -- macvm exec dev -t`。
- 任务板的 agent 前缀：`macvm exec dev -t --cwd "$PWD" --`，配合 `create --share 目录` 让项目目录在客户机里可见。
