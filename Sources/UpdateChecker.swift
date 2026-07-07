import Foundation

/// GitHub 릴리스를 조회해 새 버전이 있는지 확인한다.
/// (앱이 ad-hoc 서명이라 자동 설치 대신, 새 버전이면 다운로드 페이지를 연다.)
enum UpdateChecker {
    static let repo = "drzekil-dev/NFCNameFixer"
    static var releasesURL: URL { URL(string: "https://github.com/\(repo)/releases")! }

    /// 최신 릴리스 태그를 조회. completion(최신버전, 오류메시지) 중 하나만 채워짐.
    static func check(_ completion: @escaping (String?, String?) -> Void) {
        let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(nil, err.localizedDescription); return }
            if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
                completion(nil, "아직 게시된 릴리스가 없습니다."); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                completion(nil, "업데이트 정보를 해석할 수 없습니다."); return
            }
            completion(normalize(tag), nil)
        }.resume()
    }

    /// "v1.0" → "1.0"
    static func normalize(_ tag: String) -> String {
        (tag.hasPrefix("v") || tag.hasPrefix("V")) ? String(tag.dropFirst()) : tag
    }

    /// a가 b보다 높은 버전인지 (점 구분 숫자 비교).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
