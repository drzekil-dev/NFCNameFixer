import Foundation
import ServiceManagement

/// 앱 설정·상태 모델. 감시 폴더 목록을 영속화하고 FolderWatcher / 로그인 항목을 제어한다.
final class WatchStore: ObservableObject {
    @Published private(set) var watchedFolders: [String]
    @Published private(set) var isWatching: Bool
    @Published private(set) var launchAtLogin: Bool
    /// (변환 개수, 시각) — 마지막 변환 표시용.
    @Published private(set) var lastResult: (count: Int, date: Date)?
    /// 감시 폴더의 압축 파일 처리 기록(수정됨/실패/미지원).
    @Published private(set) var log = ProcessLog()
    /// 사용자가 아직 확인하지 않은 문제가 있는지 — 메뉴바 아이콘을 경고 모양으로 바꾸는 신호.
    @Published private(set) var hasUnseenProblems = false
    /// 새 문제가 생겼을 때 호출(시스템 알림용). 메인 스레드.
    var onProblems: (([ProcessRecord]) -> Void)?

    private let watcher = FolderWatcher()
    private let defaults = UserDefaults.standard
    private let kFolders = "watchedFolders"
    private let kWatching = "isWatching"

    init() {
        watchedFolders = defaults.stringArray(forKey: kFolders) ?? []
        isWatching = (defaults.object(forKey: kWatching) as? Bool) ?? true
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        watcher.onConverted = { [weak self] count in
            self?.lastResult = (count, Date())
        }
        watcher.onArchiveEvents = { [weak self] events in
            guard let self = self else { return }
            let newProblems = self.log.apply(events)
            if !newProblems.isEmpty {
                self.hasUnseenProblems = true
                self.onProblems?(newProblems)
            } else if self.log.problemCount == 0 {
                self.hasUnseenProblems = false      // 문제가 전부 해소됨(파일 교체·삭제)
            }
        }
        if isWatching { watcher.start(paths: watchedFolders) }
    }

    // MARK: - 감시 on/off

    func setWatching(_ on: Bool) {
        isWatching = on
        defaults.set(on, forKey: kWatching)
        if on { watcher.start(paths: watchedFolders) } else { watcher.stop() }
    }

    // MARK: - 감시 폴더 관리

    func addFolder(_ path: String) {
        guard !watchedFolders.contains(path) else { return }
        watchedFolders.append(path)
        defaults.set(watchedFolders, forKey: kFolders)
        if isWatching { watcher.start(paths: watchedFolders) }
    }

    func removeFolder(_ path: String) {
        watchedFolders.removeAll { $0 == path }
        defaults.set(watchedFolders, forKey: kFolders)
        if isWatching { watcher.start(paths: watchedFolders) }
    }

    /// "지정 폴더 지금 스캔" — 감시 폴더 전체를 즉시 1회 스캔(이름 변환 + zip 내부 수정).
    /// (감시 큐에서 직렬 실행되므로 FSEvents 처리와 같은 트리를 동시에 훑지 않는다.)
    func scanNow() {
        let folders = watchedFolders
        guard !folders.isEmpty else { return }
        watcher.scan(paths: folders) { [weak self] stats in
            self?.lastResult = (stats.renamed, Date())
        }
    }

    // MARK: - 처리 기록

    /// 사용자가 창을 열어 문제를 봤다 → 메뉴바 경고를 내린다(기록은 남는다).
    func markProblemsSeen() {
        if hasUnseenProblems { hasUnseenProblems = false }
    }

    func clearLog() {
        log.clear()
        hasUnseenProblems = false
    }

    /// 드롭된 경로들을 처리한다(zip 은 내부 이름 수정, 그 외는 NFC 변환).
    /// 감시 큐에서 직렬 실행되고, 드롭된 폴더는 감시 목록에 추가한다. 결과는 메인 스레드로 전달.
    func processDrop(paths: [String], completion: @escaping (DropOutcome) -> Void) {
        watcher.perform({ DropProcessor.process(paths: paths) }) { [weak self] outcome in
            for dir in outcome.folders { self?.addFolder(dir) }
            completion(outcome)
        }
    }

    /// 패널이 열릴 때 호출. 보호 폴더 권한이 없는 채로 감시를 시작했었다면
    /// (허용 창에서 거부했거나 나중에 설정에서 켠 경우) 스트림을 다시 만든다.
    /// 정상 동작 중인 스트림은 건드리지 않으므로 창을 열 때마다 전체 스캔이 돌지 않는다.
    func rescanOnAppear() {
        guard isWatching else { return }
        watcher.restartIfBlocked()
    }

    // MARK: - 로그인 시 시작

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // 등록 실패해도 실제 상태로 동기화.
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
}
