# MacVM

在 Apple Silicon 上运行 macOS、Linux、Windows（ARM64）虚拟机，基于 Apple Virtualization.framework。SwiftUI 应用与 `macvm` 命令行共用同一引擎，客户机内的 `macvm-agent` 经 vsock 提供执行、端口转发与系统管理。

## 构建

```sh
make sign            # 调试构建并 ad-hoc 签名：.build/debug/macvm、.build/debug/MacVMApp
make agent           # 交叉编译客户机代理到 guest/agent/dist
make firmware        # 编译 UEFI 引导程序到 guest/firmware/dist
make app             # 发布构建并组装 dist/MacVM.app
make test lint
```

发布签名：`make app SIGN_IDENTITY="Developer ID Application: …"`，公证：`make release`。

## 快速上手

```sh
macvm create dev --image debian-13 --memory 8G      # 云镜像，秒级开机，自带用户、密钥与代理
macvm exec dev -- uname -a                           # 未运行时自动后台启动
macvm install-macos mac                              # 下载最新 IPSW，无人值守安装并开通 SSH
macvm create win --os windows --iso Win11_arm64.iso  # 需 brew install qemu；部署后自带 OpenSSH
macvm set win --engine vz                            # Windows 日常改用 VZ 运行，占用更低
macvm suspend dev && macvm start dev                 # 挂起与恢复
macvm snapshot save dev clean && macvm clone dev dev2
macvm ssh-config --install                           # 之后 ssh macvm-dev，runode 也能直接看到
```

完整命令、JSON 输出与退出码见 `docs/cli.md`，代理协议见 `protocol/agent.md`。
