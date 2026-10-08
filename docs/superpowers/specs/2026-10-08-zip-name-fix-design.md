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

---

# 추가 설계 — 감시 폴더의 zip 자동 수정 (2026-10-08, 승인됨)

원칙: **감시 폴더에 들어온 zip 은 전부 처리한다. 조용하면 다 된 것이고, 안 된 것은 앱이 먼저 알린다.**
(앞 절의 "자동 감시 폴더의 zip 은 건드리지 않는다"를 대체한다. 스위치는 두지 않는다.)

## 처리 규칙 (`Sources/ArchiveAutoFixer.swift`)

- 대상: 감시 폴더와 하위의 `.zip`. 이벤트 경로가 폴더면 하위까지 훑는다. 시작 스캔·"지금 스캔"에도 포함.
- 이름 변환(NFCConverter) 뒤에 같은 직렬 큐에서 실행한다.
- **쓰기 완료 대기**: (크기, 수정시각, inode)가 `settleInterval`(1.5초) 동안 그대로일 때 처리. 수정시각이 10초 이상 지난 파일은 바로 처리.
- **재시도**: 구조가 불완전(EOCD 없음 등)한데 파일이 아직 "젊으면"(`giveUpAfter` 60초 이내 수정) 실패로 보지 않고 계속 대기한다.
- **중복 방지**: 처리한 파일의 서명을 기억해 같은 상태는 다시 열지 않는다. 우리가 다시 쓴 뒤의 서명도 기억한다.
- 이미 정상인 zip, UTF-8 이 아닌 이름의 zip(Windows 에서 만든 것)은 **문제 없음**으로 본다(알리지 않음).
- 실패(이름 충돌·분할·손상·권한·zip 아님)는 이벤트로 알린다. 파일이 바뀌거나 사라지면 실패 기록을 지운다.
- `7z/rar/alz/egg`: 내부 이름을 고칠 수 없다고 한 번 알린다. 단 감시 중 새로 들어온 것이고 격리 표시(com.apple.quarantine)가
  없는 것(= 이 맥에서 만든 것)만. 받은 파일이나 기존 파일로 경고가 쏟아지는 것을 막기 위함이다.

## 알림 (`ProcessLog`, `WatchStore`, `AppDelegate`)

- `ProcessLog`: 최근 처리 기록(수정됨/실패/미지원), 경로당 1건, 최대 50건. 패널에 문제 우선으로 표시.
- 메뉴바 아이콘: 미확인 문제가 있으면 경고 모양. 창을 열면 원래대로.
- macOS 알림: 새 문제 발생 시(권한은 첫 문제 때 요청). 권한이 없어도 아이콘이 주 신호.

## 테스트 (`tests/auto_test.sh`)

실제 FSEvents 로 임시 폴더를 감시하며: 기존 zip(시작 스캔), 새로 들어온 NFD zip, 두 번에 나눠 쓰는 zip(실패 보고 없이 최종 수정),
끝내 불완전한 zip(유예 후 실패), 이름 충돌 zip(실패 → 교체하면 해소), Windows zip(무보고), 7z(1회 알림)·격리 표시된 rar(무보고), 삭제 시 기록 해소.
