#!/bin/bash
# 앱 아이콘 생성: Swift로 PNG 렌더 → .iconset 구성 → iconutil로 AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
echo "▶ 아이콘 렌더(Swift)"
swiftc -O -o "$TMP/makeicon" tools/make_icon.swift
"$TMP/makeicon" "$TMP" >/dev/null

echo "▶ .iconset 구성"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
cp "$TMP/preview_16.png"   "$SET/icon_16x16.png"
cp "$TMP/preview_32.png"   "$SET/icon_16x16@2x.png"
cp "$TMP/preview_32.png"   "$SET/icon_32x32.png"
cp "$TMP/preview_64.png"   "$SET/icon_32x32@2x.png"
cp "$TMP/preview_128.png"  "$SET/icon_128x128.png"
cp "$TMP/preview_256.png"  "$SET/icon_128x128@2x.png"
cp "$TMP/preview_256.png"  "$SET/icon_256x256.png"
cp "$TMP/preview_512.png"  "$SET/icon_256x256@2x.png"
cp "$TMP/preview_512.png"  "$SET/icon_512x512.png"
cp "$TMP/preview_1024.png" "$SET/icon_512x512@2x.png"

echo "▶ iconutil → AppIcon.icns"
iconutil -c icns "$SET" -o AppIcon.icns

rm -rf "$TMP"
echo "✅ 완료: $(pwd)/AppIcon.icns"
