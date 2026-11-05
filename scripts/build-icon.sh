#!/usr/bin/env bash
# make icon 由 Icon Composer 文档编出 Assets.car、AppIcon.icns 和 README 预览，改图标后将产物一并提交。
# Assets.car 由系统按 CFBundleIconName 读取，统一裁成圆角方形并跟随深色与染色外观；AppIcon.icns 供 macOS 26 之前的系统使用。
# 需要 Xcode 26 以上的 actool；打包只复制产物，不依赖 Xcode。
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# actool 的后台进程会沿用先前调用的工作目录，输入要给绝对路径。
xcrun actool "$PWD/packaging/icon/AppIcon.icon" --compile "$WORK" \
    --output-format human-readable-text --errors --warnings \
    --output-partial-info-plist "$WORK/partial.plist" \
    --app-icon AppIcon --include-all-app-icons --enable-on-demand-resources NO \
    --development-region zh_CN --target-device mac --platform macosx --minimum-deployment-target 15.0 >&2
# 不认 .icon 的 actool 不报错也不出文件。
[[ -s "$WORK/Assets.car" && -s "$WORK/AppIcon.icns" ]] \
    || { echo "actool 没有生成图标（需要 Xcode 26 以上）：$(xcodebuild -version | head -1)" >&2; exit 1; }
sips -s format png -z 256 256 "$WORK/AppIcon.icns" --out "$WORK/icon.png" >/dev/null
mv -f "$WORK/Assets.car" "$WORK/AppIcon.icns" packaging/icon/
mv -f "$WORK/icon.png" docs/images/icon.png
echo packaging/icon/Assets.car packaging/icon/AppIcon.icns docs/images/icon.png
