#!/bin/zsh
# 重新编译并重启应用（修改代码后必须执行，确保改动在运行时真实生效）
# 重新签名时把 designated requirement 固定为 identifier "ixxxxoooo"，
# 避免 ad-hoc 签名每次 cdhash 变化导致「完全磁盘访问权限」授权失效。
# @author ygw
set -e
cd "$(dirname "$0")"
BUNDLE_ID="ixxxxoooo"
APP="build/Build/Products/Debug/Cleaner.app"

xcodegen generate >/dev/null
xcodebuild -project Cleaner.xcodeproj -scheme Cleaner -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

# 固定签名身份：先签内部动态库，再签 App 本体
setopt null_glob
for f in "$APP"/Contents/MacOS/*.dylib; do
  codesign --force --sign - -o runtime --identifier "$BUNDLE_ID" "$f"
done
codesign --force --sign - -o runtime --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated

pkill -x Cleaner 2>/dev/null || true
sleep 0.5
open -n "$APP"
echo "已重启 Cleaner（Bundle ID: $BUNDLE_ID）"
