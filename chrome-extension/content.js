// 한글 파일명 NFC 픽서 — NFCNameFixer의 Chrome 확장.
//
// 문제: macOS의 Chrome은 파일 업로드 시 파일명을 NFD(자모 분리)로 만들어
//       윈도 사용자에게 'ㅎㅏㄴㄱㅡㄹ.hwp'처럼 깨져 보이게 한다. (Chromium 버그 125271, 2012~)
// 해결: 페이지(MAIN world)에서 업로드 경로 세 곳을 가로채 이름을 NFC로 정규화한다.
//       1) File.prototype.name getter — 사이트 JS가 읽는 이름
//       2) FormData append/set     — multipart 업로드에 실리는 실제 파일명
//       3) <input type=file> 변경  — 폼 제출 등 나머지 경로의 원천 교정
// 모든 처리는 브라우저 안에서만 일어나고 외부 전송은 없다.
(() => {
    'use strict';

    const needsFix = (s) => typeof s === 'string' && s !== s.normalize('NFC');

    // File의 "진짜"(패치 전) 이름을 읽는 함수. getter 패치 후에도 내부 NFD 이름을 봐야
    // FormData 경로에서 "고칠 필요 없음"으로 오판하지 않는다.
    let rawName = (file) => file.name;

    // 정규화된 복제 File 생성 (내용·타입·수정시각 보존)
    const normalizedFile = (file) => {
        try {
            return new File([file], rawName(file).normalize('NFC'),
                            { type: file.type, lastModified: file.lastModified });
        } catch {
            return file; // 만들 수 없으면 원본 유지
        }
    };

    // --- 1) File.name getter: 사이트가 읽는 이름을 NFC로 ---
    try {
        const desc = Object.getOwnPropertyDescriptor(File.prototype, 'name');
        if (desc && desc.get) {
            const origGet = desc.get;
            rawName = (file) => { try { return origGet.call(file); } catch { return file.name; } };
            Object.defineProperty(File.prototype, 'name', {
                configurable: true,
                enumerable: desc.enumerable,
                get() { return origGet.call(this).normalize('NFC'); }
            });
        }
    } catch { /* 실패해도 아래 경로가 커버 */ }

    // --- 2) FormData: 업로드에 실리는 실제 파일명 교정 ---
    const patchFormData = (method) => {
        const orig = FormData.prototype[method];
        if (!orig) return;
        FormData.prototype[method] = function (key, value, filename) {
            if (value instanceof File) {
                if (filename === undefined) {
                    // 주의: value.name은 위에서 패치된 getter라 항상 NFC로 보인다.
                    // 실제 업로드(multipart)에는 내부 이름이 실리므로 raw 이름으로 판단해야 한다.
                    if (needsFix(rawName(value))) value = normalizedFile(value);
                } else if (needsFix(filename)) {
                    filename = filename.normalize('NFC');
                }
            }
            return filename === undefined
                ? orig.call(this, key, value)
                : orig.call(this, key, value, filename);
        };
    };
    patchFormData('append');
    patchFormData('set');

    // --- 3) <input type=file>: 선택 직후 FileList 자체를 교체 ---
    document.addEventListener('change', (e) => {
        const input = e.target;
        if (!input || input.type !== 'file' || !input.files || input.files.length === 0) return;
        const files = Array.from(input.files);
        if (!files.some(f => needsFix(rawName(f)))) return;   // raw 이름으로 판단(패치된 getter 금지)
        try {
            const dt = new DataTransfer();
            for (const f of files) dt.items.add(needsFix(rawName(f)) ? normalizedFile(f) : f);
            input.files = dt.files;
        } catch { /* DataTransfer 미지원 등 — 1)·2) 경로가 커버 */ }
    }, true); // capture: 사이트 핸들러보다 먼저
})();
