#!/bin/bash
# 감시 폴더 zip 자동 수정 통합 테스트 — 실제 FSEvents 로 임시 폴더를 감시한다(약 20초).
# 원칙 검증: 감시 폴더의 zip 은 전부 처리되고, 안 된 것만 알려진다.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(cd "$(mktemp -d /tmp/nfcauto.XXXXXX)" && pwd -P)"   # FSEvents 는 실경로(/private/tmp)를 보고한다
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/autofix"
W="$WORK/watched"

echo "▶ 감시 하니스 컴파일"
swiftc -O -framework CoreServices -o "$BIN" \
    Sources/Converter.swift Sources/ZipNameFixer.swift Sources/ArchiveAutoFixer.swift Sources/FolderWatcher.swift tests/auto/main.swift

fail=0
pass() { echo "PASS: $1"; }
failmsg() { echo "FAIL: $1"; fail=$((fail+1)); }
count() { grep -c -- "$1" "$WORK/out.txt" || true; }

# --- 픽스처 ---
mkdir -p "$W/하위" "$WORK/src" "$WORK/stage"
python3 - "$WORK" <<'PY'
import os, sys, struct, zlib, unicodedata
root = sys.argv[1]; NFD = lambda s: unicodedata.normalize("NFD", s); NFC = lambda s: unicodedata.normalize("NFC", s)
open(os.path.join(root, "src", NFD("내부파일.txt")), "w").write("body " * 200)
def make(path, entries):
    out = bytearray(); cd = bytearray()
    for n, fl, data in entries:
        c = zlib.crc32(data); off = len(out)
        out += struct.pack("<IHHHHHIIIHH", 0x04034b50, 20, fl, 0, 0, 0x21, c, len(data), len(data), len(n), 0) + n + data
        cd += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014b50, 20, 20, fl, 0, 0, 0x21, c, len(data), len(data), len(n), 0, 0, 0, 0, 0, off) + n
    open(path, "wb").write(bytes(out) + bytes(cd) + struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, len(entries), len(entries), len(cd), len(out), 0))
make(os.path.join(root, "stage", "dup.zip"), [(NFD("같음.txt").encode(), 0, b"one"), (NFC("같음.txt").encode(), 0x800, b"two")])
make(os.path.join(root, "stage", "win.zip"), [("보고서.txt".encode("cp949"), 0, b"x")])
PY
(cd "$WORK/src" && ditto -c -k --sequesterRsrc . "$WORK/stage/mac.zip")
SIZE="$(stat -f %z "$WORK/stage/mac.zip")"; HALF=$((SIZE / 2))
NEW_NFD="$(python3 -c "import unicodedata;print(unicodedata.normalize('NFD','새압축.zip'))")"

# 앱이 꺼져 있던 동안 들어와 있던 zip (수정시각 과거) — 하위 폴더 포함
cp "$WORK/stage/mac.zip" "$W/old.zip";      touch -t 202001010000 "$W/old.zip"
cp "$WORK/stage/mac.zip" "$W/하위/old2.zip"; touch -t 202001010000 "$W/하위/old2.zip"
# 받은 파일 흉내: 격리 표시가 붙은 rar
: > "$WORK/stage/받은.rar"; xattr -w com.apple.quarantine "0083;00000000;Safari;" "$WORK/stage/받은.rar"

echo "▶ 감시 시작 (20초 시나리오)"
"$BIN" "$W" 19 > "$WORK/out.txt" &
HPID=$!
sleep 2
# t=2: 감시 중에 들어오는 파일들
cp "$WORK/stage/mac.zip" "$W/$NEW_NFD"                 # NFD 이름의 맥 zip
cp "$WORK/stage/dup.zip" "$W/dup.zip"                  # 고칠 수 없는 zip(이름 충돌)
cp "$WORK/stage/win.zip" "$W/win.zip"                  # 윈도에서 만든 zip
echo seven > "$W/만든.7z"                              # 이 맥에서 만든 7z
mv "$WORK/stage/받은.rar" "$W/받은.rar"                # 받은 rar (격리 표시)
head -c "$HALF" "$WORK/stage/mac.zip" > "$W/slow.zip"  # 쓰는 중인 zip (앞 절반만)
head -c "$HALF" "$WORK/stage/mac.zip" > "$W/trunc.zip" # 끝내 완성되지 않는 zip
sleep 3
# t=5: 느린 쓰기가 끝남
tail -c +"$((HALF + 1))" "$WORK/stage/mac.zip" >> "$W/slow.zip"
sleep 5
# t=10: 문제였던 zip 을 정상 zip 으로 교체, 7z 는 한 번 더 수정(알림이 반복되면 안 됨)
cp "$WORK/stage/mac.zip" "$W/dup.zip"
echo more >> "$W/만든.7z"
sleep 4
# t=14: 불완전한 zip 삭제
rm "$W/trunc.zip"
wait "$HPID"
sed 's/^/   /' "$WORK/out.txt"

inner_ok() {   # zip 내부가 고쳐졌는지: 이름 NFC + 플래그 + __MACOSX 없음
    python3 - "$1" <<'PY'
import sys, zipfile, unicodedata
L = zipfile.ZipFile(sys.argv[1]).infolist()
ok = L and all(i.filename == unicodedata.normalize("NFC", i.filename) and not i.filename.startswith("__MACOSX")
               and (i.filename.isascii() or i.flag_bits & 0x800) for i in L)
sys.exit(0 if ok else 1)
PY
}

echo "▶ 검증"
[[ "$(count 'EVENT fixed old.zip')" == 1 ]] && inner_ok "$W/old.zip" && pass "기존 zip: 시작 스캔에서 수정" || failmsg "기존 zip"
[[ "$(count 'EVENT fixed old2.zip')" == 1 ]] && inner_ok "$W/하위/old2.zip" && pass "하위 폴더의 zip 도 수정" || failmsg "하위 폴더 zip"
[[ "$(count 'EVENT fixed 새압축.zip')" == 1 ]] && inner_ok "$W/새압축.zip" && pass "새로 들어온 NFD zip: 파일명 + 내부 모두 수정" || failmsg "새 zip"
[[ "$(./check.sh "$W" | tail -1)" == *"0개"* ]] && pass "감시 폴더에 NFD 이름 없음" || failmsg "NFD 잔존"
[[ "$(count 'EVENT fixed slow.zip')" == 1 ]] && [[ "$(count 'EVENT failed slow.zip')" == 0 ]] && inner_ok "$W/slow.zip" && unzip -tq "$W/slow.zip" >/dev/null \
    && pass "쓰는 중이던 zip: 실패 보고 없이 완료 후 수정" || failmsg "느린 쓰기 zip"
[[ "$(count 'EVENT failed trunc.zip')" == 1 ]] && pass "끝내 불완전한 zip: 유예 후 실패로 알림(1회)" || failmsg "불완전 zip 실패 알림"
[[ "$(count 'EVENT gone trunc.zip')" == 1 ]] && pass "문제 파일 삭제 시 기록 해소" || failmsg "삭제 해소"
[[ "$(count 'EVENT failed dup.zip')" == 1 ]] && pass "고칠 수 없는 zip: 실패로 알림(1회)" || failmsg "충돌 zip 실패 알림"
[[ "$(count 'EVENT fixed dup.zip')" == 1 ]] && inner_ok "$W/dup.zip" && pass "문제 zip 을 교체하면 다시 처리되어 해소" || failmsg "교체 후 재처리"
[[ "$(count 'win.zip')" == 0 ]] && cmp -s "$W/win.zip" "$WORK/stage/win.zip" && pass "윈도 zip: 알림 없음·원본 그대로" || failmsg "윈도 zip"
[[ "$(count 'EVENT unsupported 만든.7z')" == 1 ]] && pass "이 맥에서 만든 7z: 한 번만 알림" || failmsg "7z 알림 횟수 $(count 'EVENT unsupported 만든.7z')"
[[ "$(count '받은.rar')" == 0 ]] && pass "받은 rar(격리 표시): 알림 없음" || failmsg "받은 rar"
[[ "$(count 'EVENT fixed')" == 5 ]] && pass "수정 이벤트 총 5건(중복 처리 없음)" || failmsg "수정 이벤트 수 $(count 'EVENT fixed')"
grep -qx "PROBLEMS 만든.7z" "$WORK/out.txt" && pass "끝에 남은 문제는 7z 하나뿐" || failmsg "남은 문제 목록"
grep -qx "DISPLAY_FIRST 만든.7z" "$WORK/out.txt" && pass "표시 순서: 문제가 맨 위" || failmsg "표시 순서"
[[ -z "$(find "$W" -name '.*nfctmp*')" ]] && pass "임시 파일 미잔존" || failmsg "임시 파일 잔존"

if [ "$fail" -eq 0 ]; then echo; echo "✅ 자동 수정 테스트 전체 통과"; else echo; echo "❌ 자동 수정 테스트 실패 ${fail}건"; exit 1; fi
