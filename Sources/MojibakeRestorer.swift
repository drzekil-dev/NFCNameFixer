import Foundation

/// 윈도에서 받은 파일의 한글 이름이 맥에서 깨져 보이는(모지바케) 경우를 복원한다.
///
/// 원리: 깨진 문자열은 "원래 바이트를 잘못된 charset으로 해석한" 결과다.
/// 그래서 깨진 문자열을 그 잘못된 charset으로 다시 인코딩해 원래 바이트를 복구하고,
/// 올바른 charset(주로 CP949/EUC-KR 또는 UTF-8)으로 재디코딩한다.
/// 여러 후보를 만들어 점수가 가장 높은(=한글이 잘 살아난) 것을 고르되,
/// 원본보다 분명히 나아질 때만 교체한다(멀쩡한 이름은 건드리지 않음).
enum MojibakeRestorer {

    /// CP949(Windows-949, 통합 완성형 = EUC-KR 상위호환)
    static let cp949 = String.Encoding(rawValue:
        CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
    /// EUC-KR
    static let eucKR = String.Encoding(rawValue:
        CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))

    /// 깨진 이름을 복원한다. 복원이 원본보다 나아지지 않으면 원본을 그대로 돌려준다.
    static func restore(_ s: String) -> String {
        var candidates: [String] = [s]

        // Latin-1로 잘못 해석된 바이트 되돌리기 → 올바른 charset 재디코딩
        if let bytes = s.data(using: .isoLatin1) {
            if let v = String(data: bytes, encoding: cp949) { candidates.append(v) }
            if let v = String(data: bytes, encoding: eucKR) { candidates.append(v) }
            if let v = String(data: bytes, encoding: .utf8)  { candidates.append(v) }
        }
        // MacRoman 경유 케이스
        if let bytes = s.data(using: .macOSRoman) {
            if let v = String(data: bytes, encoding: cp949) { candidates.append(v) }
            if let v = String(data: bytes, encoding: .utf8)  { candidates.append(v) }
        }

        let originalScore = score(s)
        var best = s
        var bestScore = originalScore
        for c in candidates where c != s {
            let sc = score(c)
            if sc > bestScore {
                best = c
                bestScore = sc
            }
        }
        // 원본보다 "분명히" 나을 때만 교체.
        return bestScore > originalScore ? best : s
    }

    /// 변환 후보의 "그럴듯함" 점수. 높을수록 좋다.
    /// 한글 음절 비율이 높을수록 가점, 깨짐 신호(U+FFFD·제어문자·사용영역 등)는 감점.
    static func score(_ s: String) -> Double {
        let scalars = Array(s.unicodeScalars)
        if scalars.isEmpty { return 0 }

        var hangul = 0
        var penalty = 0.0
        for u in scalars {
            let v = u.value
            switch v {
            case 0xAC00...0xD7A3:        // 한글 음절 (가–힣)
                hangul += 1
            case 0x1100...0x11FF,        // 한글 자모(분리형)
                 0x3130...0x318F:        // 호환 자모(ㄱ, ㅏ …)
                penalty += 0.3           // 자모 단독은 약한 깨짐 신호
            case 0xFFFD:                 // replacement char — 강한 깨짐
                penalty += 3
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F: // C0 제어문자
                penalty += 2
            case 0x80...0x9F:            // C1 제어문자(Latin-1 오해석의 전형)
                penalty += 1.5
            case 0xE000...0xF8FF:        // 사용자 영역(PUA) — 깨짐 흔함
                penalty += 1
            default:
                break
            }
        }
        let total = Double(scalars.count)
        // 한글 비율(0~1)에 가중치 + 절대 한글 수 소폭 가점 − 감점
        return (Double(hangul) / total) * 10.0 + Double(hangul) * 0.1 - penalty
    }
}
