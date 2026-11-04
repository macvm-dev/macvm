#!/usr/bin/env bash
# 公证 App 或 DMG 并装订。需先用 `xcrun notarytool store-credentials macvm` 存好凭据（或设 NOTARY_PROFILE）。
set -euo pipefail
TARGET=${1:?用法：notarize.sh <App 或 DMG 路径>}
PROFILE=${NOTARY_PROFILE:-macvm}
# notarytool 收 zip、pkg、dmg：App 要先压成 zip，DMG 直接提交。
case "$TARGET" in
  *.dmg) SUBMIT=$TARGET ;;
  *)
    SUBMIT="${TARGET%.app}.zip"
    ditto -c -k --keepParent "$TARGET" "$SUBMIT"
    trap 'rm -f "$SUBMIT"' EXIT
    ;;
esac
# 公证结果为 Invalid 时 notarytool 照样以 0 退出，要看返回的 status。
result=$(xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait --output-format json)
status=$(plutil -extract status raw -o - - <<<"$result")
if [ "$status" != "Accepted" ]; then
  id=$(plutil -extract id raw -o - - <<<"$result")
  echo "公证未通过（${status}），日志：" >&2
  xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
  exit 1
fi
xcrun stapler staple "$TARGET"
