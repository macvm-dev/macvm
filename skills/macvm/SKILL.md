---
name: macvm
description: 用 macvm 命令行在 Mac 上创建和操作 macOS / Linux / Windows（ARM64）虚拟机：建机、启停、挂起、在客户机里执行命令、SSH、端口转发、快照与模板、操作客户机桌面（UI 自动化、截图）。只要任务涉及在虚拟机或隔离的客户机里跑东西、测试别的系统、要一台干净的 Linux / Windows / macOS 环境，或提到 macvm、MacVM，都用这个技能，即使用户没说「虚拟机」而只说「开个 Ubuntu 试试」「在 Windows 里点一下」「沙箱里跑」。
---

# macvm

`macvm` 是 MacVM 自带的命令行，基于 Apple Virtualization.framework（另有 QEMU 引擎），只在 Apple 芯片的 Mac 上运行。

## 找到命令

依次试：`macvm`（App 会在 `~/.local/bin` 放链接）、`/usr/local/bin/macvm`、`/Applications/MacVM.app/Contents/Resources/bin/macvm`。都没有就是没装 MacVM，告诉用户去装，不要自己找别的虚拟化方案替代。

选项以 `macvm <命令> --help` 为准；本技能只讲怎么用得稳。

## 一律加 `--json`

加 `--json` 时标准输出恰好一行：

- 成功：`{"schemaVersion":1,"result":…}`
- 失败：`{"schemaVersion":1,"error":{"code":"…","message":"…"}}`

按 `error.code` 或退出码分支，不要解析人读输出（格式不保证稳定）。例外：`exec`、`ssh`、`proxy` 不支持 `--json`，它们的输入输出属于客户机命令，`exec` 的退出码就是客户机命令的退出码。

| code | 退出码 | 含义与通常的处理 |
| --- | --- | --- |
| —（无 code） | 1 | 其他错误，看 message |
| `vm_not_found` | 10 | 名字不对，先 `macvm ls --json` |
| `already_exists` | 11 | 同名虚拟机或模板已存在，换名字或确认要用现有的 |
| `already_running` | 12 | 已在运行；改配置要先关机 |
| `not_running` | 13 | 先 `start` |
| `invalid_config` | 14 | 参数或配置无效；挂起状态下改配置也报这个 |
| `unsupported` | 15 | 本机、该引擎或该客户机不支持；也用于代理没装或版本过旧，按 message 提示做（常见是 `macvm agent install <名>`） |
| `entitlement_missing` | 16 | 用了没签名的 macvm，换成 App 自带的那份 |
| `timeout` | 17 | 等待超时，可加大 `--timeout` 重试 |
| `io` | 18 | 文件或 socket 读写失败 |
| `engine` | 19 | 虚拟化引擎报错；UI 自动化里也表示元素编号失效 |
| `snapshot_not_found` | 20 | 快照不存在 |
| `template_not_found` | 21 | 模板不存在 |
| `permission_denied` | 22 | 客户机没给代理权限（macOS 的辅助功能、屏幕录制），要用户在客户机里授权 |

## 基本流程

```bash
macvm ls --json                       # 结果是 VMSummary 数组：name、os、state（stopped|running|suspended）、cpuCount、memorySize、ipAddress…
macvm start dev --json                # 后台启动，就绪后返回
macvm wait dev --json                 # 等代理（或 SSH）可用；没运行时自动启动
macvm exec dev -- uname -a            # 在客户机里执行；没运行时自动启动
macvm stop dev --json                 # 正常关机
```

- 先 `ls` 看有没有现成能用的虚拟机，能复用就别新建：新建要下载镜像、安装系统，几分钟到几十分钟。
- 建机（尤其 macOS、Windows、Ubuntu 桌面版的安装）耗时很长，放后台运行并告诉用户在等什么。
- 默认虚拟机目录里是用户自己的虚拟机。为测试临时建的虚拟机，用完问用户要不要删。

## 先确认再做

这些操作会丢数据或打断用户正在用的东西，执行前先跟用户确认：`rm`、`stop --force`（直接断电）、`snapshot restore`（覆盖当前磁盘）、`template rm`、对用户已有虚拟机 `set`（改配置）、关掉不是你自己启动的虚拟机。

## 细节按需读

| 要做的事 | 读 |
| --- | --- |
| 新建虚拟机：选系统、镜像、引擎、网络、共享目录、模板 | `references/create.md` |
| 在客户机里执行命令、SSH、端口、共享目录路径、快照与克隆 | `references/guest.md` |
| 操作客户机桌面：快照无障碍树、点击、输入、截图 | `references/ui.md` |
