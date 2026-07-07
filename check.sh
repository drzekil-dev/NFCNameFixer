#!/bin/bash
# 폴더 안 파일·폴더 이름이 NFC인지 검사한다 (변환 결과 확인용).
# macOS의 ls/Finder는 화면 표시 시 정규화하므로, 디스크의 실제 바이트로 판정한다.
# 사용: ./check.sh /검사할/폴더
if [ -z "${1:-}" ]; then
    echo "사용법: ./check.sh /검사할/폴더경로"
    exit 1
fi
/usr/bin/python3 - "$1" <<'PY'
import os, sys, unicodedata
root = sys.argv[1]
bad = 0
for r, d, f in os.walk(root):
    for n in d + f:
        if n != unicodedata.normalize("NFC", n):
            bad += 1
            print("NFD!", os.path.join(r, n))
print(f"\n검사 완료 — 남은 NFD 이름: {bad}개  ({'✅ 전부 NFC' if bad == 0 else '❌ 변환 필요'})")
PY
