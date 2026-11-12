#!/bin/bash
# 发版：把 Info.plist 与客户机程序的版本号改成 <版本>，提交「chore: 版本号改为 <版本>」，在这个提交上打 v<版本> 标签，
# 再把当前分支与标签一起推送到 origin，标签触发 Release 工作流。要在没有未提交改动、不落后于 origin 的分支上运行；
# 推送失败时撤销本地的版本提交与标签，修好后可原样重跑。
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:-}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
  || { echo "用法：make tag VERSION=x.y.z（预发布版如 x.y.z-beta.1）" >&2; exit 64; }
tag=v$version
plist=packaging/Info.plist
cargo_toml=guest/Cargo.toml

# $1 比 $2 新时成功。按语义化版本比：先比 x.y.z，相同时正式版比预发布版新，预发布版之间比后缀。
newer() {
  local a=$1 b=$2 core_a=${1%%-*} core_b=${2%%-*}
  if [ "$core_a" != "$core_b" ]; then
    [ "$(printf '%s\n' "$core_a" "$core_b" | sort -V | tail -1)" = "$core_a" ]
    return
  fi
  [ "$a" != "$b" ] || return 1
  [[ "$a" == *-* ]] || return 0
  [[ "$b" == *-* ]] || return 1
  [ "$(printf '%s\n' "${a#*-}" "${b#*-}" | sort -V | tail -1)" = "${a#*-}" ]
}

# 改写 plist 里 $1 键的字符串值；plutil -replace 会重排整个文件的键。
set_plist() {
  sed -i '' -E "/<key>$1<\/key>/{n;s|<string>[^<]*</string>|<string>$2</string>|;}" "$plist"
  [ "$(plutil -extract "$1" raw "$plist")" = "$2" ] || { echo "没能改写 $plist 的 $1" >&2; exit 1; }
}

branch=$(git symbolic-ref --short -q HEAD) || { echo "不在分支上，先切到要发版的分支" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "有未提交的改动，先提交或暂存" >&2; exit 1; }
git fetch --quiet --tags origin
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "标签 $tag 已存在" >&2; exit 1; }
# 落后或分叉时推送会被拒；本地超前的提交随版本提交一起推上去。
if git rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
  git merge-base --is-ancestor "origin/$branch" HEAD || { echo "${branch} 落后于 origin/${branch}，先同步" >&2; exit 1; }
fi

# 发布说明是 GitHub Release 的正文，也是 Sparkle 更新窗口里的说明，要先写好并提交。
notes=docs/releases/$version.md
[ -s "$notes" ] && git cat-file -e "HEAD:$notes" 2>/dev/null \
  || { echo "缺少发布说明 ${notes}：先写好（中文在前、英文在后）并提交" >&2; exit 1; }

current=$(plutil -extract CFBundleShortVersionString raw "$plist")
newer "$version" "$current" || { echo "$version 不比当前的 $current 新" >&2; exit 1; }
# 构建号是 Sparkle 比新旧的依据，要与版本号同序：取版本提交在本分支上的提交数，抬到大于现有构建号与比它旧的各版本标签上的；
# 比它新的版本标签上有不大于它的（从旧版本拉出的分支上提交比之后 main 上的多），装了这一版的就收不到那些更新，停下。
build=$(( $(git rev-list --count HEAD) + 1 ))
floor=$(plutil -extract CFBundleVersion raw "$plist")
ceiling='' ceiling_tag=''
while read -r t; do
  [[ "${t#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || continue
  b=$(git show "$t:$plist" 2>/dev/null | plutil -extract CFBundleVersion raw - 2>/dev/null) || continue
  if newer "$version" "${t#v}"; then
    (( b <= floor )) || floor=$b
  elif [ -z "$ceiling" ] || (( b < ceiling )); then
    ceiling=$b ceiling_tag=$t
  fi
done < <(git tag -l 'v*')
(( build > floor )) || build=$(( floor + 1 ))
[ -z "$ceiling" ] || (( build < ceiling )) \
  || { echo "构建号 ${build} 不小于比它新的 ${ceiling_tag} 的 ${ceiling}，装了这一版的会收不到 ${ceiling_tag} 起的更新" >&2; exit 1; }

base=$(git rev-parse HEAD)
pushed=0
# 退出码保持原样：trap 里最后一条命令的结果会顶替它。
trap 'status=$?; [ $pushed = 1 ] || { git tag -d "$tag" >/dev/null 2>&1 || true; git reset -q --hard "$base"; echo "已撤销本地的版本提交与标签" >&2; }; exit $status' EXIT

set_plist CFBundleShortVersionString "$version"
set_plist CFBundleVersion "$build"
sed -i '' -E "/^\[workspace\.package\]/,/^\[/ s/^version = \"[^\"]*\"/version = \"$version\"/" "$cargo_toml"
grep -q "^version = \"$version\"" "$cargo_toml" || { echo "没能改写 $cargo_toml 的版本号" >&2; exit 1; }
cargo update --quiet --workspace --offline --manifest-path "$cargo_toml"

git commit -q -m "chore: 版本号改为 $version" -- "$plist" "$cargo_toml" guest/Cargo.lock
git tag -a "$tag" -m "MacVM $version"
echo "推送 ${branch} 与 ${tag}（构建号 ${build}）…"
git push --atomic origin "HEAD:refs/heads/$branch" "refs/tags/$tag"
pushed=1
echo "已推送，Release 工作流会构建并发布 $tag"
