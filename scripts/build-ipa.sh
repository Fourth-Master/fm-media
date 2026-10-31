#!/usr/bin/env bash
# 在 macOS 上本地构建免签 IPA（用于 TrollStore）
# 用法：./scripts/build-ipa.sh [输出文件名]
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="FM影媒"
PROJECT="FM影媒.xcodeproj"
OUT_NAME="${1:-FMMedia.ipa}"
BUILD_DIR="build"

echo "==> 清理"
rm -rf "$BUILD_DIR" Payload "$OUT_NAME"

echo "==> 编译（无签名）"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  build

APP=$(find "$BUILD_DIR/Build/Products/Release-iphoneos" -maxdepth 1 -name "*.app" | head -1)
if [ -z "$APP" ]; then
  echo "未找到 .app 产物"; exit 1
fi

echo "==> 裁剪 + 内嵌框架 ad-hoc 签名"
VLC_FW="$APP/Frameworks/MobileVLCKit.framework"
if [ -d "$VLC_FW" ]; then
  BIN="$VLC_FW/MobileVLCKit"
  if lipo -info "$BIN" | grep -q "arm64"; then
    lipo -thin arm64 "$BIN" -output "$BIN.thin" && mv "$BIN.thin" "$BIN"
    echo "    $(lipo -info "$BIN")"
  fi
  codesign --force --sign - --timestamp=none "$VLC_FW" || true
fi
codesign --force --sign - --timestamp=none "$APP" || true

echo "==> 打包 $OUT_NAME"
mkdir -p Payload
cp -R "$APP" Payload/
zip -qry "$OUT_NAME" Payload
rm -rf Payload

echo "==> 完成：$(pwd)/$OUT_NAME  ($(du -h "$OUT_NAME" | cut -f1))"
echo "把该 IPA 传到手机，用 TrollStore 打开即可安装（无需签名、无需 App Store）。"
