import Foundation

// MojibakeRestorer 단위 테스트 (swiftc 하니스 — XCTest/SwiftPM 불필요).
// 실패가 있으면 비정상 종료(exit 1)한다.

var failures = 0
func check(_ name: String, _ got: String, _ want: String) {
    if got == want {
        print("PASS: \(name)")
    } else {
        print("FAIL: \(name)\n     got = \(got)\n     want= \(want)")
        failures += 1
    }
}

/// 올바른 이름을 charset으로 인코딩한 뒤 Latin-1로 잘못 해석 = 전형적 깨짐 생성.
func mojibake(_ s: String, via enc: String.Encoding) -> String? {
    guard let data = s.data(using: enc) else { return nil }
    return String(data: data, encoding: .isoLatin1)
}

let cases = ["한글파일.pdf", "회의자료_최종.xlsx", "보고서 2026년.docx"]

for original in cases {
    // CP949 → Latin-1 깨짐 복원
    if let m = mojibake(original, via: MojibakeRestorer.cp949) {
        print("  입력(CP949→Latin1): \(m)")
        check("CP949→Latin1 복원: \(original)", MojibakeRestorer.restore(m), original)
    } else {
        print("FAIL: CP949 인코딩 불가: \(original)"); failures += 1
    }
    // UTF-8 → Latin-1 깨짐 복원
    if let m = mojibake(original, via: .utf8) {
        print("  입력(UTF8→Latin1): \(m)")
        check("UTF8→Latin1 복원: \(original)", MojibakeRestorer.restore(m), original)
    } else {
        print("FAIL: UTF8 인코딩 불가: \(original)"); failures += 1
    }
}

// 멀쩡한 이름은 절대 건드리지 않는다(회귀 방지).
check("멀쩡한 한글 불변", MojibakeRestorer.restore("한글파일.pdf"), "한글파일.pdf")
check("ASCII 불변", MojibakeRestorer.restore("report_2026.pdf"), "report_2026.pdf")
check("숫자/기호 불변", MojibakeRestorer.restore("2026-1,2부.zip"), "2026-1,2부.zip")

if failures == 0 {
    print("\n✅ 전체 통과")
} else {
    print("\n❌ 실패 \(failures)건")
    exit(1)
}
