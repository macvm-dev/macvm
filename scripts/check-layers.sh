#!/usr/bin/env bash
# 检查 target 分层：依赖只能自上而下（MacVMModel ← MacVMPrivate ← MacVMEngine ← MacVMApp / MacVMCLI），
# MacVMApp 与 MacVMCLI 互不依赖，MacVMNetHelper 只依赖 MacVMModel；Virtualization 与私有选择子各限在一个 target。
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0

bad=$(grep -rlE '^\s*(@preconcurrency\s+)?(public\s+|internal\s+)?import\s+Virtualization' Sources --include='*.swift' | grep -v '^Sources/MacVMEngine/' || true)
[ -n "$bad" ] && { echo "只有 MacVMEngine 可以 import Virtualization："; echo "$bad"; fail=1; }

bad=$(grep -rlE 'NSSelectorFromString\("_' Sources --include='*.swift' | grep -v '^Sources/MacVMPrivate/' || true)
[ -n "$bad" ] && { echo "私有选择子只能出现在 MacVMPrivate："; echo "$bad"; fail=1; }

bad=$(grep -rlE '^\s*(public\s+)?import\s+MacVM(Engine|Private)' Sources/MacVMModel || true)
[ -n "$bad" ] && { echo "MacVMModel 不能依赖上层："; echo "$bad"; fail=1; }

bad=$(grep -rlE '^\s*(public\s+)?import\s+MacVMEngine' Sources/MacVMPrivate || true)
[ -n "$bad" ] && { echo "MacVMPrivate 不能依赖 MacVMEngine："; echo "$bad"; fail=1; }

bad=$(grep -rlE '^\s*(public\s+)?import\s+MacVM(Engine|Private)' Sources/MacVMNetHelper || true)
[ -n "$bad" ] && { echo "MacVMNetHelper 只能依赖 MacVMModel："; echo "$bad"; fail=1; }

bad=$( { grep -rlE '^\s*(@[A-Za-z]+\s+)*(public\s+|internal\s+)?import\s+MacVMCLI([^[:alnum:]_]|$)' Sources/MacVMApp || true; \
         grep -rlE '^\s*(@[A-Za-z]+\s+)*(public\s+|internal\s+)?import\s+MacVMApp([^[:alnum:]_]|$)' Sources/MacVMCLI || true; } )
[ -n "$bad" ] && { echo "MacVMApp 与 MacVMCLI 不能互相依赖："; echo "$bad"; fail=1; }

exit $fail
