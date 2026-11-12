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
| `packaging` | Info.plist、entitlements、macOS 版代理 App 包的 Info.plist（`agent`）、图标（`icon`：Icon Composer 源文件与 `make` 不重编的产物）、界面文案的字符串目录（`l10n`） |
| `scripts` | Makefile 调用的脚本 |
| `docs` | 契约文档：CLI（`cli.md`）、宿主与代理之间的协议（`agent-protocol.md`） |
| `skills` | 给其他应用与 agent 用的技能：`macvm` 教它们用 CLI 操作虚拟机；打包进 App，App 菜单「安装 Agent 技能…」在终端里用 `npx skills add` 装给各 agent |

`MacVMEngine` 按关注点分子目录：

| 子目录 | 内容 |
| --- | --- |
| `VZ` | VZ 引擎：由 `VMConfig` 构建 VZ 配置（按客户机系统分文件）、运行与显示 |
| `QEMU` | QEMU 引擎：命令行、运行、QMP；`Display` 下是 VNC/SPICE 显示 |
| `Runtime` | 与引擎无关的运行时：`MachineRunner`、控制 socket、状态查询、换引擎 |
| `Install` | 创建虚拟机（`VMFactory`）与各客户机系统的安装，按 `macOS` / `Linux` / `Windows` 分 |
| `Guest` | 与客户机通信：代理（`Agent`）、SSH（`SSH`）、端口连接、随程序分发的客户机文件 |
| `Storage` | 包内文件：磁盘镜像、机器标识、克隆、快照 |
| `Network` | 网卡附件、DHCP 租约与客户机 IP |
| `Download` | 镜像、安装盘、IPSW 的分块并行下载与进度回报 |
| `Host` | 宿主系统设施：硬件、能力、entitlement、子进程、Unix socket |

## 分层

依赖只能自上而下：`MacVMModel` ← `MacVMPrivate` ← `MacVMEngine` ← `MacVMApp` / `MacVMCLI`。`make lint` 检查：

- 只有 `MacVMEngine` 可以 import Virtualization；
- 只有 `MacVMPrivate` 可以出现私有选择子（以 `_` 开头的 `NSSelectorFromString`）；
- `MacVMApp` 与 `MacVMCLI` 互不依赖。

## 构建

- 开发构建一律用团队 ID 签名：`make sign`、`make run`、`make agent`、`make app` 在钥匙串里有唯一一张 Developer ID Application 证书时用它签名，没有才 ad-hoc，`SIGN_IDENTITY=-` 强制 ad-hoc。ad-hoc 签名的代理每次重编后客户机里都要重新授权，「登录项」里也只显示 `macvm-agent`。
- `make sign` 构建并签名，之后才能运行 `.build/debug/macvm`（VZ 要求 `com.apple.security.virtualization`）。
- `make run` 先编译客户机代理与引导程序（`make agent boot`），再把调试版组装成 `.build/MacVM.app`（带 CLI、客户机程序与已编译的 QEMU）并在前台运行；自带的 QEMU 不自动编译，用 `make qemu`。
- `make install` 用 `dist/MacVM.app` 替换 `/Applications/MacVM.app`（不重新构建，先 `make app` 或 `make release`）：正在运行的先走正常退出流程，用户取消退出就不替换，装好后重新打开。
- 本仓库所在卷大小写不敏感，产品名不能只差大小写（CLI 叫 `macvm`，App 叫 `MacVMApp`）。
- 测试时用 `MACVM_HOME=<临时目录>` 隔离虚拟机目录。
- 构建、测试一律走 `make`：直接 `swift build` 不带 `SWIFT_FLAGS`，App 会以旧版外观显示。
- 发布：`make tag VERSION=0.3.0` 把 `Info.plist` 与客户机程序的版本号改成它（构建号取提交数，并与已有各版本标签上的构建号保持与版本号同序，做不到时停下），提交「chore: 版本号改为 0.3.0」，在这个提交上打 `v0.3.0` 标签，与当前分支一起原子推送；推送失败时撤销本地的提交与标签。`.github/workflows/release.yml` 收到 `v*` 标签后先核对标签所在提交的版本号与标签一致（不一致即失败，不要手动打标签），再构建、签名、公证 App 与 DMG 并发布到 GitHub Releases，同时上传 Sparkle 的 `appcast.xml`（App 的 `SUFeedURL` 经 `releases/latest/download` 取它，资源名不能改）（本地 `make release` 产出同样的 `dist/MacVM.dmg`）；手动运行以仓库里的版本号加 `-dev` 构建并上传 artifact。需要 secrets：`MACOS_CERTIFICATE`（Developer ID Application 证书导出的 .p12，base64）、`MACOS_CERTIFICATE_PASSWORD`、`SIGN_IDENTITY`（签名身份全名）、`NOTARY_KEY_P8`、`NOTARY_KEY_ID`、`NOTARY_ISSUER`（App Store Connect API 密钥）、`SPARKLE_PRIVATE_KEY`（Sparkle 更新签名私钥，`generate_keys -x` 导出，公钥是 `Info.plist` 的 `SUPublicEDKey`）。
- CI（`.github/workflows/ci.yml`）跑 `make lint`、`make build`、`make test-swift`、`make app` 与 `make lint-guest`、`make test-guest`；客户机代码要过 `make lint-guest`（clippy 有警告即失败）。

## CLI 契约

- 所有命令支持 `--json`，输出一行 `JSONEnvelope`；错误码与退出码在 `MacVMError` 定义，已发布的值不能改。
- 改命令或选项时同步更新 `docs/cli.md`，以及 `skills/macvm` 里讲到它的地方（技能用英文写）。

## 界面语言

- App 与 CLI 支持英文和简体中文，按系统语言显示，其他语言显示英文；也可在 App 设置的「通用 › 语言」（或「系统设置 › 通用 › 语言与地区」）里给 MacVM 单独选，两处写的是 App 偏好域里同一个 `AppleLanguages`，CLI 跟着变。
- 源码里写英文，英文就是查表的键；中文译文在 `packaging/l10n/Localizable.xcstrings`（Info.plist 里的文案在 `InfoPlist.xcstrings`），`make app` / `make run` 编译成 `.lproj` 放进 App 包。
- SwiftUI 收 `LocalizedStringKey` 的地方直接写英文字面量；其余给人看的 `String`（错误消息、CLI 输出与帮助）写 `String(l10n: "…")`，字面量要直接写在参数里，编译器才抽得到。日志、发进客户机的内容、客户机代理的消息只写英文，不查表。
- 改了文案后跑 `make strings`：同步字符串目录，新条目在 Xcode 里打开 `Localizable.xcstrings` 补中文（或直接编辑 JSON），直到它不再报缺译文。

## 客户机更新

- 安装流程（`WindowsUnattend`、`CloudInit`、`UbuntuAutoinstall`、`MacOSProvisioning` 等）在客户机里新做一件事、或换了装进客户机的东西（如 virtio 驱动盘版本），要给该系统的 `GuestRevision.latest` 加一，并在 `GuestMigration.all` 补一条把已有虚拟机带到这一修订的迁移；迁移经代理 `exec` 运行，要能重复执行。只是偏好的默认值（时区、电源设置等）不补，免得覆盖用户改过的设置。
- 客户机代理与 3D 显卡驱动按内容比对，不需要迁移。

## 注释

只写本声明的契约和代码看不出的原因；引用别处代码用标识符，不写文件路径；不写历史、待办、issue 号。
