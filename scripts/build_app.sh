#!/bin/bash
# 编译并组装成 DevIsland.app（输出到 dist/）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DevIsland"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

cd "$ROOT"

echo "==> swift build (release)"
swift build -c release

echo "==> 组装 .app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# 如果以后加了图标（Resources/AppIcon.icns），一并拷入
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
fi

# 签名身份的选择很关键：
# - ad-hoc 签名：能启动，但每次重建签名都变，macOS 会重置已授权限（"一直请求权限"）
# - Apple Development 证书：权限能持久，但缺描述文件会导致 Launchd 拒绝启动（error 163）
# - 自签名 Code Signing 证书（名为 DevIsland Local）：既能启动、签名又稳定，权限持久——最佳
# 优先用自签名证书；没有就回退 ad-hoc（保证至少能启动）。
# 不加 -v：自签名证书未被信任，不在 valid 列表里，但仍可用于签名
IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
    | awk '/"DevIsland Local"/{print $2; exit}')
if [ -n "$IDENTITY" ]; then
    echo "==> 用自签名稳定证书签名: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "==> 未找到自签名证书 'DevIsland Local'，回退 ad-hoc（可启动，但权限不持久）"
    echo "    建议先运行 ./scripts/setup_cert.sh 创建稳定证书，再重新构建，权限即可持久。"
    codesign --force --deep --sign - "$APP"
fi

echo "==> 完成: $APP"
echo "    运行: open \"$APP\""
