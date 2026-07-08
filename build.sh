#!/bin/bash
# 한글 파일명 NFC 변환기 — 빌드 스크립트
# 추가 설치 없이 Xcode 툴체인의 swiftc 만으로 .app 번들을 만든다.
#
# 주의: 이 저장소가 iCloud 동기화 폴더(~/Documents 등) 안에 있으면 fileprovider가
# 번들에 xattr(FinderInfo 등)을 계속 다시 붙여 codesign이 "detritus" 에러로 실패한다.
# 그래서 조립·서명은 임시 폴더(iCloud 밖)에서 하고, 완성본만 저장소로 가져온다.
set -euo pipefail
cd "$(dirname "$0")"

APP="NFCNameFixer.app"
BIN="NFCNameFixer"
BUILD_DIR="$(mktemp -d /tmp/nfcbuild.XXXXXX)"
BUILD_APP="$BUILD_DIR/$APP"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "▶ 임시 폴더에 번들 조립: $BUILD_DIR"
mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources"

echo "▶ Swift 컴파일 (-O)"
swiftc -O \
    -framework CoreServices -framework ServiceManagement -framework AppKit \
    -o "$BUILD_APP/Contents/MacOS/$BIN" \
    Sources/Converter.swift \
    Sources/MojibakeRestorer.swift \
    Sources/NameRestorer.swift \
    Sources/UpdateChecker.swift \
    Sources/FolderWatcher.swift \
    Sources/WatchStore.swift \
    Sources/NFCNameFixerApp.swift

echo "▶ Info.plist / 아이콘 복사"
cp Info.plist "$BUILD_APP/Contents/Info.plist"
if [ ! -f AppIcon.icns ]; then ./tools/make_icon.sh; fi
cp AppIcon.icns "$BUILD_APP/Contents/Resources/AppIcon.icns"
xattr -cr "$BUILD_APP"   # 혹시 딸려온 xattr 제거 (codesign은 detritus를 거부)

echo "▶ ad-hoc 코드사인 + 검증 (에러 숨기지 않음)"
codesign --force --deep --sign - "$BUILD_APP"
codesign --verify --deep --strict "$BUILD_APP"
echo "  서명 검증 통과"

echo "▶ 저장소로 복사"
rm -rf "$APP"
ditto "$BUILD_APP" "$APP"
codesign --verify --deep --strict "$APP"
echo "  복사본 서명 검증 통과"

echo "▶ 배포용 zip 생성 (xattr 없이)"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
rm -f "NFCNameFixer-$VERSION.zip"
ditto -c -k --keepParent --norsrc --noextattr --noacl "$BUILD_APP" "NFCNameFixer-$VERSION.zip"

echo "✅ 완료: $(pwd)/$APP  +  NFCNameFixer-$VERSION.zip"
echo "   실행: open \"$APP\"   (또는 Finder에서 더블클릭)"
