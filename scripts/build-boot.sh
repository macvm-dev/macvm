#!/usr/bin/env bash
# 编译 UEFI 引导程序 macvm-boot.efi 到 .build/guest/。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/.build/guest
cd "$root/guest"
TOOLCHAIN_BIN=$(dirname "$(rustup which rustc --toolchain stable)")
export RUSTC="$TOOLCHAIN_BIN/rustc"
rustup target add --toolchain stable aarch64-unknown-uefi >/dev/null
"$TOOLCHAIN_BIN/cargo" build --release -p macvm-boot --target aarch64-unknown-uefi
mkdir -p "$out"
cp target/aarch64-unknown-uefi/release/macvm-boot.efi "$out/"
ls -l "$out/macvm-boot.efi"
