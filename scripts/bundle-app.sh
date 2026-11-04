#!/usr/bin/env bash
# 组装并签名 App。环境变量：APP（输出路径，默认 dist/MacVM.app）、CONFIG、SIGN_IDENTITY、ENTITLEMENTS、SWIFT_FLAGS（swift build 的额外参数）、PROVISIONING_PROFILE（可选；ENTITLEMENTS 里有受限 entitlement，如 USB 配件访问时必须提供，否则系统拒绝启动 App）。
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
ENTITLEMENTS=${ENTITLEMENTS:-packaging/entitlements/base.entitlements}

# shellcheck disable=SC2086 # SWIFT_FLAGS 是多个参数
swift build -c "$CONFIG" ${SWIFT_FLAGS:-}
BIN=.build/$CONFIG
APP=${APP:-dist/MacVM.app}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/guest" "$APP/Contents/Library/LaunchDaemons"

cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/icon/Assets.car packaging/icon/AppIcon.icns "$APP/Contents/Resources/"
cp "$BIN/MacVMApp" "$APP/Contents/MacOS/MacVM"
cp "$BIN/macvm" "$APP/Contents/Resources/bin/macvm"
# 网络辅助程序由 App 经 SMAppService 注册成 launchd 守护进程，路径与 plist 里的 BundleProgram 对应。
cp "$BIN/macvm-netd" "$APP/Contents/MacOS/macvm-netd"
cp packaging/launchd/cn.barey.macvm.netd.plist "$APP/Contents/Library/LaunchDaemons/"
# 代理与引导程序是可选产物，缺失时 App 仍可运行，只是相应功能不可用。
for f in .build/guest/*; do
  [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/guest/"
done
# 自带的 QEMU 是可选产物（make qemu 编译，首次较久）；缺失时 QEMU 引擎退回用 Homebrew 的 QEMU。
QEMU_DIR=$(ls -dt .build/qemu/*-*/QEMU 2>/dev/null | head -1 || true)
if [ -n "$QEMU_DIR" ]; then
  cp -R "$QEMU_DIR" "$APP/Contents/Resources/QEMU"
  # CocoaSpice 在主 bundle 的 Resources 下按这个名字找 Metal 着色器。
  mv "$APP/Contents/Resources/QEMU/share/CocoaSpice_CocoaSpiceRenderer.bundle" "$APP/Contents/Resources/"
else
  echo "未找到自带 QEMU（make qemu），App 将使用 Homebrew 的 QEMU" >&2
fi
if [ -n "${PROVISIONING_PROFILE:-}" ]; then
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
fi

# ad-hoc 签名没有 Team ID，开 hardened runtime 后库校验会拒绝加载自带 QEMU 的库，所以只在正式签名时开。
SIGN_OPTIONS=(--timestamp=none)
[ "$SIGN_IDENTITY" = "-" ] || SIGN_OPTIONS=(--options runtime --timestamp)
sign() { codesign -f "${SIGN_OPTIONS[@]}" -s "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$1"; }
# 库与辅助程序不带权限。
sign_plain() { codesign -f "${SIGN_OPTIONS[@]}" -s "$SIGN_IDENTITY" "$1"; }
sign "$APP/Contents/Resources/bin/macvm"
sign_plain "$APP/Contents/MacOS/macvm-netd"
# 公证检查 App 里的每个 Mach-O，放进 macOS 客户机的代理也得重签，不能留着链接器的 ad-hoc 签名。
for f in "$APP"/Contents/Resources/guest/*; do
  if file -b "$f" | grep -q '^Mach-O'; then sign_plain "$f"; fi
done
if [ -d "$APP/Contents/Resources/QEMU" ]; then
  for f in "$APP"/Contents/Resources/QEMU/lib/*.dylib "$APP/Contents/Resources/QEMU/bin/virgl_render_server"; do
    sign_plain "$f"
  done
  ENTITLEMENTS=packaging/entitlements/qemu.entitlements sign "$APP/Contents/Resources/QEMU/bin/qemu-system-aarch64"
fi
sign "$APP"
codesign --verify --strict --deep "$APP"
echo "$APP"
