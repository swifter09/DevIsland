#!/bin/bash
# 把 dist/DevIsland.app 打包成 DMG（先运行 build_app.sh）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DevIsland"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$DIST/$APP_NAME-$VERSION.dmg"

if [ ! -d "$APP" ]; then
    echo "未找到 $APP，先运行 scripts/build_app.sh" >&2
    exit 1
fi

echo "==> 准备 DMG 内容"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> 生成 DMG"
rm -f "$DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG"

echo "==> 完成: $DMG"
echo "    （对外分发还需: 开发者证书签名 + notarytool 公证 + stapler）"
