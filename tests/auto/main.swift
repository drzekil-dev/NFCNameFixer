import Foundation

// 감시 폴더 zip 자동 수정 하니스 — tests/auto_test.sh 가 사용한다.
// 사용: autofix <감시폴더> <실행 초>
// 실제 FolderWatcher(FSEvents)를 돌리며 압축 파일 이벤트를 한 줄씩 찍고, 끝에 남은 문제 목록을 찍는다.
// (대기 시간은 테스트가 빨리 끝나도록 줄였다. 앱의 기본값은 ArchiveAutoFixer 참고.)

setvbuf(stdout, nil, _IOLBF, 0)
let dir = CommandLine.arguments[1]
let seconds = Double(CommandLine.arguments[2]) ?? 10

let watcher = FolderWatcher()
watcher.archives.settleInterval = 1.0
watcher.archives.giveUpAfter = 5
watcher.archives.recheckInterval = 0.5

var log = ProcessLog()
func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

watcher.onArchiveEvents = { events in
    for e in events {
        let label: String
        switch e.kind {
        case .fixed: label = "fixed"
        case .ok: label = "ok"
        case .failed: label = "failed"
        case .unsupported: label = "unsupported"
        case .gone: label = "gone"
        }
        print("EVENT \(label) \(nfc(e.name))")
    }
    log.apply(events)
}
watcher.start(paths: [dir])

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    print("PROBLEMS \(log.records.filter(\.isProblem).map { nfc($0.name) }.sorted().joined(separator: ","))")
    print("DISPLAY_FIRST \(log.displayOrder.first.map { nfc($0.name) } ?? "-")")
    exit(0)
}
RunLoop.main.run()
