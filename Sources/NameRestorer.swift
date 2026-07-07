import Foundation

/// 복원 작업 통계.
struct RestoreStats {
    var restored = 0
    var scanned = 0
    var skipped: [String] = []
    var errors: [String] = []
    var samples: [String] = []
}

/// 깨진(모지바케) 한글 이름을 가진 파일/폴더를 올바른 이름으로 rename 한다.
/// `MojibakeRestorer`로 이름을 판정·복원하며, 멀쩡한 이름은 건드리지 않는다.
///
/// 모지바케 이름은 유효 UTF-8(잘못된 문자들로 구성)이라 `FileManager` 기반 walk로 충분하다.
/// (NFD/NFC 정규화 함정이 없는 영역이므로 POSIX raw 바이트가 필요 없다.)
final class NameRestorer {
    private let fm = FileManager.default
    private(set) var stats = RestoreStats()
    private let maxSamples = 300

    @discardableResult
    func run(rootPaths: [String]) -> RestoreStats {
        stats = RestoreStats()
        for p in rootPaths {
            processEntry(URL(fileURLWithPath: p))
        }
        return stats
    }

    private func processEntry(_ url: URL) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            stats.errors.append("없음: \(url.path)")
            return
        }
        stats.scanned += 1
        if isDir.boolValue {
            // 하위 먼저 처리(부모 이름이 아직 안 바뀐 상태의 경로 사용 → 안전).
            let children = (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [])) ?? []
            for child in children { processEntry(child) }
        }
        maybeRename(url)
    }

    private func maybeRename(_ url: URL) {
        let name = url.lastPathComponent
        let restored = MojibakeRestorer.restore(name)
        if restored == name { return }   // 멀쩡한 이름 → 변경 없음

        let dest = url.deletingLastPathComponent().appendingPathComponent(restored)
        if fm.fileExists(atPath: dest.path) {
            stats.skipped.append("\(name) → 이미 존재: \(restored)")
            return
        }
        do {
            try fm.moveItem(at: url, to: dest)
            stats.restored += 1
            if stats.samples.count < maxSamples { stats.samples.append("\(name)  →  \(restored)") }
        } catch {
            stats.errors.append("\(name): \(error.localizedDescription)")
        }
    }
}
