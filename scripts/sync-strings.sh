#!/usr/bin/env bash
# 让编译器抽出源码里的界面文案（SwiftUI 的 LocalizedStringKey、String(l10n:) 等），同步进 packaging/l10n/Localizable.xcstrings，
# 删掉源码里已不再用的条目，再列出还没有中文译文的条目；有就以非零退出。环境变量 SWIFT_FLAGS 是 swift build 的额外参数。
set -euo pipefail
cd "$(dirname "$0")/.."
CATALOG=packaging/l10n/Localizable.xcstrings
# 抽取要带额外的编译参数，单独一个构建目录，免得与 make build 交替时整体重编。
SCRATCH=.build/strings
OUT=$SCRATCH/stringsdata

# 编译器按源文件名写 .stringsdata，不同 target 里同名的文件会互相覆盖。
dup=$(find Sources -name '*.swift' -exec basename {} \; | sort | uniq -d)
[ -z "$dup" ] || { echo "Sources 下有同名源文件，抽取结果会互相覆盖：$dup" >&2; exit 1; }

# shellcheck disable=SC2086 # SWIFT_FLAGS 是多个参数
swift build --scratch-path "$SCRATCH" ${SWIFT_FLAGS:-} -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/$OUT"
[ -f "$CATALOG" ] || printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n  },\n  "version" : "1.0"\n}\n' >"$CATALOG"
# 增量构建只重写改过的文件的 .stringsdata；源文件删掉后留下的那份要清掉，不然它的文案不会被标成过时。
for f in "$OUT"/*.stringsdata; do
  src=$(plutil -extract source raw -o - "$f")
  [ -f "$src" ] || rm "$f"
done
sync() { find "$OUT" -name '*.stringsdata' -print0 | xargs -0 xcrun xcstringstool sync "$CATALOG" --stringsdata; }
sync

# 源码里已经没有的文案会被标成过时，直接删掉（译文留在 git 历史里）；删过之后再同步一次，让文件格式回到 xcstringstool 的写法。
status=0
python3 - "$CATALOG" <<'EOF' || status=$?
import json, sys
path = sys.argv[1]
catalog = json.load(open(path))
strings = catalog["strings"]
stale = [k for k, v in strings.items() if v.get("extractionState") == "stale"]
for k in stale:
    del strings[k]
if stale:
    with open(path, "w") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)
        f.write("\n")
missing = [k for k, v in strings.items()
           if v.get("shouldTranslate", True) and "zh-Hans" not in v.get("localizations", {})]
for k in missing:
    print("缺中文译文：" + k, file=sys.stderr)
sys.exit(1 if missing else 0)
EOF
sync
exit $status
