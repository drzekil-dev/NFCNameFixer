import Foundation

// DropProcessor CLI 하니스 — tests/drop_test.sh 가 사용한다.
// 사용: dropproc <path> ...   출력: 요약 + "folders=..." 줄
let outcome = DropProcessor.process(paths: Array(CommandLine.arguments.dropFirst()))
print(outcome.summary)
// 드롭 당시 경로 문자열은 NFD 일 수 있다(APFS 는 정규화 비민감이라 변환 후에도 유효) → 비교용으로 NFC 출력.
print("folders=\(outcome.folders.map { ($0 as NSString).lastPathComponent.precomposedStringWithCanonicalMapping }.joined(separator: ","))")
print("convert=\(outcome.convert.map { "\($0.renamed)/\($0.scanned)" } ?? "nil") zip=\(outcome.zip.map { "\($0.files) ok, \($0.changedFiles) changed, \($0.errors.count) err" } ?? "nil")")
