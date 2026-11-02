#!/usr/bin/env bash
# 公证并装订。需先用 `xcrun notarytool store-credentials macvm` 存好凭据（或设 NOTARY_PROFILE）。
set -euo pipefail
APP=${1:?用法：notarize.sh <App 路径>}
PROFILE=${NOTARY_PROFILE:-macvm}
ZIP="${APP%.app}.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
