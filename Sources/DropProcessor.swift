import Foundation

/// 여러 zip 을 처리한 합산 통계.
struct ZipBatchStats {
    var files = 0            // 처리에 성공한 zip 수(변경 없음 포함)
    var changedFiles = 0     // 실제로 다시 쓴 zip 수
    var renamed = 0
    var removed = 0
    var flagged = 0
    var errors: [String] = []
}

/// 드롭 한 번의 처리 결과.
struct DropOutcome {
    var convert: ConvertStats?      // zip 이 아닌 항목이 있었을 때만
    var zip: ZipBatchStats?         // zip 이 있었을 때만
    var folders: [String] = []      // 드롭된 폴더(감시 목록 추가 대상)
    var summary = ""                // 패널에 표시할 요약(여러 줄 가능)
}

/// 드롭된 경로들을 분류해 처리한다 — UI 와 무관한 순수 로직(테스트 대상).
///
/// - 직접 드롭한 zip: 풀지 않고 내부 항목 이름을 고친다(`ZipNameFixer`).
/// - 그 외 파일·폴더: 이름을 NFC 로 변환한다(`NFCConverter`, 폴더는 하위까지).
///   폴더 안에 든 zip 은 파일 이름만 변환하고 내부는 건드리지 않는다.
enum DropProcessor {
    static func process(paths: [String]) -> DropOutcome {
        var outcome = DropOutcome()
        let zips = paths.filter { ZipNameFixer.isZip(path: $0) }
        let others = paths.filter { !zips.contains($0) }
        outcome.folders = others.filter { isDirectory($0) }
        var lines: [String] = []

        if !others.isEmpty {
            let stats = NFCConverter().run(rootPaths: others)
            outcome.convert = stats
            lines.append("변환 \(stats.renamed)개 · 검사 \(stats.scanned)개"
                         + (stats.errors.isEmpty ? "" : " · 오류 \(stats.errors.count)개"))
        }

        if !zips.isEmpty {
            var batch = ZipBatchStats()
            for path in zips {
                do {
                    let r = try ZipNameFixer.fix(path: path)
                    batch.files += 1
                    batch.renamed += r.renamed
                    batch.removed += r.removed
                    batch.flagged += r.flagged
                    if r.changed { batch.changedFiles += 1 }
                } catch {
                    batch.errors.append("\((path as NSString).lastPathComponent): \(error)")
                }
            }
            outcome.zip = batch
            lines.append("zip \(zips.count)개: 이름 수정 \(batch.renamed)개 · 항목 제거 \(batch.removed)개"
                         + (batch.errors.isEmpty ? "" : " · 오류 \(batch.errors.count)개"))
            // 실패 사유는 사용자가 알아야 한다(비밀번호 문제가 아니라 형식 문제임을 구분).
            for e in batch.errors.prefix(3) { lines.append("⚠︎ \(e)") }
        }
        outcome.summary = lines.joined(separator: "\n")
        return outcome
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
