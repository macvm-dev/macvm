#!/usr/bin/env bash
# 交叉编译客户机代理到 .build/guest/。Linux 版为 musl 静态链接，用 rust-lld 链接；
# Windows 版用 cargo-xwin（cargo install cargo-xwin），首次运行会下载 MSVC 运行库与 Windows SDK。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/.build/guest
cd "$root/guest"
# 直接用 rustup 工具链里的 cargo 与 rustc：PATH 上可能是不带交叉目标标准库的 Homebrew 版本。
TOOLCHAIN_BIN=$(dirname "$(rustup which rustc --toolchain stable)")
export RUSTC="$TOOLCHAIN_BIN/rustc"
CARGO="$TOOLCHAIN_BIN/cargo"
rustup target add --toolchain stable aarch64-unknown-linux-musl aarch64-pc-windows-msvc >/dev/null

$CARGO build --release -p macvm-agent --target aarch64-apple-darwin
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
  $CARGO build --release -p macvm-agent --target aarch64-unknown-linux-musl

PATH="$TOOLCHAIN_BIN:${CARGO_HOME:-$HOME/.cargo}/bin:$PATH" cargo-xwin xwin build --release -p macvm-agent --target aarch64-pc-windows-msvc

mkdir -p "$out"
# macOS 版装成 App 包：客户机「登录项」里按包名显示为 MacVM Agent，不显示签名的开发者名。
# 这里 ad-hoc 签好整个包，scripts/bundle-app.sh 正式签名时重签。
app="$out/MacVM Agent.app"
rm -rf "$app" "$out/macvm-agent-darwin"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp target/aarch64-apple-darwin/release/macvm-agent "$app/Contents/MacOS/macvm-agent"
cp "$root/packaging/agent/Info.plist" "$app/Contents/Info.plist"
version=$(sed -n '/^\[workspace\.package\]/,/^\[/ s/^version = "\(.*\)"/\1/p' Cargo.toml)
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
cp "$root/packaging/icon/AppIcon.icns" "$app/Contents/Resources/"
codesign -f -s - --timestamp=none "$app"
cp target/aarch64-unknown-linux-musl/release/macvm-agent "$out/macvm-agent-linux"
cp target/aarch64-pc-windows-msvc/release/macvm-agent.exe "$out/macvm-agent-windows.exe"
ls -ld "$out"/macvm-agent-* "$app"
