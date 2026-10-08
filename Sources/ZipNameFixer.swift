import Foundation

/// zip 하나를 처리한 결과.
struct ZipFixResult {
    var renamed = 0        // NFD → NFC 로 이름을 바꾼 항목 수
    var removed = 0        // 제거한 __MACOSX 항목 수
    var flagged = 0        // UTF-8 플래그(bit 11)를 새로 켠 항목 수
    var changed = false    // 파일을 실제로 다시 썼는지
    /// 항목 이름이 UTF-8 이 아님(Windows 에서 CP949 로 만든 zip 등). 맥에서 만든 zip 이 아니므로
    /// 고칠 대상이 아니다 — 오류가 아니라 "수정 불필요"로 취급하고 파일은 건드리지 않는다.
    var foreignNames = false
}

enum ZipFixError: Error, CustomStringConvertible {
    case notZip(String)
    case unsupported(String)
    case corrupt(String)
    case io(String)

    var description: String {
        switch self {
        case .notZip(let s):       return "zip 아님: \(s)"
        case .unsupported(let s):  return "미지원 zip: \(s)"
        case .corrupt(let s):      return "손상된 zip: \(s)"
        case .io(let s):           return "입출력 오류: \(s)"
        }
    }
}

/// zip 내부 항목 이름을 Windows 호환으로 고친다 — 압축을 풀지 않고 zip 구조만 다시 쓴다.
///
/// 맥에서 만든 zip(Finder "압축", Info-ZIP zip)은 (1) 항목 이름이 NFD 바이트이고 (2) UTF-8 플래그
/// (general purpose bit 11)가 꺼져 있어, Windows가 이름을 CP949로 해석하며 깨진다. 여기서는
/// 각 항목의 압축/암호화된 데이터 블록은 바이트 그대로 복사하고, 로컬 헤더와 중앙 디렉터리의
/// 이름·플래그·오프셋만 바꾼다. 비밀번호 zip도 이름은 평문이라 비밀번호 없이 처리된다.
/// Finder가 끼워 넣는 `__MACOSX/` 항목은 버린다.
///
/// 임시 파일에 쓴 뒤 재파싱으로 자체 검증하고 원자적으로 교체한다. 바꿀 것이 없으면 쓰지 않는다.
enum ZipNameFixer {

    // MARK: - 공개 API

    /// 항목이 하나도 없는 빈 zip 인지(EOCD 시그니처로 시작). 고칠 것이 없는 정상 파일이다.
    static func isEmptyZip(path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { fh.closeFile() }
        let head = fh.readData(ofLength: 4)
        return head.count == 4 && head.elementsEqual([0x50, 0x4b, 0x05, 0x06])
    }

    /// 확장자 .zip 이고 로컬 헤더 시그니처로 시작하면 zip 으로 본다.
    static func isZip(path: String) -> Bool {
        guard path.lowercased().hasSuffix(".zip"),
              let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { fh.closeFile() }
        let head = fh.readData(ofLength: 4)
        return head.count == 4 && head.elementsEqual([0x50, 0x4b, 0x03, 0x04])
    }

    static func fix(path: String) throws -> ZipFixResult {
        guard isZip(path: path) else { throw ZipFixError.notZip(path) }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) }
        catch { throw ZipFixError.io(error.localizedDescription) }

        let archive = try parse(data)
        var result = ZipFixResult()

        // 항목별로 무엇을 바꿀지 결정.
        var plans: [EntryPlan] = []
        for e in archive.entries {
            guard let nameStr = String(bytes: e.name, encoding: .utf8) else {
                var untouched = ZipFixResult()
                untouched.foreignNames = true
                return untouched
            }
            if nameStr == "__MACOSX" || nameStr.hasPrefix("__MACOSX/") {
                result.removed += 1
                continue
            }
            let nfc = nameStr.precomposedStringWithCanonicalMapping
            let rename = nameStr.compare(nfc, options: .literal) != .orderedSame
            let nonASCII = e.name.contains { $0 >= 0x80 }
            let flag = nonASCII && (e.flags & 0x0800) == 0
            if rename { result.renamed += 1 }
            if flag { result.flagged += 1 }
            plans.append(EntryPlan(entry: e,
                                   newName: Array(nfc.utf8),
                                   newFlags: nonASCII ? (e.flags | 0x0800) : e.flags))
        }
        guard result.renamed + result.removed + result.flagged > 0 else { return result }

        // 정규화 때문에 서로 다른 두 항목이 같은 이름이 되면(예: NFD '가.txt' 와 NFC '가.txt' 가 함께 든 zip)
        // 풀 때 하나가 다른 하나를 덮어쓴다 → 손대지 않고 거부한다.
        if Set(plans.map { $0.newName }).count < Set(plans.map { $0.entry.name }).count {
            throw ZipFixError.unsupported("NFC 로 바꾸면 이름이 겹치는 항목이 있음")
        }

        // 임시 파일에 쓰고 → 검증 → 교체.
        let dir = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        let tmp = (dir as NSString).appendingPathComponent(".\(base).nfctmp-\(getpid())")
        do {
            try write(archive: archive, plans: plans, source: data, to: tmp)
            try verify(tmp, against: plans)
            try replace(original: path, with: tmp)
        } catch {
            unlink(tmp)
            throw error
        }
        result.changed = true
        return result
    }

    // MARK: - 모델

    private struct Entry {
        var cdRecord: [UInt8]       // 중앙 디렉터리 레코드 고정부 46바이트
        var name: [UInt8]
        var cdExtra: [UInt8]
        var comment: [UInt8]
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var compSize: UInt64
        var uncompSize: UInt64
        var localOffset: UInt64
        var localOffset32: UInt32   // 0xFFFFFFFF 이면 zip64 extra 안에 실제 오프셋이 있다
        var localHeader: [UInt8]    // 로컬 헤더 고정부 30바이트
        var localExtra: [UInt8]
        var dataRange: Range<Int>   // 압축 데이터 + 데이터 디스크립터 (바이트 그대로 복사할 구간)
    }

    private struct Archive {
        var entries: [Entry]
        var comment: [UInt8]
    }

    private struct EntryPlan {
        var entry: Entry
        var newName: [UInt8]
        var newFlags: UInt16
    }

    // MARK: - 파싱

    private static let sigLocal: UInt32 = 0x04034b50
    private static let sigCentral: UInt32 = 0x02014b50
    private static let sigEOCD: UInt32 = 0x06054b50
    private static let sigZip64EOCD: UInt32 = 0x06064b50
    private static let sigZip64Locator: UInt32 = 0x07064b50
    private static let sigDescriptor: UInt32 = 0x08074b50

    private static func parse(_ d: Data) throws -> Archive {
        let r = Reader(d)
        // EOCD: 뒤에서부터 검색 (코멘트 최대 65535).
        let minPos = max(0, r.count - 22 - 65535)
        var eocd = -1
        var p = r.count - 22
        while p >= minPos {
            if r.u32(p) == sigEOCD { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw ZipFixError.corrupt("EOCD 없음") }

        var diskNo = UInt32(r.u16(eocd + 4)), cdDisk = UInt32(r.u16(eocd + 6))
        var count = UInt64(r.u16(eocd + 10))
        var cdSize = UInt64(r.u32(eocd + 12))
        var cdOffset = UInt64(r.u32(eocd + 16))
        let commentLen = Int(r.u16(eocd + 20))
        let comment = r.bytes(eocd + 22, commentLen)

        // zip64
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF || diskNo == 0xFFFF {
            let loc = eocd - 20
            guard loc >= 0, r.u32(loc) == sigZip64Locator else { throw ZipFixError.corrupt("zip64 locator 없음") }
            let z = Int(r.u64(loc + 8))
            guard z >= 0, z + 56 <= r.count, r.u32(z) == sigZip64EOCD else { throw ZipFixError.corrupt("zip64 EOCD 없음") }
            diskNo = r.u32(z + 16); cdDisk = r.u32(z + 20)
            count = r.u64(z + 32)
            cdSize = r.u64(z + 40)
            cdOffset = r.u64(z + 48)
        }
        guard diskNo == 0, cdDisk == 0 else { throw ZipFixError.unsupported("분할 아카이브") }
        guard cdOffset + cdSize <= UInt64(eocd) else { throw ZipFixError.corrupt("중앙 디렉터리 범위") }

        var entries: [Entry] = []
        var pos = Int(cdOffset)
        for _ in 0..<count {
            guard pos + 46 <= r.count, r.u32(pos) == sigCentral else { throw ZipFixError.corrupt("중앙 디렉터리 레코드") }
            let flags = r.u16(pos + 8), method = r.u16(pos + 10)
            let crc = r.u32(pos + 16)
            let comp32 = r.u32(pos + 20), uncomp32 = r.u32(pos + 24)
            let nameLen = Int(r.u16(pos + 28)), extraLen = Int(r.u16(pos + 30)), cmtLen = Int(r.u16(pos + 32))
            let disk16 = r.u16(pos + 34)
            let off32 = r.u32(pos + 42)
            guard pos + 46 + nameLen + extraLen + cmtLen <= r.count else { throw ZipFixError.corrupt("중앙 디렉터리 길이") }
            let name = r.bytes(pos + 46, nameLen)
            let cdExtra = r.bytes(pos + 46 + nameLen, extraLen)
            let cmt = r.bytes(pos + 46 + nameLen + extraLen, cmtLen)

            var comp = UInt64(comp32), uncomp = UInt64(uncomp32), off = UInt64(off32), disk = UInt32(disk16)
            if let z64 = extraField(cdExtra, id: 0x0001) {
                var q = 0
                func take() -> UInt64? {
                    guard q + 8 <= z64.count else { return nil }
                    defer { q += 8 }
                    return le64(z64, q)
                }
                if uncomp32 == 0xFFFF_FFFF, let v = take() { uncomp = v }
                if comp32 == 0xFFFF_FFFF, let v = take() { comp = v }
                if off32 == 0xFFFF_FFFF, let v = take() { off = v }
                if disk16 == 0xFFFF, q + 4 <= z64.count { disk = le32(z64, q) }
            }
            guard disk == 0 else { throw ZipFixError.unsupported("분할 아카이브") }

            // 로컬 헤더
            let lo = Int(off)
            guard lo >= 0, lo + 30 <= Int(cdOffset), r.u32(lo) == sigLocal else { throw ZipFixError.corrupt("로컬 헤더 (\(String(decoding: name, as: UTF8.self)))") }
            let lNameLen = Int(r.u16(lo + 26)), lExtraLen = Int(r.u16(lo + 28))
            let localExtra = r.bytes(lo + 30 + lNameLen, lExtraLen)
            let dataStart = lo + 30 + lNameLen + lExtraLen
            var dataEnd = dataStart + Int(comp)
            if flags & 0x0008 != 0 {
                // 데이터 디스크립터: [시그니처 4]? + crc 4 + 크기 2개(로컬 zip64 extra 있으면 8, 아니면 4)
                let sizeLen = extraField(localExtra, id: 0x0001) != nil ? 8 : 4
                let hasSig = dataEnd + 4 <= r.count && r.u32(dataEnd) == sigDescriptor
                dataEnd += (hasSig ? 4 : 0) + 4 + 2 * sizeLen
            }
            guard dataStart <= dataEnd, dataEnd <= Int(cdOffset) else { throw ZipFixError.corrupt("데이터 범위 (\(String(decoding: name, as: UTF8.self)))") }

            entries.append(Entry(cdRecord: r.bytes(pos, 46), name: name, cdExtra: cdExtra, comment: cmt,
                                 flags: flags, method: method, crc: crc,
                                 compSize: comp, uncompSize: uncomp,
                                 localOffset: off, localOffset32: off32,
                                 localHeader: r.bytes(lo, 30), localExtra: localExtra,
                                 dataRange: dataStart..<dataEnd))
            pos += 46 + nameLen + extraLen + cmtLen
        }
        return Archive(entries: entries, comment: comment)
    }

    // MARK: - 쓰기

    private static func write(archive: Archive, plans: [EntryPlan], source: Data, to path: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let fh = FileHandle(forWritingAtPath: path) else { throw ZipFixError.io("임시 파일 생성 실패") }
        defer { fh.closeFile() }
        var out = Writer(fh)

        // 1) 로컬 헤더 + 데이터
        var newOffsets: [UInt64] = []
        for p in plans {
            let e = p.entry
            newOffsets.append(out.offset)
            var lh = e.localHeader
            put16(&lh, 6, p.newFlags)
            let lExtra = stripField(e.localExtra, id: 0x7075)
            put16(&lh, 26, UInt16(p.newName.count))
            put16(&lh, 28, UInt16(lExtra.count))
            out.write(lh); out.write(p.newName); out.write(lExtra)
            out.copy(source, e.dataRange)
        }

        // 2) 중앙 디렉터리
        let cdStart = out.offset
        for (i, p) in plans.enumerated() {
            let e = p.entry
            var cd = e.cdRecord
            var extra = stripField(e.cdExtra, id: 0x7075)
            put16(&cd, 8, p.newFlags)
            put16(&cd, 28, UInt16(p.newName.count))
            if e.localOffset32 == 0xFFFF_FFFF {
                // 실제 오프셋은 zip64 extra 안 — 그 자리를 갱신.
                extra = updatingZip64Offset(extra, entry: e, newOffset: newOffsets[i])
            } else {
                put32(&cd, 42, UInt32(newOffsets[i]))
            }
            put16(&cd, 30, UInt16(extra.count))
            out.write(cd); out.write(p.newName); out.write(extra); out.write(e.comment)
        }
        let cdSize = out.offset - cdStart
        let count = UInt64(plans.count)

        // 3) EOCD (+ zip64)
        let needZip64 = count >= 0xFFFF || cdSize >= 0xFFFF_FFFF || cdStart >= 0xFFFF_FFFF
        if needZip64 {
            let z64Pos = out.offset
            var z = [UInt8](); app32(&z, sigZip64EOCD); app64(&z, 44)
            app16(&z, 45); app16(&z, 45); app32(&z, 0); app32(&z, 0)
            app64(&z, count); app64(&z, count); app64(&z, cdSize); app64(&z, cdStart)
            out.write(z)
            var l = [UInt8](); app32(&l, sigZip64Locator); app32(&l, 0); app64(&l, z64Pos); app32(&l, 1)
            out.write(l)
        }
        var eocd = [UInt8](); app32(&eocd, sigEOCD); app16(&eocd, 0); app16(&eocd, 0)
        let c16 = UInt16(min(count, 0xFFFF))
        app16(&eocd, c16); app16(&eocd, c16)
        app32(&eocd, UInt32(min(cdSize, 0xFFFF_FFFF))); app32(&eocd, UInt32(min(cdStart, 0xFFFF_FFFF)))
        app16(&eocd, UInt16(archive.comment.count))
        out.write(eocd); out.write(archive.comment)
        out.flush()
    }

    /// 새로 쓴 파일을 다시 파싱해 기대한 항목·이름·플래그·CRC·크기와 일치하는지 확인한다.
    private static func verify(_ path: String, against plans: [EntryPlan]) throws {
        let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        let a = try parse(d)
        guard a.entries.count == plans.count else { throw ZipFixError.corrupt("검증: 항목 수 불일치") }
        for (got, p) in zip(a.entries, plans) {
            let e = p.entry
            guard got.name == p.newName, got.flags == p.newFlags, got.method == e.method,
                  got.crc == e.crc, got.compSize == e.compSize, got.uncompSize == e.uncompSize,
                  got.dataRange.count == e.dataRange.count else {
                throw ZipFixError.corrupt("검증: 항목 불일치 (\(String(decoding: p.newName, as: UTF8.self)))")
            }
        }
    }

    private static func replace(original: String, with tmp: String) throws {
        var st = stat()
        if stat(original, &st) == 0 { chmod(tmp, st.st_mode & 0o7777) }
        guard rename(tmp, original) == 0 else { throw ZipFixError.io("교체 실패 (errno \(errno))") }
    }

    // MARK: - extra field 유틸

    /// extra 영역에서 id 필드의 데이터를 찾는다.
    private static func extraField(_ extra: [UInt8], id: UInt16) -> [UInt8]? {
        var p = 0
        while p + 4 <= extra.count {
            let fid = le16(extra, p), len = Int(le16(extra, p + 2))
            guard p + 4 + len <= extra.count else { return nil }
            if fid == id { return Array(extra[(p + 4)..<(p + 4 + len)]) }
            p += 4 + len
        }
        return nil
    }

    /// id 필드를 제거한 extra 를 돌려준다.
    private static func stripField(_ extra: [UInt8], id: UInt16) -> [UInt8] {
        var out = [UInt8](); var p = 0
        while p + 4 <= extra.count {
            let fid = le16(extra, p), len = Int(le16(extra, p + 2))
            guard p + 4 + len <= extra.count else { out.append(contentsOf: extra[p...]); return out }
            if fid != id { out.append(contentsOf: extra[p..<(p + 4 + len)]) }
            p += 4 + len
        }
        return out
    }

    /// 중앙 디렉터리 zip64 extra(0x0001) 안의 로컬 헤더 오프셋 자리를 새 값으로 바꾼다.
    private static func updatingZip64Offset(_ extra: [UInt8], entry e: Entry, newOffset: UInt64) -> [UInt8] {
        var out = extra; var p = 0
        while p + 4 <= out.count {
            let fid = le16(out, p), len = Int(le16(out, p + 2))
            guard p + 4 + len <= out.count else { break }
            if fid == 0x0001 {
                var q = p + 4
                if le32(e.cdRecord, 24) == 0xFFFF_FFFF { q += 8 }   // uncompressed
                if le32(e.cdRecord, 20) == 0xFFFF_FFFF { q += 8 }   // compressed
                if q + 8 <= p + 4 + len { put64(&out, q, newOffset) }
                break
            }
            p += 4 + len
        }
        return out
    }

    // MARK: - 바이트 유틸

    private struct Reader {
        let d: Data; let base: Int; let count: Int
        init(_ d: Data) { self.d = d; base = d.startIndex; count = d.count }
        func u16(_ p: Int) -> UInt16 { UInt16(d[base + p]) | UInt16(d[base + p + 1]) << 8 }
        func u32(_ p: Int) -> UInt32 { UInt32(u16(p)) | UInt32(u16(p + 2)) << 16 }
        func u64(_ p: Int) -> UInt64 { UInt64(u32(p)) | UInt64(u32(p + 4)) << 32 }
        func bytes(_ p: Int, _ n: Int) -> [UInt8] { n > 0 ? [UInt8](d[(base + p)..<(base + p + n)]) : [] }
    }

    private struct Writer {
        let fh: FileHandle
        var offset: UInt64 = 0
        private var buf = [UInt8]()
        init(_ fh: FileHandle) { self.fh = fh }
        mutating func write(_ b: [UInt8]) {
            buf.append(contentsOf: b); offset += UInt64(b.count)
            if buf.count >= 1 << 20 { flush() }
        }
        mutating func copy(_ src: Data, _ range: Range<Int>) {
            flush()
            let base = src.startIndex
            var p = range.lowerBound
            while p < range.upperBound {
                let n = min(4 << 20, range.upperBound - p)
                fh.write(src.subdata(in: (base + p)..<(base + p + n)))
                p += n
            }
            offset += UInt64(range.count)
        }
        mutating func flush() {
            if !buf.isEmpty { fh.write(Data(buf)); buf.removeAll(keepingCapacity: true) }
        }
    }

    private static func le16(_ b: [UInt8], _ p: Int) -> UInt16 { UInt16(b[p]) | UInt16(b[p + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ p: Int) -> UInt32 { UInt32(le16(b, p)) | UInt32(le16(b, p + 2)) << 16 }
    private static func le64(_ b: [UInt8], _ p: Int) -> UInt64 { UInt64(le32(b, p)) | UInt64(le32(b, p + 4)) << 32 }
    private static func put16(_ b: inout [UInt8], _ p: Int, _ v: UInt16) { b[p] = UInt8(v & 0xff); b[p + 1] = UInt8(v >> 8) }
    private static func put32(_ b: inout [UInt8], _ p: Int, _ v: UInt32) { put16(&b, p, UInt16(v & 0xffff)); put16(&b, p + 2, UInt16(v >> 16)) }
    private static func put64(_ b: inout [UInt8], _ p: Int, _ v: UInt64) { put32(&b, p, UInt32(v & 0xffff_ffff)); put32(&b, p + 4, UInt32(v >> 32)) }
    private static func app16(_ b: inout [UInt8], _ v: UInt16) { b.append(UInt8(v & 0xff)); b.append(UInt8(v >> 8)) }
    private static func app32(_ b: inout [UInt8], _ v: UInt32) { app16(&b, UInt16(v & 0xffff)); app16(&b, UInt16(v >> 16)) }
    private static func app64(_ b: inout [UInt8], _ v: UInt64) { app32(&b, UInt32(v & 0xffff_ffff)); app32(&b, UInt32(v >> 32)) }
}
