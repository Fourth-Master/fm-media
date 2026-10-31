#!/usr/bin/env bash
# 下载官方 MobileVLCKit 3.6.0 静态 xcframework（LGPLv2.1+）
# 来源：VideoLAN 官方 CocoaPods 分发包，固定版本 + SHA256 校验
set -euo pipefail

VERSION="3.7.4"
URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.0-20260922-1512.tar.xz"
SHA256="c649c4c47bd065b3a5511746361b5a9066a34033f2df9cbc9454409c0f363b52"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor"
TARGET="$DEST/MobileVLCKit.xcframework"

if [ -d "$TARGET" ]; then
  echo "MobileVLCKit 已存在：$TARGET"
  exit 0
fi

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 下载 MobileVLCKit $VERSION"
curl -fL --retry 5 --retry-delay 3 -o "$TMP/vlc.tar.xz" "$URL"

echo "==> 校验 SHA256"
echo "$SHA256  $TMP/vlc.tar.xz" | shasum -a 256 -c -

echo "==> 解压"
tar -xJf "$TMP/vlc.tar.xz" -C "$TMP"

FOUND="$(find "$TMP" -maxdepth 3 -name "MobileVLCKit.xcframework" -type d | head -1)"
if [ -z "$FOUND" ]; then
  echo "压缩包中未找到 MobileVLCKit.xcframework"; ls -R "$TMP" | head -40; exit 1
fi

cp -R "$FOUND" "$DEST/"
echo "==> 完成：$TARGET"
ls "$TARGET"
