#!/bin/bash
# 단위/통합 테스트 실행 (외부 의존성 없음).
set -euo pipefail
cd "$(dirname "$0")/.."
echo "▶ 복원 로직 테스트 컴파일"
swiftc -O -o /tmp/nfc_tests Sources/MojibakeRestorer.swift tests/main.swift
echo "▶ 복원 로직 테스트 실행"
/tmp/nfc_tests
echo
echo "▶ zip 내부 이름 수정 테스트"
./tests/zip_test.sh

echo
echo "▶ 드롭 처리 테스트"
./tests/drop_test.sh

echo
echo "▶ 감시 폴더 zip 자동 수정 테스트 (약 20초)"
./tests/auto_test.sh
