import Foundation
import CoreServices

/// 지정 폴더(및 하위)를 FSEvents로 감시하다가 NFD 한글 이름이 생기면 NFC로 변환한다.
///
/// 폴링이 아니라 이벤트(인터럽트형 push) 방식: 평소엔 잠들어 있고 커널이 변경 시점에 깨운다.
/// 이벤트 유실 가능성(앱 꺼짐, 커널 드롭, 합치기)은 아래로 보강한다:
///  - 시작 시 1회 전체 스캔(앱이 꺼져 있던 동안의 누락분 회수)
///  - KernelDropped/UserDropped/MustScanSubDirs 플래그가 오면 전체 재스캔
///  - 외부에서 convert()를 수동 호출(메뉴 "지정 폴더 지금 스캔")
///
/// 동시성: 스트림 상태와 모든 변환(이벤트 처리·수동 스캔·드롭)은 하나의 직렬 큐에서만
/// 실행한다. 같은 트리를 두 Converter가 동시에 훑으며 서로의 rename을 실패시키는 일이 없다.
final class FolderWatcher {
    /// 변환이 일어났을 때 (변환 개수)를 메인 스레드로 알린다. UI 갱신용.
    var onConverted: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "com.dmeta.nfcnamefixer.watch")
    // 아래 상태는 전부 queue 위에서만 읽고 쓴다.
    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    /// 스트림을 만들 때 열 수 없던 감시 폴더가 있었는지(TCC 보호 폴더 미허용 등).
    /// 사용자가 나중에 권한을 주면 그때 스트림을 다시 만들어야 하므로 기억해 둔다.
    private var blockedAtStart = false

    /// 감시 시작. 기존 스트림이 있으면 정리 후 재생성한다.
    ///
    /// 보호 폴더(다운로드 등)를 처음 열면 macOS가 TCC 허용 창을 띄우며 그 동안 호출이 멈춘다.
    /// 스트림을 그 전에 만들면 허용 후에도 이벤트를 받지 못하므로, 접근 확인 → 스트림 생성 →
    /// 시작 스캔 순서를 모두 백그라운드 큐에서 수행한다(UI도 막지 않는다).
    func start(paths: [String]) {
        queue.async { [self] in
            teardownStream()
            self.paths = paths
            guard !paths.isEmpty else { return }
            blockedAtStart = paths.contains { !canOpen($0) }
            createStream()
            scanAll()
        }
    }

    func stop() {
        queue.async { [self] in
            teardownStream()
            paths = []
        }
    }

    /// 패널이 열릴 때 호출. 권한이 막힌 채 시작했던 경우에만 스트림을 다시 만든다.
    /// (매번 전체 스캔을 돌리지 않도록 — 정상 시작한 스트림은 그대로 둔다.)
    func restartIfBlocked() {
        queue.async { [self] in
            guard !paths.isEmpty, blockedAtStart || stream == nil else { return }
            let current = paths
            teardownStream()
            blockedAtStart = current.contains { !canOpen($0) }
            paths = current
            createStream()
            scanAll()
        }
    }

    /// 임의 경로들을 변환한다(드롭·"지금 스캔"). 다른 변환과 직렬로 실행되며,
    /// 완료 시 통계를 메인 스레드로 전달한다.
    func convert(paths targets: [String], completion: @escaping (ConvertStats) -> Void) {
        queue.async {
            let stats = NFCConverter().run(rootPaths: targets)
            DispatchQueue.main.async { completion(stats) }
        }
    }

    // MARK: - queue 전용

    private func createStream() {
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        // UseCFTypes: 콜백의 eventPaths를 CFArray<CFString>로 받는다.
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { (_, info, numEvents, eventPaths, eventFlags, _) in
            guard let info = info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(UnsafeRawPointer(eventPaths)).takeUnretainedValue()
            let changed = (cfPaths as NSArray as? [String]) ?? []
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
        FSEventStreamSetDispatchQueue(s, queue)   // 콜백도 같은 직렬 큐에서 실행
        FSEventStreamStart(s)
    }

    private func teardownStream() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    /// 현재 감시 폴더 전체를 1회 스캔(변환).
    private func scanAll() {
        guard !paths.isEmpty else { return }
        let stats = NFCConverter().run(rootPaths: paths)
        if stats.renamed > 0 { notify(stats.renamed) }
    }

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

    /// 디렉터리를 실제로 열 수 있는지(TCC 거부 시 opendir이 EPERM으로 실패한다).
    private func canOpen(_ path: String) -> Bool {
        guard let d = opendir(path) else { return false }
        closedir(d)
        return true
    }

    private func notify(_ count: Int) {
        DispatchQueue.main.async { [weak self] in self?.onConverted?(count) }
    }
}
