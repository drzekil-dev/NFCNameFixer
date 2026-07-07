#!/bin/bash
# 한글 파일명 NFC 변환기 — 빌드 스크립트
# 추가 설치 없이 Xcode 툴체인의 swiftc 만으로 .app 번들을 만든다.
set -euo pipefail
cd "$(dirname "$0")"

APP="NFCNameFixer.app"
BIN="NFCNameFixer"

echo "▶ 이전 빌드 정리"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ Swift 컴파일 (-O)"
swiftc -O \
    -framework CoreServices -framework ServiceManagement -framework AppKit \
    -o "$APP/Contents/MacOS/$BIN" \
    Sources/Converter.swift \
    Sources/MojibakeRestorer.swift \
    Sources/NameRestorer.swift \
    Sources/FolderWatcher.swift \
    Sources/WatchStore.swift \
    Sources/NFCNameFixerApp.swift

echo "▶ Info.plist 복사"
cp Info.plist "$APP/Contents/Info.plist"

echo "▶ 앱 아이콘 복사"
if [ ! -f AppIcon.icns ]; then ./tools/make_icon.sh; fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▶ ad-hoc 코드사인 (로컬 실행 허용)"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "✅ 완료: $(pwd)/$APP"
echo "   실행: open \"$APP\"   (또는 Finder에서 더블클릭)"
