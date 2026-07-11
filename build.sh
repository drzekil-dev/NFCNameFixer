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

# 최소 지원 버전. -target 없이 빌드하면 빌드 머신의 OS 버전이 최소 요구
# 버전으로 박혀서(예: Tahoe에서 빌드하면 minos 26.0) 구버전 macOS에서
# "손상됨/열 수 없음"으로 실행이 거부된다. Info.plist의
# LSMinimumSystemVersion(13.0)과 반드시 일치시킬 것.
MIN_MACOS="13.0"
SOURCES=(
    Sources/Converter.swift
    Sources/MojibakeRestorer.swift
    Sources/NameRestorer.swift
    Sources/UpdateChecker.swift
    Sources/FolderWatcher.swift
    Sources/WatchStore.swift
    Sources/NFCNameFixerApp.swift
)

echo "▶ Swift 컴파일 (-O, macOS $MIN_MACOS+, universal)"
for ARCH in arm64 x86_64; do
    swiftc -O \
        -target "$ARCH-apple-macos$MIN_MACOS" \
        -framework CoreServices -framework ServiceManagement -framework AppKit \
        -o "$BUILD_DIR/$BIN-$ARCH" \
        "${SOURCES[@]}"
done
lipo -create -output "$BUILD_APP/Contents/MacOS/$BIN" \
    "$BUILD_DIR/$BIN-arm64" "$BUILD_DIR/$BIN-x86_64"

echo "▶ 최소 버전/아키텍처 검증"
MINOS="$(otool -l "$BUILD_APP/Contents/MacOS/$BIN" | awk '/minos/ {print $2; exit}')"
if [ "$MINOS" != "$MIN_MACOS" ]; then
    echo "오류: 바이너리 minos($MINOS)가 목표($MIN_MACOS)와 다릅니다." >&2
    exit 1
fi
lipo -info "$BUILD_APP/Contents/MacOS/$BIN"

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
