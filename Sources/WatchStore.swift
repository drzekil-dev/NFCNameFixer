import Foundation
import ServiceManagement

/// 앱 설정·상태 모델. 감시 폴더 목록을 영속화하고 FolderWatcher / 로그인 항목을 제어한다.
final class WatchStore: ObservableObject {
    @Published private(set) var watchedFolders: [String]
    @Published private(set) var isWatching: Bool
    @Published private(set) var launchAtLogin: Bool
    /// (변환 개수, 시각) — 마지막 변환 표시용.
    @Published private(set) var lastResult: (count: Int, date: Date)?

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

    /// "지정 폴더 지금 스캔" — 감시 폴더 전체를 즉시 1회 스캔.
    /// (감시 큐에서 직렬 실행되므로 FSEvents 처리와 같은 트리를 동시에 훑지 않는다.)
    func scanNow() {
        let folders = watchedFolders
        guard !folders.isEmpty else { return }
        watcher.convert(paths: folders) { [weak self] stats in
            self?.lastResult = (stats.renamed, Date())
        }
    }

    /// 드롭된 경로들을 변환한다. 완료 시 통계를 메인 스레드로 전달.
    func convert(paths: [String], completion: @escaping (ConvertStats) -> Void) {
        watcher.convert(paths: paths, completion: completion)
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
