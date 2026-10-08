#!/bin/bash
# DropProcessor 통합 테스트 — 패널 드롭존이 받는 경로 묶음을 GUI 없이 그대로 처리해 본다.
# (zip 은 내부 이름 수정, 그 외는 NFC 변환, 폴더 안의 zip 내부는 불가침)
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d /tmp/nfcdrop.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/dropproc"

echo "▶ 드롭 처리 하니스 컴파일"
swiftc -O -o "$BIN" Sources/Converter.swift Sources/ZipNameFixer.swift Sources/DropProcessor.swift tests/drop/main.swift

fail=0
pass() { echo "PASS: $1"; }
failmsg() { echo "FAIL: $1"; fail=$((fail+1)); }

# 픽스처: NFD 폴더(안에 NFD 파일 + NFD 이름의 zip), NFD 단일 파일, 직접 드롭할 Finder zip, CP949 zip
python3 - "$WORK" <<'PY'
import os, sys, struct, zlib, unicodedata
root = sys.argv[1]; N = lambda s: unicodedata.normalize("NFD", s)
d = os.path.join(root, "drop", N("작업폴더")); os.makedirs(d)
open(os.path.join(d, N("메모.txt")), "w").write("memo")
open(os.path.join(root, "drop", N("단일파일.txt")), "w").write("single")
os.makedirs(os.path.join(root, "zsrc")); open(os.path.join(root, "zsrc", N("압축내용.txt")), "w").write("zipped")
name = "보고서.txt".encode("cp949"); data = b"x"; crc = zlib.crc32(data)
z = struct.pack("<IHHHHHIIIHH", 0x04034b50, 20, 0, 0, 0, 0x21, crc, 1, 1, len(name), 0) + name + data
cd = struct.pack("<IHHHHHHIIIHHHHHII", 0x02014b50, 20, 20, 0, 0, 0, 0x21, crc, 1, 1, len(name), 0, 0, 0, 0, 0, 0) + name
open(os.path.join(root, "drop", "win.zip"), "wb").write(z + cd + struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, 1, 1, len(cd), len(z), 0))
# 이름 충돌 zip: NFD '같음.txt' 와 NFC '같음.txt' 가 함께 든 경우 → 고칠 수 없음(오류)
out = bytearray(); cdir = bytearray()
for nm, fl, body in [(unicodedata.normalize("NFD", "같음.txt").encode(), 0, b"one"), (unicodedata.normalize("NFC", "같음.txt").encode(), 0x800, b"two")]:
    c = zlib.crc32(body); off = len(out)
    out += struct.pack("<IHHHHHIIIHH", 0x04034b50, 20, fl, 0, 0, 0x21, c, len(body), len(body), len(nm), 0) + nm + body
    cdir += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014b50, 20, 20, fl, 0, 0, 0x21, c, len(body), len(body), len(nm), 0, 0, 0, 0, 0, off) + nm
open(os.path.join(root, "drop", "dup.zip"), "wb").write(bytes(out) + bytes(cdir) + struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, 2, 2, len(cdir), len(out), 0))
PY
FOLDER="$WORK/drop/$(ls "$WORK/drop" | grep -v -e '\.txt$' -e '\.zip$')"
FILE="$WORK/drop/$(ls "$WORK/drop" | grep '\.txt$')"
(cd "$WORK/zsrc" && ditto -c -k --sequesterRsrc . "$WORK/drop/direct.zip")
# 폴더 안의 zip: 파일 이름은 NFD, 내부 이름도 NFD
INNER_NFD="$(python3 -c "import unicodedata;print(unicodedata.normalize('NFD','안쪽압축.zip'))")"
cp "$WORK/drop/direct.zip" "$FOLDER/$INNER_NFD"
inner_md5="$(md5 -q "$FOLDER/$INNER_NFD")"

echo "▶ 폴더 + 파일 + zip + 윈도 zip 을 한 번에 드롭"
cp "$WORK/drop/win.zip" "$WORK/win.orig.zip"
out="$("$BIN" "$FOLDER" "$FILE" "$WORK/drop/direct.zip" "$WORK/drop/win.zip" "$WORK/drop/dup.zip")"
echo "$out" | sed 's/^/   /'

# 폴더(1) + 메모(1) + 안쪽 zip 파일명(1) + 단일 파일(1) = 변환 4, 검사 4
[[ "$out" == *"변환 4개 · 검사 4개"* ]] && pass "폴더·파일 NFC 변환 4개" || failmsg "변환 요약"
[[ "$out" == *"zip 3개: 이름 수정 1개 · 항목 제거 "*"오류 1개"* ]] && pass "zip 3개 중 1개 수정·1개 오류 요약" || failmsg "zip 요약"
[[ "$out" == *"⚠︎ dup.zip: 미지원 zip"* ]] && pass "이름 충돌 zip 실패 사유 표시" || failmsg "오류 사유 줄"
[[ "$out" != *"win.zip"* ]] && cmp -s "$WORK/drop/win.zip" "$WORK/win.orig.zip" && pass "윈도 zip 은 오류 아님·원본 그대로" || failmsg "윈도 zip 처리"
[[ "$out" == *"folders=작업폴더"* ]] && pass "드롭된 폴더만 감시 대상으로 보고" || failmsg "folders 줄"

[[ "$(./check.sh "$WORK/drop" | tail -1)" == *"0개"* ]] && pass "디스크의 파일·폴더 이름 전부 NFC" || failmsg "디스크에 NFD 잔존"
python3 - "$WORK/drop/direct.zip" <<'PY' && pass "직접 드롭한 zip 내부 이름 NFC·플래그·__MACOSX 제거" || failmsg "직접 드롭 zip 내부"
import sys, zipfile, unicodedata
L = zipfile.ZipFile(sys.argv[1]).infolist()
ok = L and all(i.filename == unicodedata.normalize("NFC", i.filename) and not i.filename.startswith("__MACOSX")
               and (i.filename.isascii() or i.flag_bits & 0x800) for i in L)
sys.exit(0 if ok else 1)
PY
INNER="$WORK/drop/작업폴더/안쪽압축.zip"
[[ -f "$INNER" ]] && [[ "$(md5 -q "$INNER")" == "$inner_md5" ]] && pass "폴더 안의 zip 은 내용 불가침(이름만 NFC)" || failmsg "폴더 안 zip 이 변경됨"

echo "▶ 같은 묶음을 다시 드롭 (멱등)"
out2="$("$BIN" "$WORK/drop/작업폴더" "$WORK/drop/단일파일.txt" "$WORK/drop/direct.zip")"
[[ "$out2" == *"변환 0개"* ]] && [[ "$out2" == *"이름 수정 0개 · 항목 제거 0개"* ]] && pass "재드롭 시 변경 0" || failmsg "재드롭: $out2"

if [ "$fail" -eq 0 ]; then echo; echo "✅ 드롭 테스트 전체 통과"; else echo; echo "❌ 드롭 테스트 실패 ${fail}건"; exit 1; fi
