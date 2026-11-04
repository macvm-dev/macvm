# MacVM 开发约定

基于 Apple Virtualization.framework 的 macOS / Linux / Windows（ARM64）虚拟机，SwiftUI 应用 + `macvm` CLI 共用一套引擎，客户机代理用 Rust。

## 目录

| 目录 | 内容 |
| --- | --- |
| `Sources/MacVMModel` | 纯模型：配置、包布局、CLI 输出与错误码。不 import Virtualization |
| `Sources/MacVMPrivate` | 唯一调用 Virtualization 私有选择子的地方 |
| `Sources/MacVMEngine` | 引擎：配置构建、运行、安装、存储、网络、USB、代理客户端 |
| `Sources/MacVMApp` | SwiftUI 应用 |
| `Sources/MacVMCLI` | `macvm` 命令，每个子命令一个文件 |
| `guest` | 放进客户机的 Rust 程序（一个 Cargo workspace，`make agent` / `make boot` 编译，产物在 `.build/guest`） |
| `guest/agent` | 客户机代理 macvm-agent；`agent-platform` 是各系统的实现，`agent-protocol` 是协议类型与黄金样例（`fixtures`） |
| `guest/boot` | UEFI 引导程序 macvm-boot：在 VZ 上启动 Windows 用的帧缓冲垫片 |
| `qemu` | App 自带 QEMU 的源码清单、补丁与 SPICE 显示库（`make qemu` 编译，产物在 `.build/qemu`） |
| `packaging` | Info.plist、entitlements、图标（`icon`：Icon Composer 源文件与 `make` 不重编的产物） |
| `scripts` | Makefile 调用的脚本 |
| `docs` | 契约文档：CLI（`cli.md`）、宿主与代理之间的协议（`agent-protocol.md`） |

`MacVMEngine` 按关注点分子目录：

| 子目录 | 内容 |
| --- | --- |
| `VZ` | VZ 引擎：由 `VMConfig` 构建 VZ 配置（按客户机系统分文件）、运行与显示 |
| `QEMU` | QEMU 引擎：命令行、运行、QMP；`Display` 下是 VNC/SPICE 显示 |
| `Runtime` | 与引擎无关的运行时：`MachineRunner`、控制 socket、状态查询、换引擎 |
| `Install` | 创建虚拟机（`VMFactory`）与各客户机系统的安装，按 `macOS` / `Linux` / `Windows` 分 |
| `Guest` | 与客户机通信：代理（`Agent`）、SSH（`SSH`）、端口连接、随程序分发的客户机文件 |
| `Storage` | 包内文件：磁盘镜像、机器标识、克隆、快照 |
| `Network` | 网卡附件与 DHCP 租约 |
| `Download` | 镜像、安装盘、IPSW 的分块并行下载与进度回报 |
| `Host` | 宿主系统设施：硬件、能力、entitlement、子进程、Unix socket |

## 分层

依赖只能自上而下：`MacVMModel` ← `MacVMPrivate` ← `MacVMEngine` ← `MacVMApp` / `MacVMCLI`。`make lint` 检查：

- 只有 `MacVMEngine` 可以 import Virtualization；
- 只有 `MacVMPrivate` 可以出现私有选择子（以 `_` 开头的 `NSSelectorFromString`）；
- `MacVMApp` 与 `MacVMCLI` 互不依赖。

## 构建

- `make sign` 构建并 ad-hoc 签名，之后才能运行 `.build/debug/macvm`（VZ 要求 `com.apple.security.virtualization`）。
- 本仓库所在卷大小写不敏感，产品名不能只差大小写（CLI 叫 `macvm`，App 叫 `MacVMApp`）。
- 测试时用 `MACVM_HOME=<临时目录>` 隔离虚拟机目录。

## CLI 契约

- 所有命令支持 `--json`，输出一行 `JSONEnvelope`；错误码与退出码在 `MacVMError` 定义，已发布的值不能改。
- 改命令或选项时同步更新 `docs/cli.md`。

## 注释

只写本声明的契约和代码看不出的原因；引用别处代码用标识符，不写文件路径；不写历史、待办、issue 号。
