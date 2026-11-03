#!/usr/bin/env bash
# 编译 UEFI 引导程序 macvm-boot.efi 到 guest/firmware/dist/。
set -euo pipefail
cd "$(dirname "$0")/../guest/firmware"
TOOLCHAIN_BIN=$(dirname "$(rustup which rustc --toolchain stable)")
export RUSTC="$TOOLCHAIN_BIN/rustc"
rustup target add --toolchain stable aarch64-unknown-uefi >/dev/null
"$TOOLCHAIN_BIN/cargo" build --release --target aarch64-unknown-uefi
mkdir -p dist
cp target/aarch64-unknown-uefi/release/macvm-boot.efi dist/
ls -l dist
