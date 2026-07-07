import Foundation

/// 변환 결과 통계.
struct ConvertStats {
    var renamed = 0                 // 실제로 NFC로 바꾼 항목 수
    var scanned = 0                 // 검사한 항목 수
    var skipped: [String] = []      // 이름 충돌 등으로 건너뛴 항목
    var errors: [String] = []       // rename 실패 등 오류
    var samples: [String] = []      // 변경 내역 표시용 (앞쪽 일부)
}

/// macOS(NFD) 한글 파일/폴더 이름을 Windows 호환(NFC)으로 변환한다.
///
/// 핵심 설계:
/// - `FileManager`/`URL`은 디스크의 NFD 바이트를 읽는 즉시 NFC 문자열로 정규화해버려
///   NFD를 탐지하지도, 올바른 source 바이트로 rename 하지도 못한다.
/// - 따라서 POSIX `opendir`/`readdir`로 raw 바이트를 읽고, `rename(2)`에 raw 바이트
///   경로를 그대로 넘긴다. APFS는 정규화 비민감이지만 바이트는 보존하므로,
///   source(NFD)와 dest(NFC) 바이트가 다르면 실제로 NFC 바이트로 저장된다.
/// - "변환 필요" 판단은 `String.compare(_:options: .literal)` 로 한다. `.literal`은
///   유니코드 정규화를 적용하지 않고 코드 유닛 그대로 비교하므로 NFD/NFC를 구분한다.
///   (그냥 `==` 나 기본 compare 는 정규형 등가라 둘을 같다고 보아 쓸 수 없다.)
final class NFCConverter {
    private(set) var stats = ConvertStats()
    private let maxSamples = 300

    /// 드롭된 경로들(파일 또는 폴더)을 변환한다. 폴더는 하위까지 재귀.
    @discardableResult
    func run(rootPaths: [String]) -> ConvertStats {
        stats = ConvertStats()
        for p in rootPaths {
            processRoot(Array(p.utf8))
        }
        return stats
    }

    // MARK: - 루트 처리

    /// 드롭된 항목은 OS가 NFC 문자열로 정규화해 넘겨줄 수 있으므로,
    /// 부모 디렉터리를 raw로 훑어 실제 on-disk 이름(바이트)을 찾아낸 뒤 처리한다.
    private func processRoot(_ rootBytes: [UInt8]) {
        var bytes = rootBytes
        // 끝의 '/' 제거
        while bytes.count > 1, bytes.last == 0x2f { bytes.removeLast() }
        guard let slash = bytes.lastIndex(of: 0x2f) else {
            stats.errors.append("잘못된 경로: \(String(decoding: rootBytes, as: UTF8.self))")
            return
        }
        let parent = Array(bytes[..<slash])
        let leaf = Array(bytes[(slash + 1)...])

        guard let entry = findEntry(parent: parent, matching: leaf) else {
            stats.errors.append("항목을 찾을 수 없음: \(String(decoding: rootBytes, as: UTF8.self))")
            return
        }
        processEntry(parent: parent, name: entry.name, isDir: entry.isDir)
    }

    // MARK: - 재귀 처리

    private struct Entry { var name: [UInt8]; var isDir: Bool }

    private func processEntry(parent: [UInt8], name: [UInt8], isDir: Bool) {
        stats.scanned += 1
        if isDir {
            // 하위를 먼저 처리(부모 이름이 아직 안 바뀐 상태의 경로 사용 → 안전).
            let childDir = parent + [0x2f] + name
            var kids: [Entry] = []
            forEachChild(childDir) { n, d in kids.append(Entry(name: n, isDir: d)); return true }
            for k in kids {
                processEntry(parent: childDir, name: k.name, isDir: k.isDir)
            }
        }
        // 그 다음 이 항목 자신을 변환.
        maybeRename(parent: parent, name: name)
    }

    /// 필요 시 NFC로 rename. 이미 NFC면 아무것도 하지 않는다.
    private func maybeRename(parent: [UInt8], name: [UInt8]) {
        let raw = String(decoding: name, as: UTF8.self)
        let nfc = raw.precomposedStringWithCanonicalMapping
        // .literal: 정규화 없이 코드 유닛 비교 → 같으면 이미 NFC.
        if raw.compare(nfc, options: .literal) == .orderedSame { return }

        let nfcBytes = Array(nfc.utf8)
        let oldPath = parent + [0x2f] + name
        let newPath = parent + [0x2f] + nfcBytes

        // 진짜 충돌(서로 다른 파일이 이미 NFC 이름을 점유)인지 확인.
        // APFS는 정규화 비민감이라 같은 파일이면 같은 inode로 잡힌다 → 그땐 진행한다.
        if let oldID = statID(oldPath), let newID = statID(newPath), oldID != newID {
            stats.skipped.append("\(raw) → 다른 항목이 이미 NFC 이름 사용 중")
            return
        }

        if renameBytes(oldPath, newPath) == 0 {
            stats.renamed += 1
            if stats.samples.count < maxSamples { stats.samples.append("\(raw)  →  \(nfc)") }
        } else {
            stats.errors.append("\(raw): rename 실패 (errno \(errno))")
        }
    }

    // MARK: - POSIX 헬퍼

    private func cString(_ bytes: [UInt8]) -> [CChar] {
        var c = bytes.map { CChar(bitPattern: $0) }
        c.append(0)
        return c
    }

    private func findEntry(parent: [UInt8], matching leaf: [UInt8]) -> Entry? {
        let target = String(decoding: leaf, as: UTF8.self)
        var found: Entry?
        forEachChild(parent) { name, isDir in
            // 정규형 차이를 흡수하려 여기서는 일반 == (정규형 등가) 비교가 적절하다.
            if String(decoding: name, as: UTF8.self) == target {
                found = Entry(name: name, isDir: isDir)
                return false   // 중단
            }
            return true
        }
        return found
    }

    /// 디렉터리의 직속 항목을 raw 바이트로 순회. body가 false를 반환하면 중단.
    private func forEachChild(_ dirBytes: [UInt8], _ body: (_ name: [UInt8], _ isDir: Bool) -> Bool) {
        let c = cString(dirBytes)
        guard let dir = c.withUnsafeBufferPointer({ opendir($0.baseAddress) }) else { return }
        defer { closedir(dir) }
        while let ent = readdir(dir) {
            var nameBytes = [UInt8]()
            withUnsafeBytes(of: ent.pointee.d_name) { raw in
                for b in raw { if b == 0 { break }; nameBytes.append(b) }
            }
            if nameBytes == [0x2e] || nameBytes == [0x2e, 0x2e] { continue }  // . ..

            var isDir = ent.pointee.d_type == UInt8(DT_DIR)
            if ent.pointee.d_type == UInt8(DT_UNKNOWN) {
                isDir = statIsDir(dirBytes + [0x2f] + nameBytes)
            }
            // 심볼릭 링크(DT_LNK)는 isDir=false 로 두어 따라 들어가지 않는다(루프 방지).
            if !body(nameBytes, isDir) { break }
        }
    }

    private func renameBytes(_ old: [UInt8], _ new: [UInt8]) -> Int32 {
        let oc = cString(old)
        let nc = cString(new)
        return oc.withUnsafeBufferPointer { op in
            nc.withUnsafeBufferPointer { np in
                rename(op.baseAddress, np.baseAddress)
            }
        }
    }

    private func statID(_ path: [UInt8]) -> (dev_t, ino_t)? {
        let c = cString(path)
        var st = stat()
        let rc = c.withUnsafeBufferPointer { lstat($0.baseAddress, &st) }
        return rc == 0 ? (st.st_dev, st.st_ino) : nil
    }

    private func statIsDir(_ path: [UInt8]) -> Bool {
        let c = cString(path)
        var st = stat()
        let rc = c.withUnsafeBufferPointer { lstat($0.baseAddress, &st) }
        return rc == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}
