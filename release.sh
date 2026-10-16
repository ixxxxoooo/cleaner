#!/bin/zsh
# Developer ID 签名 + 公证打包脚本（需要付费开发者账号，本机自用无需执行）
# 前置：钥匙串中有 "Developer ID Application: ..." 证书；已执行
#   xcrun notarytool store-credentials cleaner-notary --apple-id <id> --team-id <team> --password <app 专用密码>
# 用法：DEV_ID="Developer ID Application: Your Name (TEAMID)" ./release.sh
# @author ygw
set -euo pipefail
cd "$(dirname "$0")"
: "${DEV_ID:?请设置 DEV_ID 为 Developer ID Application 证书名称}"
xcodegen generate >/dev/null
xcodebuild -project Cleaner.xcodeproj -scheme Cleaner -configuration Release -derivedDataPath build/release \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEV_ID" ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" build
APP="build/release/Build/Products/Release/Cleaner.app"
ditto -c -k --keepParent "$APP" build/Cleaner.zip
xcrun notarytool submit build/Cleaner.zip --keychain-profile cleaner-notary --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
echo "完成：$APP"
