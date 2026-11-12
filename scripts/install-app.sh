#!/bin/bash
# 用 dist/MacVM.app 替换 /Applications/MacVM.app。替换前请正在运行的那份退出：走 App 正常的退出流程，
# 运行中的虚拟机照常询问转到后台、挂起还是关机；用户取消退出就不替换。替换前在运行的，装好后重新打开。
set -euo pipefail

SRC=${1:-dist/MacVM.app}
DEST=/Applications/MacVM.app
EXE="$DEST/Contents/MacOS/MacVM"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ -d "$SRC" ] || { echo "找不到 ${SRC}，先 make app 或 make release" >&2; exit 1; }

# 按可执行文件路径认进程，后面可以带启动参数；不能只比整行，漏认会把运行中的 App 包删掉。
running() { pgrep -f "^$EXE( |$)" >/dev/null; }

was_running=0
if running; then
  was_running=1
  echo "退出正在运行的 ${DEST}…"
  # 退出时 App 可能要等虚拟机挂起或关机，给足时间；用户取消退出时 osascript 报错，这里就停下。
  osascript -e "with timeout of 3600 seconds" -e "tell application \"$DEST\" to quit" -e "end timeout" >/dev/null \
    || { echo "MacVM 没有退出，未替换" >&2; exit 1; }
  for _ in $(seq 100); do running || break; sleep 0.2; done
  running && { echo "MacVM 仍在运行，未替换" >&2; exit 1; }
fi

# 先完整复制到旁边再换上，复制中途失败时原来的 App 还在。
NEW="/Applications/.MacVM.app.installing"
rm -rf "$NEW"
ditto "$SRC" "$NEW"
rm -rf "$DEST"
mv "$NEW" "$DEST"
"$LSREGISTER" -f "$DEST"
echo "已安装 $DEST"

if [ "$was_running" = 1 ]; then open "$DEST"; fi
