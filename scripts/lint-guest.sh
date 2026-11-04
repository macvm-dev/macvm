#!/usr/bin/env bash
# 对客户机 Rust 工程跑 clippy：代理按它要运行的三个系统各查一遍，引导程序查 UEFI 目标；有警告即失败。
set -euo pipefail
cd "$(dirname "$0")/../guest"
# 直接用 rustup 工具链里的 cargo 与 clippy：PATH 上可能是不带交叉目标标准库的 Homebrew 版本。
TOOLCHAIN_BIN=$(dirname "$(rustup which rustc --toolchain stable)")
export PATH="$TOOLCHAIN_BIN:$PATH"
rustup component add --toolchain stable clippy >/dev/null
rustup target add --toolchain stable aarch64-apple-darwin aarch64-unknown-linux-musl aarch64-pc-windows-msvc aarch64-unknown-uefi >/dev/null

for target in aarch64-apple-darwin aarch64-unknown-linux-musl aarch64-pc-windows-msvc; do
  echo "clippy: $target"
  cargo clippy --all-targets --target "$target" -- -D warnings
done
echo "clippy: aarch64-unknown-uefi"
cargo clippy -p macvm-boot --target aarch64-unknown-uefi -- -D warnings
