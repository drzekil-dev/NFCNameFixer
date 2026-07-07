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

    /// "지정 폴더 지금 스캔" — 감시 폴더 전체를 즉시 1회 스캔(백그라운드).
    func scanNow() {
        let folders = watchedFolders
        guard !folders.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stats = NFCConverter().run(rootPaths: folders)
            DispatchQueue.main.async { self?.lastResult = (stats.renamed, Date()) }
        }
    }

    /// 패널이 열릴 때 호출. 감시 중이면 스트림을 새로 생성한다.
    /// → 보호 폴더 접근 권한(TCC)을 처음 허용한 뒤, 수동 토글 없이 자동 복구됨.
    ///   (start()는 스트림 재생성 + 시작 스캔을 백그라운드로 수행하므로 UI를 막지 않는다.)
    func rescanOnAppear() {
        guard isWatching else { return }
        watcher.start(paths: watchedFolders)
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
