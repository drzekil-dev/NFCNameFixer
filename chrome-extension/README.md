# 한글 파일명 NFC 픽서 — Chrome 확장

macOS의 Chrome은 파일 업로드 시 한글 파일명을 **NFD(자모 분리)로 되돌립니다**
([Chromium 버그 125271](https://bugs.chromium.org/p/chromium/issues/detail?id=125271), 2012년부터 미해결).
디스크에서 NFC로 고쳐놔도 Gmail 웹 등에 첨부하면 다시 깨지는 이유입니다.

이 확장은 업로드 경로를 가로채 **전송 직전에 파일명을 NFC로 정규화**합니다.

## 동작 방식

페이지 컨텍스트(MAIN world)에서 세 지점을 패치합니다:

1. `File.prototype.name` getter — 사이트 JS가 읽는 이름
2. `FormData.append/set` — multipart 업로드에 실리는 실제 파일명
3. `<input type=file>` change — 폼 제출 등 나머지 경로의 원천 교정

- 파일 **내용은 건드리지 않고 이름만** 정규화합니다.
- 모든 처리는 브라우저 안에서만 일어나며, **외부 전송·수집 없음**.
- 이미 정상(NFC·ASCII)인 이름은 변경하지 않습니다.

## 설치 (개발자 모드)

1. Chrome 주소창에 `chrome://extensions` 입력
2. 우측 상단 **개발자 모드** 켜기
3. **"압축해제된 확장 프로그램을 로드합니다"** 클릭 → 이 `chrome-extension` 폴더 선택
4. 끝. 이후 Gmail 등에서 한글 파일을 첨부하면 NFC로 올라갑니다.

## 확인 방법

저장소의 `tools/chrome-nfc-test.html`을 Chrome으로 열고 NFC 한글 파일을 드래그하세요.
확장이 켜져 있으면 **✅ NFC 유지됨**으로 나옵니다.
