#!/usr/bin/env bash
# 组装并签名 App。环境变量：APP（输出路径，默认 dist/MacVM.app）、CONFIG、SIGN_IDENTITY、SWIFT_FLAGS（swift build 的额外参数）、
# PROVISIONING_PROFILE（可选，Developer ID 描述文件；ad-hoc 签名时不用它）、
# ENTITLEMENTS（App 主程序的权限；不给时有描述文件就带桥接网络的权限，没有就只带基础权限）。
# 受限 entitlement 要由描述文件授权，否则系统拒绝启动 App：ENTITLEMENTS 里有而描述文件没授权的，这里直接停下。
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
PROVISIONING_PROFILE=${PROVISIONING_PROFILE:-}
if [ -n "$PROVISIONING_PROFILE" ] && [ "$SIGN_IDENTITY" = - ]; then
  echo "ad-hoc 签名用不上描述文件，App 将不带桥接网络的权限" >&2
  PROVISIONING_PROFILE=
fi
if [ -z "${ENTITLEMENTS:-}" ]; then
  ENTITLEMENTS=packaging/entitlements/base.entitlements
  [ -z "$PROVISIONING_PROFILE" ] || ENTITLEMENTS=packaging/entitlements/bridged.entitlements
fi
SIGN_TMP=$(mktemp -d)
trap 'rm -rf "$SIGN_TMP"' EXIT
if [ -n "$PROVISIONING_PROFILE" ]; then
  security cms -D -i "$PROVISIONING_PROFILE" >"$SIGN_TMP/profile.plist"
  expires=$(plutil -extract ExpirationDate raw "$SIGN_TMP/profile.plist")
  # 两边都是 UTC 的 ISO 8601，按字典序比较。
  if [[ "$expires" < "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]]; then
    echo "描述文件 $PROVISIONING_PROFILE 已于 $expires 过期" >&2
    exit 1
  fi
  profile_app=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$SIGN_TMP/profile.plist")
  profile_team=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "$SIGN_TMP/profile.plist")
  bundle_id=$(plutil -extract CFBundleIdentifier raw packaging/Info.plist)
  if [ "$profile_app" != "$profile_team.$bundle_id" ]; then
    echo "描述文件 $PROVISIONING_PROFILE 是给 $profile_app 的，不是 $bundle_id" >&2
    exit 1
  fi
fi
restricted=$(/usr/libexec/PlistBuddy -c Print "$ENTITLEMENTS" | sed -nE 's/^ +(com\.apple\.(vm|developer)\.[^ ]+) = .*/\1/p')
for key in $restricted; do
  if [ -z "$PROVISIONING_PROFILE" ]; then
    echo "$ENTITLEMENTS 里的 $key 是受限 entitlement，需要 PROVISIONING_PROFILE 与正式签名" >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$SIGN_TMP/profile.plist" >/dev/null 2>&1 || {
    echo "描述文件 $PROVISIONING_PROFILE 没有授权 $key" >&2
    exit 1
  }
done

# shellcheck disable=SC2086 # SWIFT_FLAGS 是多个参数
swift build -c "$CONFIG" ${SWIFT_FLAGS:-}
BIN=.build/$CONFIG
APP=${APP:-dist/MacVM.app}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/guest"

cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/icon/Assets.car packaging/icon/AppIcon.icns "$APP/Contents/Resources/"
# 字符串目录编译成各语言的 .lproj。英文是源语言，表里没有英文条目时 xcstringstool 不产出 en.lproj，
# 但 Bundle 只在列出的语言里挑，缺了它英文用户会被落到中文，所以补一个空的。
for catalog in packaging/l10n/*.xcstrings; do
  xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources" >/dev/null
done
mkdir -p "$APP/Contents/Resources/en.lproj"
cp "$BIN/MacVMApp" "$APP/Contents/MacOS/MacVM"
cp "$BIN/macvm" "$APP/Contents/Resources/bin/macvm"
# 给 agent 用的技能，App 菜单里可以装进各 agent 的技能目录。
cp -R skills "$APP/Contents/Resources/skills"
# 代理与引导程序是可选产物，缺失时 App 仍可运行，只是相应功能不可用。
for f in .build/guest/*; do
  if [ -f "$f" ]; then cp "$f" "$APP/Contents/Resources/guest/"; fi
  if [ -d "$f" ]; then cp -R "$f" "$APP/Contents/Resources/guest/"; fi
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
# 检查与安装更新用的 Sparkle。App 没开沙盒，用不到它的 XPC 服务。
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$SPARKLE"
rm -rf "$SPARKLE/XPCServices" "$SPARKLE/Versions/B/XPCServices"
APP_ENTITLEMENTS=$ENTITLEMENTS
if [ -n "$PROVISIONING_PROFILE" ]; then
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  # 系统按签名里的应用标识与团队标识找到描述文件，受限 entitlement 才算被它授权；两个值取自描述文件。
  APP_ENTITLEMENTS=$SIGN_TMP/app.entitlements
  cp "$ENTITLEMENTS" "$APP_ENTITLEMENTS"
  for key in com.apple.application-identifier com.apple.developer.team-identifier; do
    value=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$SIGN_TMP/profile.plist")
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$APP_ENTITLEMENTS"
  done
fi

# ad-hoc 签名没有 Team ID，开 hardened runtime 后库校验会拒绝加载自带 QEMU 的库，所以只在正式签名时开。
# 公证要求可信时间戳；只有 release 构建去取，开发构建不必每个文件都连一次时间戳服务器。
SIGN_OPTIONS=(--timestamp=none)
if [ "$SIGN_IDENTITY" != "-" ]; then
  SIGN_OPTIONS=(--options runtime)
  if [ "$CONFIG" = release ]; then SIGN_OPTIONS+=(--timestamp); else SIGN_OPTIONS+=(--timestamp=none); fi
fi
sign() { codesign -f "${SIGN_OPTIONS[@]}" -s "$SIGN_IDENTITY" --entitlements "$1" "$2"; }
# 库与客户机程序不带权限。
sign_plain() { codesign -f "${SIGN_OPTIONS[@]}" -s "$SIGN_IDENTITY" "$1"; }
# 描述文件只授权 App 主程序；包内单独的命令行带上受限 entitlement 会被系统拒绝启动，所以只签基础权限。
sign packaging/entitlements/base.entitlements "$APP/Contents/Resources/bin/macvm"
# 公证检查 App 里的每个 Mach-O，放进客户机的代理（macOS 版是 App 包）也得重签，不能留着 ad-hoc 签名。
for f in "$APP"/Contents/Resources/guest/*; do
  if [ -d "$f" ] || file -b "$f" | grep -q '^Mach-O'; then sign_plain "$f"; fi
done
if [ -d "$APP/Contents/Resources/QEMU" ]; then
  for f in "$APP"/Contents/Resources/QEMU/lib/*.dylib "$APP/Contents/Resources/QEMU/bin/virgl_render_server"; do
    sign_plain "$f"
  done
  sign packaging/entitlements/qemu.entitlements "$APP/Contents/Resources/QEMU/bin/qemu-system-aarch64"
fi
# Sparkle 由内而外重签，与 App 同一身份，hardened runtime 的库校验才放行。
sign_plain "$SPARKLE/Versions/B/Autoupdate"
sign_plain "$SPARKLE/Versions/B/Updater.app"
sign_plain "$SPARKLE"
sign "$APP_ENTITLEMENTS" "$APP"
if [ -n "$PROVISIONING_PROFILE" ]; then
  # 描述文件只对它收录的证书签出的 App 有效：签名证书不在其中时签名与公证都能过，系统却拒绝启动 App。
  fingerprint() { openssl x509 -inform DER -noout -fingerprint -sha1; }
  codesign -d --extract-certificates="$SIGN_TMP/cert" "$APP" 2>/dev/null
  signer=$(fingerprint <"$SIGN_TMP/cert0")
  listed=false
  i=0
  while /usr/libexec/PlistBuddy -c "Print :DeveloperCertificates:$i" "$SIGN_TMP/profile.plist" >"$SIGN_TMP/listed.cer" 2>/dev/null; do
    if [ "$(fingerprint <"$SIGN_TMP/listed.cer" 2>/dev/null)" = "$signer" ]; then listed=true; fi
    i=$((i + 1))
  done
  if [ "$listed" = false ]; then
    echo "描述文件 $PROVISIONING_PROFILE 没有收录签名用的证书（$SIGN_IDENTITY），这样签出的 App 启动不了" >&2
    exit 1
  fi
fi
codesign --verify --strict --deep "$APP"
echo "$APP"
