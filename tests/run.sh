#!/bin/bash
# MojibakeRestorer 단위 테스트 실행 (외부 의존성 없음).
set -euo pipefail
cd "$(dirname "$0")/.."
echo "▶ 테스트 컴파일"
swiftc -O -o /tmp/nfc_tests Sources/MojibakeRestorer.swift tests/main.swift
echo "▶ 테스트 실행"
/tmp/nfc_tests
