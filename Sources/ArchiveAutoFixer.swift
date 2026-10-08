import Foundation

/// 감시 폴더의 압축 파일 하나에 대해 일어난 일.
enum ArchiveEventKind: Equatable {
    case fixed(renamed: Int, removed: Int)   // zip 내부 이름을 고쳤다
    case ok                                  // 고칠 것이 없다(이전 문제가 해소됨)
    case failed(String)                      // 고치지 못했다
    case unsupported(String)                 // 내부 이름을 고칠 수 없는 형식
    case gone                                // 문제가 있던 파일이 사라졌다
}

struct ArchiveEvent {
    var path: String
    var kind: ArchiveEventKind
    var name: String { (path as NSString).lastPathComponent }
}

/// 감시 폴더에 들어온 zip 의 내부 이름을 자동으로 고친다.
///
/// 원칙: 감시 폴더의 zip 은 전부 처리하고, 안 된 것은 반드시 이벤트로 알린다(조용하면 다 된 것).
/// - 쓰는 중인 파일은 건드리지 않는다: (크기·수정시각·inode)가 `settleInterval` 동안 그대로일 때 처리.
/// - 구조가 불완전한데 최근에 수정된 파일은 실패로 보지 않고 `giveUpAfter` 까지 계속 기다린다.
/// - 같은 상태의 파일은 다시 열지 않는다(우리가 다시 쓴 결과 포함).
///
/// 스레드: 호출자가 직렬화한다(FolderWatcher 의 직렬 큐에서만 호출).
final class ArchiveAutoFixer {
    /// 이 시간 동안 파일이 변하지 않아야 "쓰기 완료"로 본다.
    var settleInterval: TimeInterval = 1.5
    /// 수정시각이 이만큼 지난 파일은 기다리지 않고 바로 처리한다.
    var oldEnough: TimeInterval = 10
    /// 불완전한 zip 을 실패로 확정하기 전에, 마지막 수정 후 기다리는 시간.
    var giveUpAfter: TimeInterval = 60
    /// 대기 중인 파일을 다시 확인하는 주기(FolderWatcher 가 사용).
    var recheckInterval: TimeInterval = 2

    /// 내부 이름을 고칠 수 없는 형식(이름이 압축·암호화 블록 안에 있거나 쓰기 도구가 없음).
    static let unsupportedExtensions: Set<String> = ["7z", "rar", "alz", "egg"]

    private struct Signature: Equatable {
        var size: Int64, mtimeSec: Int, mtimeNsec: Int, inode: UInt64
        var modified: Date { Date(timeIntervalSince1970: Double(mtimeSec) + Double(mtimeNsec) / 1e9) }
    }

    private var handled: [String: Signature] = [:]                       // 처리 끝난 상태
    private var pending: [String: (sig: Signature, since: Date)] = [:]   // 쓰기 완료 대기
    private var problems: Set<String> = []                               // 문제로 알린 경로
    private var noticed: Set<String> = []                                // 미지원 형식 알림을 낸 경로

    var hasPending: Bool { !pending.isEmpty }

    /// 대기 목록만 비운다(감시 중지 시). 처리 기록은 유지해 재시작 때 같은 파일을 다시 열지 않는다.
    func clearPending() { pending.removeAll() }

    /// 경로들(파일 또는 폴더)을 검사한다. 폴더는 하위까지 훑는다.
    /// - Parameter fromEvent: 파일 시스템 이벤트로 온 것인지(전체 스캔이 아닌지). 미지원 형식 알림은 이때만 낸다.
    func examine(targets: [String], fromEvent: Bool, now: Date = Date()) -> [ArchiveEvent] {
        var events: [ArchiveEvent] = []
        var seen = Set<String>()
        for target in targets {
            for path in archivePaths(under: target) where seen.insert(path).inserted {
                examineOne(path, fromEvent: fromEvent, now: now, into: &events)
            }
        }
        // 전체 스캔 때는, 문제로 알렸던 파일이 그 사이 사라졌는지도 확인한다.
        if !fromEvent {
            for path in problems where !seen.contains(path) && signature(path) == nil {
                forget(path); events.append(ArchiveEvent(path: path, kind: .gone))
            }
        }
        return events
    }

    /// 대기 중인 파일들을 다시 확인한다.
    func recheckPending(now: Date = Date()) -> [ArchiveEvent] {
        var events: [ArchiveEvent] = []
        for path in Array(pending.keys) { examineOne(path, fromEvent: true, now: now, into: &events) }
        return events
    }

    // MARK: - 내부

    private func examineOne(_ path: String, fromEvent: Bool, now: Date, into events: inout [ArchiveEvent]) {
        guard let sig = signature(path) else {
            // 사라졌다(삭제·이동). 문제로 알렸던 파일이면 해소를 알린다.
            let hadProblem = problems.contains(path)
            forget(path)
            if hadProblem { events.append(ArchiveEvent(path: path, kind: .gone)) }
            return
        }
        let ext = (path as NSString).pathExtension.lowercased()

        if Self.unsupportedExtensions.contains(ext) {
            // 새로 들어왔고(이벤트), 이 맥에서 만든 것(격리 표시 없음)일 때만 한 번 알린다.
            guard fromEvent, !noticed.contains(path), !isQuarantined(path) else { return }
            noticed.insert(path); problems.insert(path)
            events.append(ArchiveEvent(path: path, kind: .unsupported(
                "\(ext.uppercased()) 형식은 내부 파일명을 고칠 수 없습니다. zip 으로 압축해 주세요.")))
            return
        }
        guard ext == "zip" else { return }
        if handled[path] == sig { return }

        // 쓰기 완료 대기.
        if now.timeIntervalSince(sig.modified) < oldEnough {
            if let p = pending[path], p.sig == sig {
                if now.timeIntervalSince(p.since) < settleInterval { return }   // 아직 관찰 중
            } else {
                pending[path] = (sig, now)                                       // 처음 봤거나 그 사이 변함
                return
            }
        }

        do {
            guard ZipNameFixer.isZip(path: path) else {
                if ZipNameFixer.isEmptyZip(path: path) { settle(path, sig, .ok, &events); return }
                throw ZipFixError.notZip("zip 파일로 인식되지 않습니다")
            }
            let r = try ZipNameFixer.fix(path: path)
            // 다시 썼다면 서명이 바뀌었다 → 새 서명을 기억해 우리 자신의 변경에 다시 반응하지 않는다.
            let after = r.changed ? (signature(path) ?? sig) : sig
            settle(path, after, r.changed ? .fixed(renamed: r.renamed, removed: r.removed) : .ok, &events)
        } catch let error as ZipFixError {
            // 구조가 불완전한데 최근에 수정된 파일 → 아직 쓰는 중일 수 있다. 실패로 보지 않고 더 기다린다.
            if case .corrupt = error, now.timeIntervalSince(sig.modified) < giveUpAfter {
                pending[path] = (sig, now)
                return
            }
            let reason: String
            if case .notZip(let m) = error { reason = m } else { reason = error.description }
            settle(path, sig, .failed(reason), &events)
        } catch {
            settle(path, sig, .failed("\(error)"), &events)
        }
    }

    /// 처리 결과를 확정한다: 상태 기억 + 필요한 이벤트만 낸다.
    private func settle(_ path: String, _ sig: Signature, _ kind: ArchiveEventKind, _ events: inout [ArchiveEvent]) {
        pending[path] = nil
        handled[path] = sig
        switch kind {
        case .failed:
            problems.insert(path)
            events.append(ArchiveEvent(path: path, kind: kind))
        case .fixed:
            problems.remove(path)
            events.append(ArchiveEvent(path: path, kind: kind))
        case .ok:
            // 원래 문제 없던 파일은 조용히 넘어간다. 문제였던 파일만 해소를 알린다.
            if problems.remove(path) != nil { events.append(ArchiveEvent(path: path, kind: .ok)) }
        case .unsupported, .gone:
            break
        }
    }

    private func forget(_ path: String) {
        handled[path] = nil; pending[path] = nil
        problems.remove(path); noticed.remove(path)
    }

    /// target 이 파일이면 자신(압축 확장자일 때), 폴더면 하위의 압축 파일 전부. 경로는 NFC 로 통일한다.
    /// (이름 변환이 먼저 끝난 뒤 호출되므로 디스크의 이름은 NFC 다. APFS 는 정규화 비민감이라 어느 쪽이든 열린다.)
    private func archivePaths(under target: String) -> [String] {
        let root = target.precomposedStringWithCanonicalMapping
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            return isArchiveName(root) ? [root] : []     // 없는 경로도 넘긴다 → "사라짐" 처리
        }
        var result: [String] = []
        guard let en = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in en where isArchiveName(url.path) {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result.append(url.path.precomposedStringWithCanonicalMapping)
            }
        }
        return result
    }

    private func isArchiveName(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix(".") else { return false }            // 숨김·임시 파일 제외
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "zip" || Self.unsupportedExtensions.contains(ext)
    }

    private func signature(_ path: String) -> Signature? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Signature(size: Int64(st.st_size), mtimeSec: st.st_mtimespec.tv_sec,
                         mtimeNsec: st.st_mtimespec.tv_nsec, inode: UInt64(st.st_ino))
    }

    /// macOS 가 밖에서 들어온 파일(다운로드·메신저·메일·AirDrop)에 붙이는 격리 표시가 있는지.
    private func isQuarantined(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }
}

// MARK: - 처리 기록

/// 패널에 보여 줄 처리 기록 한 건.
struct ProcessRecord: Identifiable {
    let id = UUID()
    var path: String
    var kind: ArchiveEventKind
    var date: Date

    var name: String { (path as NSString).lastPathComponent }
    var isProblem: Bool {
        switch kind {
        case .failed, .unsupported: return true
        default: return false
        }
    }
    var detail: String {
        switch kind {
        case .fixed(let renamed, let removed):
            return "zip 내부 이름 수정 \(renamed)개" + (removed > 0 ? " · 불필요 항목 제거 \(removed)개" : "")
        case .failed(let reason), .unsupported(let reason): return reason
        case .ok: return "문제 없음"
        case .gone: return "삭제됨"
        }
    }
}

/// 최근 처리 기록. 경로당 한 건만 유지하고, 문제가 해소되거나 파일이 사라지면 기록을 지운다.
struct ProcessLog {
    private(set) var records: [ProcessRecord] = []   // 최신이 앞
    let capacity = 50

    var problemCount: Int { records.filter(\.isProblem).count }

    /// 표시용: 문제를 먼저, 그 안에서는 최신순.
    var displayOrder: [ProcessRecord] { records.filter(\.isProblem) + records.filter { !$0.isProblem } }

    /// 이벤트를 반영하고, 이번에 새로 생긴 문제 기록을 돌려준다(알림용).
    @discardableResult
    mutating func apply(_ events: [ArchiveEvent], now: Date = Date()) -> [ProcessRecord] {
        var newProblems: [ProcessRecord] = []
        for e in events {
            records.removeAll { $0.path == e.path }
            switch e.kind {
            case .ok, .gone:
                continue
            case .fixed, .failed, .unsupported:
                let r = ProcessRecord(path: e.path, kind: e.kind, date: now)
                records.insert(r, at: 0)
                if r.isProblem { newProblems.append(r) }
            }
        }
        // 넘치면 문제가 아닌 오래된 기록부터 버린다(문제 기록은 해소될 때까지 남긴다).
        while records.count > capacity, let i = records.lastIndex(where: { !$0.isProblem }) { records.remove(at: i) }
        return newProblems
    }

    mutating func clear() { records.removeAll() }
}
