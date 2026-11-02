# macvm CLI 契约

供脚本与其他程序（如 runode）调用。退出码表与错误码以 `macvm --help` 输出为准，由 `MacVMError` 生成。

## 输出

- 加 `--json` 时标准输出恰好一行：成功 `{"schemaVersion":1,"result":…}`，失败 `{"schemaVersion":1,"error":{"code":"…","message":"…"}}`。
- 不加 `--json` 时输出面向人阅读，格式不保证稳定。
- `exec`、`ssh`、`proxy` 不支持 `--json`：它们的标准输入输出属于客户机命令，`exec` 的退出码就是客户机命令的退出码。

## 命令

| 命令 | 作用 |
| --- | --- |
| `create <名> [--image ID \| --iso 文件] [--os linux\|windows]` | 创建 Linux / Windows 虚拟机 |
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

## 与 runode 配合

- 把虚拟机当远端主机：`macvm ssh-config --install`，runode 读取 `~/.ssh/config` 后列出 `macvm-<名>`。连接经 `macvm proxy` 走 vsock，虚拟机未运行时自动启动。
- 在面板里开客户机 shell：`runode open --right -- macvm exec dev -t`。
- 任务板的 agent 前缀：`macvm exec dev -t --cwd "$PWD" --`，配合 `create --share 目录` 让项目目录在客户机里可见。
