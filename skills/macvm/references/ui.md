# 操作客户机桌面（UI 自动化）

`macvm ui` 经客户机代理读客户机的无障碍树、注入鼠标键盘、截图。三种客户机系统、两种引擎都可用。虚拟机要在运行，`ui` 不会自动开机。

## 循环

1. `macvm ui snapshot <名> --json [--app 应用] [--depth N] [--limit N]`：拿到 `screen`、`apps`、`app`、`nodes`（元素编号、角色、名称、`bounds`）、`truncated`。树太大就用 `--app` 限定到目标应用，或调 `--depth` / `--limit`；`truncated` 为 true 说明没取全。
2. 优先按元素操作，比按坐标点稳：
   - `macvm ui act <名> <元素> <动作> [--value 文本] --json`，动作有 `press`、`focus`、`set-value`、`toggle`、`expand`、`collapse`、`select`、`scroll-into-view`、`show-menu`、`raise`。
   - `macvm ui click <名> --element <元素> --json`：点元素当前位置的中心。
3. 没有合适元素时按坐标：`ui click <名> <x> <y> [--button left|right|middle] [--count N]`、`ui move`、`ui drag <名> x1 y1 x2 y2`、`ui scroll <名> <x> <y> [--dx N] [--dy N]`（单位是滚轮格，正值向右、向下）。
4. 输入：`ui type <名> <文本>`、`ui key <名> <组合键>`（如 `cmd+shift+t`、`enter`）。
5. `macvm ui screenshot <名> <文件.png> --json`，再看图核对结果；结果带 `width`、`height`。

## 坐标与编号

- 坐标一律是 `ui screenshot` 截图的像素，原点在主屏左上角；`snapshot` 的 `bounds` 用同一套坐标，`screen.scale` 是客户机坐标单位到像素的倍数。
- 元素编号至少在下一次 `snapshot` 之前有效；操作报 `engine` 时先重新快照再试，别反复用旧编号。

## 各系统的坑

- **macOS**：要在客户机「系统设置 › 隐私与安全性」给 MacVM Agent「辅助功能」（快照、动作、输入）与「屏幕录制」（截图）权限，没给报 `permission_denied`。这一步得让用户在画面里点，你做不了。授权后第一次调用回「正在重启以载入授权」，代理会自行重启，几秒后重试即可。
- **Linux**：要有已登录的图形会话。第一次快照时代理才打开无障碍支持，之前已运行的部分应用要重启后才看得到。Wayland 下 GNOME Shell 以外的元素没有 `bounds`，`click --element` 报 `engine`，改用 `act` 或按截图坐标点。`type` 的非 ASCII 字符不是所有程序都认，不认时用 `act --value`。客户机息屏时截图报错，先 `ui key` 或 `ui move` 唤醒。
- **Windows**：UAC 提示、锁屏与登录界面上也能操作，`snapshot` 默认取安全桌面上的前台程序；但客户机还没有用户登录过时代理不在运行。
