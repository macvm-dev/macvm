#!/usr/bin/env bash
# 把 App 做成拖拽安装的 DMG（App 与「应用程序」替身）并签名。环境变量：SIGN_IDENTITY（缺省 ad-hoc）。
set -euo pipefail
APP=${1:?用法：make-dmg.sh <App 路径> <DMG 路径>}
DMG=${2:?用法：make-dmg.sh <App 路径> <DMG 路径>}
SIGN_IDENTITY=${SIGN_IDENTITY:--}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "$stage/$(basename "$APP")"
ln -s /Applications "$stage/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname MacVM -srcfolder "$stage" -fs HFS+ -format ULFO "$DMG"

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign -f -s - --timestamp=none "$DMG"
else
  codesign -f -s "$SIGN_IDENTITY" --timestamp "$DMG"
fi
echo "$DMG"
