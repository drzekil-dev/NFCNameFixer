import Foundation
import CoreServices

/// 지정 폴더(및 하위)를 FSEvents로 감시하다가 NFD 한글 이름이 생기면 NFC로 변환한다.
///
/// 폴링이 아니라 이벤트(인터럽트형 push) 방식: 평소엔 잠들어 있고 커널이 변경 시점에 깨운다.
/// 이벤트 유실 가능성(앱 꺼짐, 커널 드롭, 합치기)은 아래로 보강한다:
///  - 시작 시 1회 전체 스캔(앱이 꺼져 있던 동안의 누락분 회수)
///  - KernelDropped/UserDropped/MustScanSubDirs 플래그가 오면 전체 재스캔
///  - 외부에서 scanAll()을 수동 호출(메뉴 "지정 폴더 지금 스캔", 패널 열 때 등)
final class FolderWatcher {
    /// 변환이 일어났을 때 (변환 개수)를 메인 스레드로 알린다. UI 갱신용.
    var onConverted: ((Int) -> Void)?

    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    private let queue = DispatchQueue(label: "com.dmeta.nfcnamefixer.watch")

    /// 감시 시작. 기존 스트림이 있으면 정리 후 재생성한다.
    func start(paths: [String]) {
        stop()
        self.paths = paths
        guard !paths.isEmpty else { return }

        // 시작 시 1회 전체 스캔 (백그라운드 큐에서 — 앱 기동 차단 방지).
        queue.async { [weak self] in self?.scanAll() }

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        // UseCFTypes: 콜백의 eventPaths를 CFArray<CFString>로 받는다(아래 NSArray 캐스팅 전제).
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { (_, info, numEvents, eventPaths, eventFlags, _) in
            guard let info = info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flagBuf = UnsafeBufferPointer(start: eventFlags, count: numEvents)
            watcher.handle(changed: changed, flags: Array(flagBuf))
        }

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &ctx,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,                                  // latency(초): 연쇄 변경 합치기
            flags
        ) else { return }

        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    /// 현재 감시 폴더 전체를 1회 스캔(변환). 변환 개수를 반환.
    @discardableResult
    func scanAll() -> Int {
        guard !paths.isEmpty else { return 0 }
        let stats = NFCConverter().run(rootPaths: paths)
        if stats.renamed > 0 { notify(stats.renamed) }
        return stats.renamed
    }

    // MARK: - 이벤트 처리

    private func handle(changed: [String], flags: [FSEventStreamEventFlags]) {
        // 드롭/재스캔 신호가 있으면 변경 경로만으로는 부족 → 전체 재스캔.
        let mustRescan = flags.contains { f in
            f & UInt32(kFSEventStreamEventFlagKernelDropped) != 0 ||
            f & UInt32(kFSEventStreamEventFlagUserDropped) != 0 ||
            f & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
        }
        let targets = mustRescan ? paths : changed
        guard !targets.isEmpty else { return }
        let stats = NFCConverter().run(rootPaths: targets)
        if stats.renamed > 0 { notify(stats.renamed) }
    }

    private func notify(_ count: Int) {
        DispatchQueue.main.async { [weak self] in self?.onConverted?(count) }
    }
}
