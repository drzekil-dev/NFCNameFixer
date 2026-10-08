import Foundation

// ZipNameFixer CLI 하니스 — 테스트 스크립트(tests/zip_test.sh)가 사용한다.
// 사용: zipfix <file.zip> ...   출력: 한 줄 통계 또는 "ERROR: ..." (exit 1)

var failed = false
for path in CommandLine.arguments.dropFirst() {
    do {
        let r = try ZipNameFixer.fix(path: path)
        print("changed=\(r.changed) renamed=\(r.renamed) removed=\(r.removed) flagged=\(r.flagged) foreign=\(r.foreignNames)")
    } catch {
        print("ERROR: \(error)")
        failed = true
    }
}
exit(failed ? 1 : 0)
