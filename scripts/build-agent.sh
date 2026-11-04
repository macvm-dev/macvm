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
cp target/aarch64-apple-darwin/release/macvm-agent "$out/macvm-agent-darwin"
cp target/aarch64-unknown-linux-musl/release/macvm-agent "$out/macvm-agent-linux"
cp target/aarch64-pc-windows-msvc/release/macvm-agent.exe "$out/macvm-agent-windows.exe"
ls -l "$out"/macvm-agent-*
