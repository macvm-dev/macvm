#!/usr/bin/env bash
# 组装并签名 dist/MacVM.app。环境变量：CONFIG、SIGN_IDENTITY、ENTITLEMENTS、PROVISIONING_PROFILE（可选）。
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
ENTITLEMENTS=${ENTITLEMENTS:-packaging/entitlements/base.entitlements}

swift build -c "$CONFIG"
BIN=.build/$CONFIG
APP=dist/MacVM.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/guest"

cp packaging/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/MacVMApp" "$APP/Contents/MacOS/MacVM"
cp "$BIN/macvm" "$APP/Contents/Resources/bin/macvm"
# 代理与固件是可选产物，缺失时 App 仍可运行，只是相应功能不可用。
for f in guest/agent/dist/* guest/firmware/dist/*; do
  [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/guest/"
done
if [ -n "${PROVISIONING_PROFILE:-}" ]; then
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
fi

sign() { codesign -f --options runtime --timestamp=none -s "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$1"; }
[ "$SIGN_IDENTITY" != "-" ] && sign() { codesign -f --options runtime --timestamp -s "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$1"; }
sign "$APP/Contents/Resources/bin/macvm"
sign "$APP"
codesign --verify --strict --deep "$APP"
echo "$APP"
