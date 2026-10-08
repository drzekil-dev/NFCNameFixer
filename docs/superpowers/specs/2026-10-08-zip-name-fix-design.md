# zip 내부 파일명 NFC 수정 — 설계 (2026-10-08)

## 목적

맥에서 만든 zip(Finder "압축", Info-ZIP `zip`)은 내부 항목 이름이 NFD 바이트이고 UTF-8 플래그(bit 11)가
꺼져 있어, Windows에서 이름이 깨진다(CP949 해석 + 자모 분리). 사용자가 zip을 드롭존에 던지면
압축을 풀지 않고 zip 구조만 다시 써서 두 원인을 모두 고친다. 비밀번호 zip도 이름은 평문이므로
비밀번호 없이 처리한다.

## 확정된 결정

- 결과는 **원본을 제자리에서 교체**한다(임시 파일 → 자체 검증 → 원자 교체).
- Finder가 넣는 **`__MACOSX/` 항목은 제거**한다.
- **zip만** 지원한다. 7z/RAR/ALZ/EGG는 이름이 압축·암호화 블록 안에 있어 범위 밖.
- **드롭존에 직접 던진 zip만** 처리한다. 폴더 안의 zip은 뒤지지 않고, 자동 감시 폴더의 zip도 건드리지 않는다.

## 구성 요소

### `Sources/ZipNameFixer.swift` (신규, 순수 엔진)

```
enum ZipNameFixer {
    static func isZip(path: String) -> Bool          // 확장자 .zip + 시그니처 PK\x03\x04
    static func fix(path: String) throws -> ZipFixResult
}
struct ZipFixResult { renamed: Int; removed: Int; flagged: Int; changed: Bool }
```

파서: EOCD(+zip64 EOCD/locator) → 중앙 디렉터리 → 항목별 로컬 헤더.
작성기: 항목별 [새 로컬 헤더 + 원본 데이터 블록(+데이터 디스크립터)] → 새 중앙 디렉터리 → (필요 시 zip64 EOCD/locator) → EOCD.

항목별 규칙:
- 이름 바이트가 UTF-8이 아니면 파일 전체를 **미지원**으로 거부(Windows CP949 zip 등, 반대 방향 문제).
- `__MACOSX/`로 시작하는 항목은 버린다.
- 이름이 NFD면 NFC로 바꾼다(`precomposedStringWithCanonicalMapping`, `.literal` 비교).
- 이름에 비ASCII가 있으면 UTF-8 플래그(bit 11)를 켠다. ASCII 전용 항목은 플래그를 건드리지 않는다.
- Unicode Path 추가 필드(0x7075)는 제거한다. 나머지 추가 필드(zip64, Unix, AES 등)는 보존한다.
- 데이터 디스크립터(bit 3)는 그대로 복사한다. (ZipCrypto는 bit 3 여부에 따라 검증 바이트가 달라지므로 플래그를 바꾸면 안 된다.)
  디스크립터 길이: 시그니처 유무 + 로컬 헤더에 zip64 추가 필드가 있으면 8바이트 크기.
- 압축 데이터 길이는 중앙 디렉터리의 compressed size를 쓴다(로컬 헤더는 bit 3 시 0일 수 있음).
- zip64 추가 필드 안의 로컬 헤더 오프셋은 새 오프셋으로 갱신한다. 파일은 줄어들기만 하므로 새로 zip64가 필요해지는 경우는 없다.

바꿀 항목이 하나도 없으면(모두 NFC·플래그 정상·`__MACOSX` 없음) 파일을 쓰지 않고 `changed=false`로 끝낸다(멱등).

미지원으로 거부: 분할 아카이브(디스크 번호 ≠ 0), 로컬 헤더 시그니처 불일치, 오프셋이 파일 범위를 벗어남, 비UTF-8 이름.

### 안전장치

- 같은 폴더의 임시 파일에 전부 쓴 뒤 재파싱해 **항목 수, 각 항목의 CRC·압축/원본 크기·압축 방식·플래그·이름**이 기대값과 일치하는지 검증한다. 불일치면 임시 파일을 지우고 오류.
- 검증 통과 시 원본의 권한(mode)을 복사하고 `rename(2)`으로 교체한다.

### UI 연결 (`NFCNameFixerApp.swift`, `WatchStore.swift`, `FolderWatcher.swift`)

- 드롭 경로를 zip / 그 외로 나눈다. zip은 `ZipNameFixer.fix`, 나머지는 기존 `NFCConverter`.
- 둘 다 FolderWatcher의 직렬 큐에서 실행한다(`perform(work:completion:)`로 일반화).
- 요약 줄: 기존 "변환 N개 · 검사 M개" 뒤에 "zip K개: 이름 수정 a개 · 항목 제거 b개" 및 오류 수.

## 테스트 (`tests/zip_test.sh`, `tests/zip/main.swift`)

엔진 + CLI 하니스(`zipfix <file>`)를 swiftc로 빌드하고, 픽스처는 `ditto -c -k --sequesterRsrc`(Finder 압축과 동일)와
`zip -r -P <pw>`로 NFD 이름 파일에서 만든다. python3 `zipfile`과 `unzip`으로 독립 검증:

1. Finder zip: 처리 후 모든 이름 NFC, 비ASCII 항목 플래그 on, `__MACOSX` 없음, `unzip -t` 통과.
2. 비밀번호 zip: 처리 후 이름 NFC·플래그 on, 원래 비밀번호로 `unzip -P`한 내용이 원본과 동일.
3. 멱등성: 처리된 파일을 다시 처리하면 `changed=false`, 바이트 동일.
4. ASCII 전용 zip: 변경 없음, 바이트 동일.
5. 하위 폴더 포함 트리에서 폴더 항목(이름 끝 `/`)도 NFC.

## 문서

README "파일 보낼 때 주의"의 "반디집으로 압축하세요"를 "zip을 드롭존에 던지면 내부 이름까지 고쳐집니다"로,
MANUAL에 "zip 파일 고치기" 절 추가. Windows 10 이후 탐색기·반디집·7-Zip이 UTF-8 플래그를 인식한다고 명시.
