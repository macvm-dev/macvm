---
name: verify
description: 改了 MacVM 的 Sources/、guest/、qemu/、packaging/、scripts/、Makefile 或 Package.swift 后准备提交时用，把改动真正跑起来验证：make 构建签名与单测，再用隔离的临时虚拟机走 macvm CLI 主流程（create、start、exec、cp、ssh、挂起恢复、快照、克隆、引擎），界面改动起调试版 App 交给 cua-operator，留下命令输出、run.log 与截图作证据。只改 docs/、README、AGENTS.md 或 skills/macvm 时不用。
---

# 验证 MacVM 的改动

改动按「静态检查 → 不建虚拟机的冒烟 → 按改动挑虚拟机流程 → 界面」逐级往上走，前一级不过不往后。命令都在仓库根目录跑。

## 不能碰用户的东西

用户机器上有在用的虚拟机和模板。验证时：

- 一律用 `.build/debug/macvm`，虚拟机建在 `MACVM_HOME` 指向的临时目录里，名字以 `verify-tmp-` 开头，用完关机删除。不对用户的虚拟机执行任何 `stop`、`set`、`rm`、`snapshot`、`template save/rm`；只读的 `ls`、`template ls`、`doctor` 可以不带 `MACVM_HOME`。
- `create`、`clone`、`rm` 会按当前（临时）虚拟机列表重写用户的 `~/.config/macvm/ssh_config`，用户原来的条目会被冲掉。`smoke.sh` 和 `app.sh` 都在临时目录里放了备份，结束时整份覆盖还原；手动跑这几条命令前先自己备份。整份覆盖的代价是验证期间别处对它的改动（比如用户在正式版 App 里新建了虚拟机）也会被盖掉：这个文件按虚拟机列表生成，事后不带 `MACVM_HOME` 运行一次 `/Applications/MacVM.app/Contents/Resources/bin/macvm ssh-config` 就能重新生成。
- 调试版 App 与正式版共用用户级状态：启动时把 `~/.local/bin/macvm` 改指到 `.build/MacVM.app`，把仓库里的 `skills/macvm` 覆盖到用户已装的技能副本，读写未完成的新建记录 `~/Library/Application Support/MacVM/creations.json`（不跟 `MACVM_HOME` 走），`app.sh` 在 start 时备份或挪开、stop 时还原这些。还有两样它还原不了：设置文件 `~/Library/Application Support/MacVM/settings.json`（虚拟机、下载、模板目录），以及偏好域 `cn.barey.macvm`（Bundle ID 相同，窗口位置、菜单栏显示、语言、更新检查记录都写在这里），在调试版里改了就是改了正式版的，所以界面验证时不碰相关设置。
- 不要自己 `make run`（它在前台运行、用的是用户的虚拟机目录，要起 App 用下文的 `app.sh`），也不要 `make app`（会覆盖 `dist/` 里的发布产物）、`make install`、`make release`、`make tag`。
- 临时虚拟机目录放在下载目录（`doctor --json` 的 `downloadPath`）里：与云镜像缓存、模板同卷时 `create` 用 clonefile，一秒内建好；放到 `/tmp` 这类别的卷上要整盘复制 3 GB 镜像，实测 45 秒到近三分钟。

脚本被强杀（`kill -9`、会话中断）后，临时虚拟机和被改过的 `ssh_config` 会留下，运行 `.claude/skills/verify/smoke.sh cleanup` 收掉并还原（不带目录时跳过 `owner` 里记的进程还活着的目录，即别的验证正在用的）；起过 `app.sh` 的再运行 `.claude/skills/verify/app.sh stop`，把链接、技能副本和 `creations.json` 还原回去（`creations.json` 的备份是它旁边的 `creations.json.verify-backup`，正式版在运行时 stop 不动它）。

## 1. 静态检查（每次都做）

前提：Apple Silicon、macOS 15 以上、Xcode 27、Rust（rustup，`make agent` 交叉编译 Windows 版代理另需 `cargo install cargo-xwin`）。构建、测试一律走 `make`，它带上 `SWIFT_FLAGS`；直接 `swift build` 出来的 App 会以旧版外观显示。

| 命令 | 作用 | 实测耗时（增量） |
| --- | --- | --- |
| `make lint` | 分层规则 | 不到 1 秒 |
| `make sign` | 调试构建并签名 `.build/debug/macvm`、`MacVMApp`，带 `com.apple.security.virtualization`；钥匙串里有唯一一张 Developer ID 证书时用它，否则 ad-hoc。之后的一切都依赖它 | 3–12 秒 |
| `make test-swift` | 全部 Swift 单测 | 4–16 秒 |
| 只跑相关单测：`swift test -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$(xcrun --sdk macosx --show-sdk-path)" --filter SnapshotTests` | 与 `make test-swift` 同样的参数，不会触发整体重编 | 约 3 秒 |
| `make strings` | 改了界面或 CLI 文案时：同步字符串目录、检查中文译文；跑完 `packaging/l10n` 的变化应只来自这次改的文案 | 2–10 秒 |
| `make lint-guest`、`make test-guest` | 改了 `guest/` 时：clippy 有警告即失败、cargo 单测 | 约 2 秒、5 秒 |
| `make agent boot` | 改了 `guest/` 后要重编客户机程序，新建的 Linux 虚拟机和 `agent install` 才会用上 | 约 18 秒 |

单测按目录对应：`MacVMModelTests`、`MacVMEngineTests`（按 `VZ`、`QEMU`、`Runtime`、`Storage`、`Network`、`Guest`、`Install`、`Download` 分文件）、`MacVMCLITests`（退出码表）。

## 2. 冒烟与虚拟机流程：`smoke.sh`

```sh
.claude/skills/verify/smoke.sh            # 缺省 cli：不建虚拟机，1 秒内
.claude/skills/verify/smoke.sh linux qemu  # 可以连写几个流程
.claude/skills/verify/smoke.sh all         # cli linux qemu macos windows 全走，约 80 秒
```

脚本开头检查 `.build/debug/macvm` 存在、带 virtualization entitlement、不比 `Sources` 旧，不满足就让你先 `make sign`。每个流程自己建临时目录、自己收拾，Ctrl-C 或 `kill` 也会关机删除临时虚拟机并还原 `ssh_config`。用 Bash 工具跑时设好 timeout（`all` 给 10 分钟），不用另写等待循环。

| 流程 | 走什么 | 实测耗时 | 前提 |
| --- | --- | --- | --- |
| `cli` | `--version`、`doctor`、空目录 `ls`、`status` 不存在的虚拟机得 `vm_not_found`/10、非法名字与未知镜像得 `invalid_config`/14、`template ls`、`--help` 的退出码表、临时目录里没留下文件 | 1 秒 | 无 |
| `linux` | Debian 13 云镜像、vz 引擎：`create --forward` → `start` → `wait` → `exec`（含退出码透传）→ `agent info`（代理与当前构建一致）→ `ip` → `cp` 双向 → 经 `macvm proxy` 的 ssh → 端口转发读到 SSH 横幅 → `suspend`/`start` 从内存恢复（tmpfs 里的标记还在、run.log 有 Resumed）→ `stop` → `snapshot save/ls`、改动、`snapshot restore` 后内容回到快照时 → `snapshot rm` → `clone` → `set --cpus --memory` → 克隆开机后主机名与核数是新的 | 约 30 秒 | 下载目录里有 `images/debian-13-generic-arm64.raw`；没有时首次 `create` 先下载解包云镜像，要几分钟 |
| `qemu` | 同一镜像、`--engine qemu`：开机、`exec` 看到 QEMU 机器、`agent info`、关机 | 约 10 秒 | `doctor` 能找到 QEMU（`make qemu` 编译自带的，或 `brew install qemu`），找不到时跳过 |
| `macos` | 从用户模板目录里第一个 macOS 模板新建（只读模板）：开机、`exec sw_vers`、`agent info`、`ui screenshot`、关机 | 约 25–45 秒 | 有 macOS 模板，且用户运行中的 macOS 虚拟机少于两台；不满足时跳过 |
| `windows` | 同上，Windows 模板（qemu 引擎）：`exec cmd /c echo` | 约 20–40 秒 | 有 Windows 模板和 QEMU |

模板里的客户机代理是存模板时的版本。改了客户机代理时用 `VERIFY_AGENT_INSTALL=1 .claude/skills/verify/smoke.sh macos windows`（先 `make agent`），多走一步 `agent install` 并确认 `updateAvailable` 为 false，各多十几秒。

`ui screenshot` 只当证据、不计成败：macOS 客户机没给代理「屏幕录制」权限时报 `permission_denied`（退出码 22）是正常的。

### 按改动挑流程

| 改了哪里 | 至少跑 |
| --- | --- |
| 只改文档、`skills/macvm` | 不用跑虚拟机；改了 CLI 帮助或文案时 `make strings` |
| `MacVMModel`、CLI 输出与错误码、`MacVMCLI` 的参数解析 | `cli`，再加用到这条命令的流程 |
| `MacVMEngine` 的 `VZ`、`Runtime`、`Storage`、`Network`、`Guest`，`MacVMCLI` 的子命令实现 | `linux`；涉及某个客户机系统的再加 `macos` 或 `windows` |
| `MacVMEngine/QEMU`、`qemu/` | `qemu`、`windows` |
| `Install/Linux`（云镜像、cloud-init） | `linux`（`create` 后首次开机就是走这条） |
| `guest/agent` | `make agent` 后 `linux` 与 `VERIFY_AGENT_INSTALL=1` 的 `macos windows` |
| `MacVMApp` | 静态检查加下面的界面验证 |
| `Install/macOS`、`Install/Windows`、Ubuntu 桌面版自动安装、`Download` | 单测之外只有下面的慢路径能覆盖 |

### 慢路径：完整安装（默认不跑）

模板流程不经过安装器。改了安装流程、确实要端到端验证时，在临时目录里手动建，并先跟用户确认要占用的时间和磁盘：

- macOS：`create verify-tmp-mac --os macos` 下载 15–20 GB 的 IPSW（缓存在下载目录 `ipsw/`，有缓存时可用 `--ipsw` 指定），安装加首次开机配置要几十分钟。
- Windows：`create verify-tmp-win --os windows` 从微软下载 ISO（下载目录 `windows/` 有缓存时用缓存），无人值守部署要半小时以上。
- Ubuntu 桌面版：`create verify-tmp-desk --desktop ubuntu-desktop` 下载安装 ISO 并离线自动安装，十几分钟以上。

做法：Bash 工具每次调用不保留环境变量，不要 `export`。先跑 `mktemp -d "<downloadPath>/.verify-tmp.XXXXXX"` 记下它打印的路径（下称 `<D>`）；有 `~/.config/macvm/ssh_config` 就 `cp -p` 到 `<D>/ssh_config.backup`，没有就 `touch <D>/ssh_config.absent`。之后每条命令都写成 `MACVM_HOME=<D> .build/debug/macvm …` 的字面量前缀，用 `run_in_background` 跑；完了 `.claude/skills/verify/smoke.sh cleanup <D>` 删虚拟机并还原 `ssh_config`。这样手建的目录没有 `owner`，跑着的时候别人不带目录跑 `cleanup` 会把它清掉，所以慢路径期间不要并行跑别的验证。

## 3. 界面：调试版 App 交给 cua-operator

```sh
.claude/skills/verify/app.sh start    # make run 放到后台，虚拟机目录隔离；增量构建实测 8–12 秒就绪，冷构建要几分钟
.claude/skills/verify/app.sh status
.claude/skills/verify/app.sh stop     # 关掉临时虚拟机、退出 App、还原上面列的用户级状态、删临时目录，1–2 秒
```

`start` 等到可执行文件是 `.build/MacVM.app/Contents/MacOS/MacVM` 的进程出现并活过三秒才返回（上限 10 分钟），打印 pid、临时虚拟机目录和日志；中途失败会自动回滚。`stop` 只给按可执行文件路径核对过的调试版进程和 start 起的 `make run` 发信号，不会碰正式版；有一步没还原成功时返回非零、保留 `.build/verify/app/` 里的备份并说明缺了哪样，这时不能当作已收拾干净。退出后 App 日志在 `.build/verify/app-last.log`。

已有名为 `MacVM` 的进程在运行（多半是 `/Applications` 那份）时 `start` 拒绝启动：App 有用户级单实例锁，调试版会立刻退出并把那份切到前台。这时请用户先退出它，或者只做 CLI 验证。

交给 `cua-operator` 时说明：目标是可执行文件为 `.build/MacVM.app/Contents/MacOS/MacVM`、pid 为 `start` 打印的那个进程的窗口；界面按系统语言显示；虚拟机列表只有临时目录里的虚拟机。并交代这些一律不点：

- 菜单「MacVM › 安装 Agent 技能…」：会打开终端真跑 `npx skills add -g`，装到用户全局。
- 「检查更新…」和弹出的更新窗口里的安装、跳过此版本。
- 设置里的「在菜单栏显示」「语言」和虚拟机 / 下载 / 模板目录（写的是正式版共用的偏好域和 `settings.json`）。
- 「继续创建」「取消创建」「放弃」这类续建或放弃未完成新建的按钮。

可以让它按改动走这些流程，每步给预期：

- 新建 Linux：工具栏 **+**（⌘N，「新建虚拟机…」）→ 选 Linux 服务器云镜像 Debian 13，名字填 `verify-tmp-gui` →「创建」后侧栏出现这台，创建完成后为已关机（云镜像已缓存时很快）。
- 启动：详情页点「启动」→ 状态变为运行中；云镜像默认无画面，有画面的系统会自动打开虚拟机窗口。
- 快照：关机后在详情页「快照」区「创建快照」→ 列表出现一条；「还原」后仍是已关机。
- 关机、删除：右键侧栏条目「关机」，再「删除」→ 侧栏回到空列表。
- 菜单栏图标：能看到虚拟机状态与创建进度。

要关键画面的截图让它存进 scratchpad，只看需要的那几张。也可以先用 CLI 在 `start` 打印的目录里建好虚拟机（`MACVM_HOME=<目录> .build/debug/macvm create verify-tmp-gui --image debian-13`），再让它在界面里操作。用完一定 `app.sh stop`；它会删掉临时目录里的所有虚拟机。

## 4. 判定与证据

- 通过：静态检查全部成功；`smoke.sh` 最后一行是「通过 N 项，失败 0 项」且退出码为 0（清理临时虚拟机失败也计入失败项）；界面流程每步都符合预期，且 `app.sh stop` 退出码为 0。`skip` 的流程要在汇报里写明跳过了什么、为什么。
- 证据在 `.build/verify/<时间>/`（已被 `.gitignore` 忽略）：`smoke.log` 有每条命令、完整输出、退出码与耗时；`<虚拟机>.run.log` 是引擎日志；`<虚拟机>.png` 是客户机截图。汇报时引用目录和关键几行，不贴整份。
- 结束后确认没留东西：下载目录里没有 `.verify-tmp.*`，`ps -axo pid,command | grep '[v]erify-tmp-'` 没有输出（临时虚拟机的 `macvm run <名> --detached` 进程都退了）。

### 失败先看哪里

- 先读 `smoke.log` 里失败那一步的 JSON：`error.code` 与退出码对照 `macvm --help` 的表。`entitlement_missing` 是没 `make sign`。
- `wait` 超时（`timeout`/17）：看 `<虚拟机>.run.log`。`Couldn't resume from the suspended state … did a cold boot instead` 说明恢复失败后冷启动了。已知的偶发症状：恢复报 `permission denied`，冷启动后客户机能 ping 通，但代理和 SSH 一直连不上，关机重开也一样。遇到时这次验证照样算失败，连同 run.log 和 `smoke.log` 报给用户；可以再跑一次 `linux` 看能否复现，作为诊断材料一并报上，但重跑通过不改变这次的判定。
- `create` 很慢：临时目录和下载目录不在同一个 APFS 卷，或者云镜像还没缓存。
- `macos` 开不了机：用户已有两台 macOS 虚拟机在运行（系统上限）。
- `qemu`、`windows` 跳过或失败：`doctor --json` 的 `qemu` 为空，`make qemu` 或 `brew install qemu`。
- 调试版 App 起不来：`start` 会打印日志末尾，完整的在 `.build/verify/app-last.log`；`MacVM is already running` 是单实例锁。
