#!/usr/bin/env bash
# 由 packaging/AppIcon.icon（Icon Composer 文档）编出 packaging/Assets.car 与 packaging/AppIcon.icns，改了图标后运行一次，把两个产物一并提交。
# Assets.car 由系统按 CFBundleIconName 读取，统一裁成圆角方形并跟随深色与染色外观；AppIcon.icns 供 macOS 26 之前的系统使用。
# 需要 Xcode 26 以上的 actool；打包只复制产物，不依赖 Xcode。
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

xcrun actool packaging/AppIcon.icon --compile "$WORK" \
    --output-format human-readable-text --errors --warnings \
    --output-partial-info-plist "$WORK/partial.plist" \
    --app-icon AppIcon --include-all-app-icons --enable-on-demand-resources NO \
    --development-region zh_CN --target-device mac --platform macosx --minimum-deployment-target 15.0 >&2
# 不认 .icon 的 actool 不报错也不出文件。
[[ -s "$WORK/Assets.car" && -s "$WORK/AppIcon.icns" ]] \
    || { echo "actool 没有生成图标（需要 Xcode 26 以上）：$(xcodebuild -version | head -1)" >&2; exit 1; }
mv -f "$WORK/Assets.car" "$WORK/AppIcon.icns" packaging/
echo packaging/Assets.car packaging/AppIcon.icns
