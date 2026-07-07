import SwiftUI
import AppKit
import CoreServices
import UniformTypeIdentifiers

extension Notification.Name {
    /// 창 안의 "종료" 버튼 → AppDelegate가 받아 실제 종료를 수행.
    static let nfcQuitRequested = Notification.Name("nfcQuitRequested")
}

@main
struct NFCNameFixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 메뉴바 아이콘과 창은 AppDelegate가 직접 관리한다.
        // (MenuBarExtra .window 팝오버는 드래그 시작 시 자동으로 닫혀 드롭이 불가능하므로 쓰지 않음.)
        Settings { EmptyView() }
    }
}

/// 메뉴바 아이콘(NSStatusItem)과 진짜 창(NSWindow)을 관리한다.
/// 팝오버가 아니라 일반 창이라 Finder에서 파일을 드래그해 와도 창이 닫히지 않는다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private let store = WatchStore()
    private var userInitiatedQuit = false   // 메뉴 "종료"로만 true

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 메뉴바 아이콘
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "textformat",
                                   accessibilityDescription: "한글 NFC 변환기")
            button.image?.isTemplate = true
            button.action = #selector(statusClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])  // 좌클릭=창, 우클릭=메뉴
        }

        // 창 준비(숨김 상태로 생성). 내용 크기에 맞춰 자동 리사이즈.
        let hosting = NSHostingController(rootView: PanelView(store: store))
        hosting.sizingOptions = [.preferredContentSize]
        window = NSWindow(contentViewController: hosting)
        window.title = "한글 파일명 NFC 변환기"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false   // 닫기 버튼은 숨김(orderOut)만, 객체 유지
        window.level = .floating               // 다른 창 위로

        // 창 안 "종료" 버튼 → 실제 종료.
        NotificationCenter.default.addObserver(
            self, selector: #selector(quitApp), name: .nfcQuitRequested, object: nil)
    }

    @objc private func toggleWindow(_ sender: Any?) {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            store.rescanOnAppear()             // 권한 부여 후 자동 복구 + 누락 점검
            positionUnderStatusItem()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// 메뉴바 아이콘 바로 아래에 창을 배치.
    private func positionUnderStatusItem() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { window.center(); return }
        let rectInWindow = button.convert(button.bounds, to: nil)
        let rectOnScreen = buttonWindow.convertToScreen(rectInWindow)
        let size = window.frame.size
        let x = rectOnScreen.midX - size.width / 2
        let y = rectOnScreen.minY - size.height - 4
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - 클릭 라우팅 / 종료 제어

    /// 좌클릭 → 창 토글, 우클릭(또는 control-클릭) → 메뉴(종료).
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else {
            toggleWindow(sender)
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        if let button = statusItem.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 4),
                       in: button)
        }
    }

    @objc private func quitApp() {
        userInitiatedQuit = true
        NSApp.terminate(nil)
    }

    /// Cmd-Q·창 닫기 등 사용자 종료 시도는 가로채 창만 숨긴다(메뉴바 상주 유지).
    /// 메뉴 "종료" 또는 시스템 로그아웃/재시작/종료일 때만 실제 종료한다.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if userInitiatedQuit { return .terminateNow }
        // 시스템 종료(로그아웃/재시작/셧다운)는 막지 않는다.
        if NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil {
            return .terminateNow
        }
        window.orderOut(nil)
        return .terminateCancel
    }
}

struct PanelView: View {
    // [윈도→맥 복원 기능 임시 비활성 — 필요 시 아래 주석과 restoreSection/handleRestoreDrop 주석 해제]
    // enum Mode: Hashable { case toNFC, restore }

    @ObservedObject var store: WatchStore
    // @State private var mode: Mode = .toNFC
    @State private var isTargeted = false
    @State private var dropSummary = ""
    // @State private var restoreSummary = ""

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("한글 파일명 변환기").font(.headline)

            // [복원 모드 전환 UI 비활성]
            // Picker("", selection: $mode) {
            //     Text("맥→윈도 (NFC)").tag(Mode.toNFC)
            //     Text("윈도→맥 (복원)").tag(Mode.restore)
            // }
            // .pickerStyle(.segmented)
            // .labelsHidden()
            // if mode == .toNFC { nfcSection } else { restoreSection }

            nfcSection

            Divider()

            HStack {
                Text("버전 \(appVersion)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("업데이트 확인") { checkForUpdate() }
                Button("종료") {
                    NotificationCenter.default.post(name: .nfcQuitRequested, object: nil)
                }
            }
            Text("Cmd-Q·닫기는 창만 숨깁니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: - NFC 변환 모드 (맥 → 윈도)

    private var nfcSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("폴더·파일을 끌어다 놓으면 NFC로 변환됩니다. 감시 폴더는 자동 변환됩니다.")
                .font(.caption).foregroundStyle(.secondary)

            dropZone(title: "여기에 폴더 / 파일 끌어다 놓기",
                     subtitle: "(폴더를 놓으면 감시 목록에도 추가됩니다)",
                     onDrop: handleNFCDrop)
            if !dropSummary.isEmpty {
                Text(dropSummary).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Toggle("자동 감시", isOn: Binding(
                get: { store.isWatching },
                set: { store.setWatching($0) }))
                .toggleStyle(.switch)

            Text("감시 폴더").font(.subheadline).bold()
            if store.watchedFolders.isEmpty {
                Text("감시 중인 폴더 없음 — 아래에서 추가하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.watchedFolders, id: \.self) { folder in
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text((folder as NSString).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .help(folder)
                        Spacer()
                        Button {
                            store.removeFolder(folder)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("감시 목록에서 제거")
                    }
                }
            }

            HStack {
                Button("감시 폴더 추가…") { addFolder() }
                Button("지정 폴더 지금 스캔") { store.scanNow() }
                    .disabled(store.watchedFolders.isEmpty)
            }

            if let r = store.lastResult {
                Text("마지막 변환: \(r.count)개 · \(timeString(r.date))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Toggle("로그인 시 시작", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
        }
    }

    // MARK: - 복원 모드 (윈도 → 맥) — 현재 버전 비활성 (필요 시 주석 해제)

    /*
    private var restoreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("윈도에서 받은 깨진 한글 이름을 복원합니다. 폴더·파일을 끌어다 놓으세요(하위 포함).")
                .font(.caption).foregroundStyle(.secondary)

            dropZone(title: "깨진 이름 복원 — 폴더 / 파일 놓기",
                     subtitle: "(멀쩡한 이름은 건드리지 않습니다)",
                     onDrop: handleRestoreDrop)
            if !restoreSummary.isEmpty {
                Text(restoreSummary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    */

    // MARK: - 드롭존(공용)

    private func dropZone(title: String, subtitle: String,
                          onDrop: @escaping ([NSItemProvider]) -> Void) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc.fill").font(.system(size: 26))
                Text(title).font(.caption)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
        }
        .frame(height: 96)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            onDrop(providers)
            return true
        }
    }

    // MARK: - 드롭 처리

    /// 드롭된 항목들의 파일 경로를 모아 완료 시 콜백(백그라운드 큐).
    private func collectPaths(_ providers: [NSItemProvider], _ done: @escaping ([String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var paths: [String] = []
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let path = url?.path {
                    lock.lock(); paths.append(path); lock.unlock()
                }
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) { done(paths) }
    }

    /// NFC 변환(맥→윈도). 폴더는 감시 목록에도 추가.
    private func handleNFCDrop(_ providers: [NSItemProvider]) {
        collectPaths(providers) { paths in
            let stats = NFCConverter().run(rootPaths: paths)
            let dirs = paths.filter { isDirectory($0) }
            DispatchQueue.main.async {
                dropSummary = "변환 \(stats.renamed)개 · 검사 \(stats.scanned)개"
                    + (stats.errors.isEmpty ? "" : " · 오류 \(stats.errors.count)개")
                for dir in dirs { store.addFolder(dir) }
            }
        }
    }

    /// 깨짐 복원(윈도→맥). — 현재 버전 비활성 (필요 시 주석 해제)
    /*
    private func handleRestoreDrop(_ providers: [NSItemProvider]) {
        collectPaths(providers) { paths in
            let stats = NameRestorer().run(rootPaths: paths)
            DispatchQueue.main.async {
                restoreSummary = "복원 \(stats.restored)개 · 검사 \(stats.scanned)개"
                    + (stats.skipped.isEmpty ? "" : " · 건너뜀 \(stats.skipped.count)개")
                    + (stats.errors.isEmpty ? "" : " · 오류 \(stats.errors.count)개")
            }
        }
    }
    */

    // MARK: - 업데이트 확인

    private func checkForUpdate() {
        UpdateChecker.check { latest, error in
            DispatchQueue.main.async {
                let alert = NSAlert()
                if let error = error {
                    alert.messageText = "업데이트 확인 실패"
                    alert.informativeText = error
                    alert.runModal()
                } else if let latest = latest, UpdateChecker.isNewer(latest, than: appVersion) {
                    alert.messageText = "새 버전 \(latest) 있음"
                    alert.informativeText = "현재 버전 \(appVersion). 다운로드 페이지를 열까요?"
                    alert.addButton(withTitle: "다운로드 페이지 열기")
                    alert.addButton(withTitle: "나중에")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(UpdateChecker.releasesURL)
                    }
                } else {
                    alert.messageText = "최신 버전입니다"
                    alert.informativeText = "현재 버전 \(appVersion)"
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - 헬퍼

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "감시 추가"
        panel.message = "감시할 폴더를 선택하세요."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls { store.addFolder(url.path) }
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
