# 新建虚拟机

名字只能用字母、数字与 `. _ -`，最长 40。`--cpus` 默认 4、不超过主机核数；`--memory` 默认 8G、不超过主机内存一半；`--disk` 是稀疏文件，按实际写入占用。

## 选哪种

| 需要 | 命令 | 说明 |
| --- | --- | --- |
| 命令行 Linux（最快，推荐） | `macvm create dev --image debian-13` 或 `--image ubuntu-24.04` | 云镜像，首次下载后缓存；开机即带登录用户与 macvm 专用 SSH 密钥，可直接 `exec` / `ssh` |
| 带桌面的 Ubuntu | `macvm create desk --desktop ubuntu-desktop` | 离线无人值守安装，命令等到装好的系统里代理响应才返回；系统为英文、时区同主机 |
| 带桌面的 Fedora | `macvm create desk --desktop fedora-workstation` | 开机后要在窗口里手动图形安装，不适合无人值守 |
| Windows 11 | `macvm create win --os windows` | 从微软下载 ARM64 ISO 无人值守安装，总是先用 qemu 引擎部署；装好带用户、OpenSSH 与代理。`--product-key` 才会激活 |
| macOS | `macvm create mac --os macos` | 不给 `--ipsw` 时下载本机支持的最新版（约 15–20 GB）；装好自动登录、开 SSH、装代理并做降占用调优。网络与共享目录装好后用 `set` 改 |
| 从模板复制（任何系统） | `macvm create dev2 --template base` | 零拷贝或整盘复制；换新的机器标识与 MAC。模板由 `macvm template save <虚拟机> [<模板>]` 存下 |
| 自己的安装盘 | `macvm create box --os linux --iso 文件` | 开机从 ISO 安装，要在窗口里操作 |

用户名默认与主机用户同名（`--user` 可改）；密码用 `--password` 指定，省略时云镜像只能用密钥登录，Ubuntu 桌面版、Windows、macOS 随机生成，存在虚拟机包内的 `guest-password`。

## 引擎

`--engine vz`（默认，占用最低）或 `qemu`。

- macOS 客户机只能用 vz。
- Windows 安装总是 qemu；装好后可 `macvm set win --engine vz`，但 vz 下 Windows 分辨率固定 1024x768、没有声音。Windows 要 3D、声音、跟随窗口的分辨率就留在 qemu。
- 共享目录（virtio-fs）与 Rosetta 只在 vz 下可用。

## 网络

`--network nat`（默认）或 `bridged[:网卡]`（如 `bridged:en0`，可用网卡见 `macvm doctor --json`）。桥接要用户在 App 设置里启用网络辅助程序，`doctor` 的 `bridgedNetworking` 为 true 才可用，否则开机报 `unsupported`。改网络只能在关机时。

## 共享目录

`--share 主机路径[:名称][:ro]`，可重复；只用于 vz 引擎的 macOS、Linux 客户机。客户机里的路径与宿主不同：Linux 在 `/mnt/<名称>`，macOS 在 `/Volumes/My Shared Files/<名称>`。

## 建好之后

- `macvm set <名> --cpus N --memory 8G --disk-size 256G …` 改配置，要关机；`--disk-size` 只能扩大，客户机分区要另行扩展（云镜像建的 Linux 下次开机自动扩展）。
- 不确定本机能力时先 `macvm doctor --json`。
