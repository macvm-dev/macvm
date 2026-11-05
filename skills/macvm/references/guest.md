# 和客户机打交道

## 执行命令

```bash
macvm exec dev -- sh -c 'cd /tmp && make'     # 非交互，退出码就是客户机命令的
macvm exec dev -t -- bash                     # 交互程序要 -t 分配伪终端
macvm exec dev --cwd /mnt/src -- cargo test   # --cwd 是客户机里的路径
macvm exec dev --user root -- apt-get update  # --user 要经客户机代理（Linux 客户机）
```

- 虚拟机没运行时 `exec` 会自动在后台启动。
- `--cwd` 原样交给客户机，不做路径换算：宿主的 `$PWD` 在客户机里不存在，要换成共享目录在客户机里的路径（Linux `/mnt/<名称>`，macOS `/Volumes/My Shared Files/<名称>`）。
- 要把宿主文件给客户机，优先用建机时的 `--share`；没有共享目录时用 `macvm cp`（见下）。

## 复制文件

```bash
macvm cp report.pdf src dev:/home/me            # 宿主 → 客户机，目标是客户机上已有的目录
macvm cp 'win:C:\Users\me\Desktop\a.txt' .    # 客户机 → 宿主，客户机路径写绝对路径
```

- 经客户机代理，三种客户机都支持；保留目录结构、修改时间，非 Windows 之间还保留权限位与符号链接（Windows 上跳过符号链接）。
- 与目标里已有项重名时编号改名（`a.txt` → `a 2.txt`，Windows 客户机里是 `a (2).txt`），不覆盖；`--json` 的 `result.files` 是各项实际复制到的位置。
- 含冒号的本地路径写成 `./a:b`，否则冒号前的部分会被当成虚拟机名。

## SSH 与端口

- `macvm ssh <名>`：登录 shell。
- `macvm ssh-config --install`：生成 `~/.config/macvm/ssh_config`（之后 `create` / `rm` 自动更新）并在 `~/.ssh/config` 开头加入 Include，之后 `ssh <虚拟机名>`、`scp`、`rsync` 都能直接用，主机名就是虚拟机名；连接经 `macvm proxy` 走，虚拟机未运行时自动启动。
- `macvm proxy <名> --port N`：把标准输入输出接到客户机的 TCP 端口（默认 22），用作 ssh 的 ProxyCommand；代理还没装时加 `--tcp` 直连客户机 IP。
- `macvm ip <名> --json [--wait 秒]`：客户机 IP（NAT 下从 DHCP 租约查，桥接下客户机拿到地址前查不到）。

## 客户机代理

`exec --user`、`cp`、剪贴板、UI 自动化、显示尺寸等经客户机里的 macvm-agent。代理没装或版本过旧时报 `unsupported`，运行 `macvm agent install <名>` 安装或更新（代理在线时经代理自身更新、不需要 SSH，代理会重启一次）；`macvm agent info <名> --json` 看版本与 `features`。`macvm update <名> --check` 列出代理与客户机设置有没有要更新的，`macvm update <名>` 经代理一并更新（不需要 SSH，代理会重启一次；`rebootRequired` 为 true 时客户机要重启才完全生效，可加 `--reboot`）。

## 状态与快照

- `macvm status <名> --json`：单台的 `VMSummary`。
- `macvm suspend <名>`：挂起，下次 `start` 接着运行。vz 下的 Windows、非 headless 的 Linux、挂着安装介质的虚拟机、自带 QEMU 的 qemu 引擎都不支持，报 `unsupported`。
- `macvm snapshot save|restore|ls|rm`：快照；`restore` 会覆盖当前磁盘，先跟用户确认。
- `macvm clone <源> <名>`：克隆一台已停止的虚拟机，APFS 上零拷贝。

## 显示

- `macvm display <名> 1920x1080`：调整运行中虚拟机的显示尺寸（vz 下的 Windows 不支持）；不带尺寸时恢复为默认尺寸。
- 画面窗口在 MacVM App 里打开。`macvm run <名>` 是前台无头运行到关机（`--console` 接客户机控制台），只有 Homebrew 的 QEMU 能用 `run --display` 另开 QEMU 窗口。
