#!/bin/bash
# ZipNameFixer 통합 테스트.
# Finder 압축(ditto)과 Info-ZIP 비밀번호 zip을 NFD 이름 파일로 만든 뒤 엔진을 돌리고,
# python3 zipfile / unzip 으로 독립 검증한다.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d /tmp/nfczip.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/zipfix"

echo "▶ zip 엔진 + 하니스 컴파일"
swiftc -O -o "$BIN" Sources/ZipNameFixer.swift tests/zip/main.swift

fail=0
pass() { echo "PASS: $1"; }
failmsg() { echo "FAIL: $1"; fail=$((fail+1)); }

# --- 픽스처: NFD 이름의 트리 ---
python3 - "$WORK" <<'PY'
import os, sys, unicodedata
root = sys.argv[1]
N = lambda s: unicodedata.normalize("NFD", s)
d = os.path.join(root, "src", N("한글폴더"))
os.makedirs(os.path.join(d, N("하위")))
open(os.path.join(d, N("보고서.txt")), "w").write("report-body")
open(os.path.join(d, N("하위"), N("문서.txt")), "w").write("doc-body")
open(os.path.join(d, "ascii.txt"), "w").write("ascii-body")
os.makedirs(os.path.join(root, "plain"))
open(os.path.join(root, "plain", "a.txt"), "w").write("a")
PY
SRCDIR="$WORK/src/$(ls "$WORK/src")"

(cd "$WORK/src" && ditto -c -k --sequesterRsrc --keepParent "$(ls)" "$WORK/finder.zip")
(cd "$SRCDIR" && zip -q -r -P pw1234 "$WORK/enc.zip" .)
(cd "$WORK/plain" && zip -q -r "$WORK/ascii.zip" .)
cp "$WORK/ascii.zip" "$WORK/ascii.orig.zip"

# 검증 헬퍼: 모든 이름 NFC + 비ASCII 항목 플래그 on + __MACOSX 없음 → "OK" 출력
verify() {
    python3 - "$1" <<'PY'
import sys, zipfile, unicodedata
z = zipfile.ZipFile(sys.argv[1])
problems = []
for i in z.infolist():
    utf8 = bool(i.flag_bits & 0x800)
    raw = i.filename if utf8 else i.filename.encode("cp437").decode("utf-8", "replace")
    if raw.startswith("__MACOSX"): problems.append("macosx:" + raw)
    if raw != unicodedata.normalize("NFC", raw): problems.append("nfd:" + raw)
    if not raw.isascii() and not utf8: problems.append("noflag:" + raw)
print("OK" if not problems else "BAD " + " ".join(problems))
PY
}

echo "▶ 1. Finder zip"
out="$("$BIN" "$WORK/finder.zip")"; echo "   $out"
[[ "$out" == changed=true* ]] && [[ "$out" == *removed=[1-9]* ]] && pass "Finder zip 변경됨(__MACOSX 제거)" || failmsg "Finder zip 통계: $out"
[[ "$(verify "$WORK/finder.zip")" == OK ]] && pass "Finder zip 이름 NFC·플래그·__MACOSX" || failmsg "Finder zip 검증: $(verify "$WORK/finder.zip")"
unzip -tq "$WORK/finder.zip" >/dev/null && pass "Finder zip unzip -t" || failmsg "Finder zip CRC"
n="$(python3 -c "import zipfile,sys;print(len(zipfile.ZipFile(sys.argv[1]).infolist()))" "$WORK/finder.zip")"
[[ "$n" == 5 ]] && pass "Finder zip 항목 수 5(폴더2+파일3)" || failmsg "Finder zip 항목 수 $n"

echo "▶ 2. 비밀번호 zip"
out="$("$BIN" "$WORK/enc.zip")"; echo "   $out"
[[ "$out" == changed=true* ]] && pass "enc zip 변경됨" || failmsg "enc zip 통계: $out"
[[ "$(verify "$WORK/enc.zip")" == OK ]] && pass "enc zip 이름 NFC·플래그" || failmsg "enc zip 검증: $(verify "$WORK/enc.zip")"
body="$(unzip -P pw1234 -p "$WORK/enc.zip" "하위/문서.txt" 2>/dev/null || true)"
[[ "$body" == "doc-body" ]] && pass "enc zip 비밀번호로 내용 복원" || failmsg "enc zip 내용: '$body'"
unzip -P pw1234 -tq "$WORK/enc.zip" >/dev/null && pass "enc zip unzip -t" || failmsg "enc zip CRC"

echo "▶ 3. 멱등성"
cp "$WORK/finder.zip" "$WORK/finder.2.zip"
out="$("$BIN" "$WORK/finder.2.zip")"; echo "   $out"
[[ "$out" == changed=false* ]] && cmp -s "$WORK/finder.zip" "$WORK/finder.2.zip" && pass "재처리 시 변경 없음·바이트 동일" || failmsg "멱등성: $out"

echo "▶ 4. ASCII 전용 zip"
out="$("$BIN" "$WORK/ascii.zip")"; echo "   $out"
[[ "$out" == changed=false* ]] && cmp -s "$WORK/ascii.zip" "$WORK/ascii.orig.zip" && pass "ASCII zip 변경 없음" || failmsg "ASCII zip: $out"

echo "▶ 5. 손상/비zip 입력"
echo "not a zip" > "$WORK/bogus.zip"
if "$BIN" "$WORK/bogus.zip" >/dev/null 2>&1; then failmsg "비zip이 성공으로 처리됨"; else pass "비zip 거부"; fi

# --- 경계 사례: 손으로 만든 zip (python3 표준 라이브러리만 사용) ---
python3 - "$WORK" <<'PY'
import os, sys, struct, zlib, unicodedata
root = sys.argv[1]
NFD = lambda s: unicodedata.normalize("NFD", s).encode()
NFC = lambda s: unicodedata.normalize("NFC", s).encode()
ef = lambda fid, data: struct.pack("<HH", fid, len(data)) + data
def make(name, entries, archive_comment=b""):
    """entries: dict(name, flags=0, data, extra=b'', comment=b'', z64off=False)"""
    out = bytearray(); cd = bytearray()
    for e in entries:
        n, fl, data = e["name"], e.get("flags", 0), e["data"]
        lextra = e.get("extra", b""); cmt = e.get("comment", b"")
        crc = zlib.crc32(data); off = len(out)
        out += struct.pack("<IHHHHHIIIHH", 0x04034b50, 45, fl, 0, 0, 0x21, crc, len(data), len(data), len(n), len(lextra)) + n + lextra + data
        cextra = lextra + (ef(0x0001, struct.pack("<Q", off)) if e.get("z64off") else b"")
        off32 = 0xFFFFFFFF if e.get("z64off") else off
        cd += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014b50, 0x032d, 45, fl, 0, 0, 0x21, crc, len(data), len(data),
                          len(n), len(cextra), len(cmt), 0, 0, 0o100644 << 16, off32) + n + cextra + cmt
    cdoff = len(out); out += cd
    out += struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, len(entries), len(entries), len(cd), cdoff, len(archive_comment)) + archive_comment
    open(os.path.join(root, name), "wb").write(out)

n = NFD("보고서.txt")
upath = ef(0x7075, b"\x01" + struct.pack("<I", zlib.crc32(n)) + n)
make("upath.zip", [dict(name=n, data=b"body-a", extra=upath, comment=b"entry-comment")], b"archive-comment")
make("already.zip", [dict(name=NFC("보고서.txt"), flags=0x800, data=b"body-b")])
make("cp949.zip", [dict(name="보고서.txt".encode("cp949"), data=b"body-c")])
make("nfdflag.zip", [dict(name=NFD("보고서.txt"), flags=0x800, data=b"body-d")])
make("z64off.zip", [dict(name=b"__MACOSX/._x", data=b"junkjunkjunk"),
                    dict(name=NFD("문서.txt"), data=b"body-f", z64off=True),
                    dict(name=b"tail.txt", data=b"tail", z64off=True)])
make("dup.zip", [dict(name=NFD("같음.txt"), data=b"one"), dict(name=NFC("같음.txt"), flags=0x800, data=b"two")])
PY
for f in already cp949 dup; do cp "$WORK/$f.zip" "$WORK/$f.orig.zip"; done

# 한 줄 python 검증: 표현식이 참이면 OK
pycheck() {  # $1=zip, $2=python 표현식 (z=ZipFile, L=infolist, NFC=정규화 함수)
    python3 - "$1" "$2" <<'PY'
import sys, zipfile, struct, unicodedata
z = zipfile.ZipFile(sys.argv[1]); L = z.infolist()
NFC = lambda s: unicodedata.normalize("NFC", s)
def ids(b):
    r, p = [], 0
    while p + 4 <= len(b):
        i, l = struct.unpack("<HH", b[p:p+4]); r.append(i); p += 4 + l
    return r
print("OK" if eval(sys.argv[2]) else "BAD")
PY
}

echo "▶ 6. Unicode Path 추가 필드(0x7075) 제거, 코멘트 보존"
"$BIN" "$WORK/upath.zip" >/dev/null
[[ "$(pycheck "$WORK/upath.zip" 'L[0].filename==NFC(L[0].filename) and L[0].flag_bits&0x800 and 0x7075 not in ids(L[0].extra) and L[0].comment==b"entry-comment" and z.comment==b"archive-comment" and z.read(L[0])==b"body-a"')" == OK ]] \
    && pass "0x7075 제거·코멘트·내용 보존" || failmsg "Unicode Path 처리"

echo "▶ 7. 이미 정상인 zip(NFC + UTF-8 플래그)은 무변경"
out="$("$BIN" "$WORK/already.zip")"
[[ "$out" == changed=false* ]] && cmp -s "$WORK/already.zip" "$WORK/already.orig.zip" && pass "정상 zip 바이트 동일" || failmsg "정상 zip: $out"

echo "▶ 8. CP949 이름(윈도에서 만든 zip)은 오류가 아니라 '수정 불필요', 원본 보존"
out="$("$BIN" "$WORK/cp949.zip")"
[[ "$out" == changed=false*foreign=true ]] && cmp -s "$WORK/cp949.zip" "$WORK/cp949.orig.zip" && pass "CP949 zip 무변경(foreign)" || failmsg "CP949: $out"

echo "▶ 9. NFD인데 UTF-8 플래그는 이미 켜진 항목"
out="$("$BIN" "$WORK/nfdflag.zip")"
[[ "$out" == *renamed=1*flagged=0* ]] && [[ "$(pycheck "$WORK/nfdflag.zip" 'L[0].filename==NFC(L[0].filename) and z.read(L[0])==b"body-d"')" == OK ]] \
    && pass "이름만 NFC로" || failmsg "nfdflag: $out"

echo "▶ 10. 로컬 오프셋이 zip64 extra 안에 있을 때 오프셋 갱신"
"$BIN" "$WORK/z64off.zip" >/dev/null
[[ "$(pycheck "$WORK/z64off.zip" '[(i.filename, z.read(i)) for i in L]==[(NFC("문서.txt"), b"body-f"), ("tail.txt", b"tail")] and L[0].header_offset==0')" == OK ]] \
    && pass "zip64 오프셋 갱신 후 두 항목 모두 읽힘" || failmsg "zip64 오프셋"

echo "▶ 11. NFC로 바꾸면 이름이 겹치는 zip은 거부(덮어쓰기 방지)"
if "$BIN" "$WORK/dup.zip" >/dev/null 2>&1; then failmsg "이름 충돌 zip이 처리됨"; else
    cmp -s "$WORK/dup.zip" "$WORK/dup.orig.zip" && pass "충돌 거부·원본 그대로" || failmsg "충돌 zip 원본 변경됨"; fi

echo "▶ 12. zip64 + 암호화 (8바이트 데이터 디스크립터)"
(cd "$SRCDIR" && zip -q -r -fz -P pw1234 "$WORK/z64enc.zip" .)
"$BIN" "$WORK/z64enc.zip" >/dev/null
python3 - "$WORK/z64enc.zip" <<'PY' && pass "디스크립터가 다음 헤더 직전에 정확히 위치" || failmsg "zip64 디스크립터"
import sys, zipfile, struct
raw = open(sys.argv[1], "rb").read(); z = zipfile.ZipFile(sys.argv[1])
infos = sorted(z.infolist(), key=lambda i: i.header_offset)
ends = [i.header_offset for i in infos[1:]] + [z.start_dir]
seen = 0
for i, end in zip(infos, ends):
    if not i.flag_bits & 8: continue
    seen += 1
    d32 = struct.pack("<III", i.CRC, i.compress_size, i.file_size)
    d64 = struct.pack("<IQQ", i.CRC, i.compress_size, i.file_size)
    if raw[end-12:end] != d32 and raw[end-20:end] != d64: sys.exit(1)
sys.exit(0 if seen else 1)
PY
unzip -P pw1234 -tq "$WORK/z64enc.zip" >/dev/null && pass "zip64 암호화 zip unzip -t" || failmsg "zip64 암호화 CRC"

echo "▶ 13. 쓰기 불가 폴더: 오류 + 원본 보존 / 권한 보존 / 임시 파일 미잔존"
mkdir "$WORK/ro"
(cd "$WORK/src" && ditto -c -k --sequesterRsrc --keepParent "$(ls)" "$WORK/ro/a.zip")
cp "$WORK/ro/a.zip" "$WORK/ro.orig.zip"; chmod 555 "$WORK/ro"
if "$BIN" "$WORK/ro/a.zip" >/dev/null 2>&1; then failmsg "읽기전용 폴더에서 성공으로 처리됨"; else
    cmp -s "$WORK/ro/a.zip" "$WORK/ro.orig.zip" && pass "읽기전용 폴더: 원본 그대로" || failmsg "읽기전용 폴더: 원본 변경됨"; fi
chmod 755 "$WORK/ro"; chmod 600 "$WORK/ro/a.zip"
"$BIN" "$WORK/ro/a.zip" >/dev/null
[[ "$(stat -f %Lp "$WORK/ro/a.zip")" == 600 ]] && [[ "$(ls -A "$WORK/ro")" == "a.zip" ]] && pass "권한 600 유지·임시 파일 없음" || failmsg "권한/임시파일: $(stat -f %Lp "$WORK/ro/a.zip") / $(ls -A "$WORK/ro")"

if [ "$fail" -eq 0 ]; then echo; echo "✅ zip 테스트 전체 통과"; else echo; echo "❌ zip 테스트 실패 ${fail}건"; exit 1; fi
