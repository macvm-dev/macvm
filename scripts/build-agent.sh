#!/usr/bin/env bash
# 交叉编译客户机代理到 guest/agent/dist/。Linux 版为 musl 静态链接，用 rust-lld 链接，无需额外工具链。
set -euo pipefail
cd "$(dirname "$0")/../guest/agent"
# 直接用 rustup 工具链里的 cargo 与 rustc：PATH 上可能是不带交叉目标标准库的 Homebrew 版本。
TOOLCHAIN_BIN=$(dirname "$(rustup which rustc --toolchain stable)")
export RUSTC="$TOOLCHAIN_BIN/rustc"
CARGO="$TOOLCHAIN_BIN/cargo"
rustup target add --toolchain stable aarch64-unknown-linux-musl >/dev/null

$CARGO build --release --target aarch64-apple-darwin
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
  $CARGO build --release --target aarch64-unknown-linux-musl

mkdir -p dist
cp target/aarch64-apple-darwin/release/macvm-agent dist/macvm-agent-darwin
cp target/aarch64-unknown-linux-musl/release/macvm-agent dist/macvm-agent-linux
ls -l dist
