#!/usr/bin/env bash
# 检查 target 分层：依赖只能自上而下（MacVMModel ← MacVMPrivate ← MacVMEngine ← MacVMApp / MacVMCLI），
# MacVMApp 与 MacVMCLI 互不依赖；Virtualization 与私有选择子各限在一个 target；
# 字符串字面量里不写中文。
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

bad=$( { grep -rlE '^\s*(@[A-Za-z]+\s+)*(public\s+|internal\s+)?import\s+MacVMCLI([^[:alnum:]_]|$)' Sources/MacVMApp || true; \
         grep -rlE '^\s*(@[A-Za-z]+\s+)*(public\s+|internal\s+)?import\s+MacVMApp([^[:alnum:]_]|$)' Sources/MacVMCLI || true; } )
[ -n "$bad" ] && { echo "MacVMApp 与 MacVMCLI 不能互相依赖："; echo "$bad"; fail=1; }

# 界面文案的源文本是英文，中文译文在 packaging/l10n 的字符串目录里；注释（含行尾的 // 注释）不受限，"""…""" 多行字面量的每一行都查。
bad=$(find Sources -name '*.swift' -print0 | xargs -0 perl -CSD -ne '
  BEGIN { $cjk = qr/[\x{4e00}-\x{9fff}\x{3000}-\x{303f}\x{ff00}-\x{ffef}]/ }
  if ($multi) { print "$ARGV:$.: $_" if /$cjk/; $multi = 0 if /"""/; }
  elsif (!m{^\s*(//|\*|/\*)}) {
    (my $code = $_) =~ s{\s//\s.*$}{};
    print "$ARGV:$.: $_" if $code =~ /"[^"]*$cjk/;
    $multi = 1 if (() = $code =~ /"""/g) % 2;
  }
  if (eof) { $multi = 0; close ARGV }')
[ -n "$bad" ] && { echo "源码字符串里不要写中文，写英文并用 String(l10n:) 或 LocalizedStringKey 查表："; echo "$bad"; fail=1; }

exit $fail
