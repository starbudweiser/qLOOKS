// qLOOKS — contenu d'un dossier ou d'une archive (zip, tar, tar.gz, gz) sous forme d'arbre ; rien n'est décompressé sur le disque.
import Foundation
import zlib

final class TreeNode {
    let name: String
    let isDir: Bool
    var size: Int64
    var children: [TreeNode]
    private var loader: (() -> [TreeNode])?
    let url: URL?

    init(name: String, isDir: Bool, size: Int64 = 0, children: [TreeNode] = [], url: URL? = nil, loader: (() -> [TreeNode])? = nil) {
        self.name = name; self.isDir = isDir; self.size = size; self.children = children; self.url = url; self.loader = loader
    }

    /// Enfants triés : dossiers d'abord, puis par nom ; un dossier de disque est lu au premier accès.
    var kids: [TreeNode] {
        if let l = loader { children = l(); loader = nil }
        return children
    }
    var hasKids: Bool { isDir && (loader != nil || !children.isEmpty) }

    static func sorted(_ nodes: [TreeNode]) -> [TreeNode] {
        nodes.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct Listing {
    var roots: [TreeNode]
    var fileCount = 0
    var dirCount = 0
    var totalSize: Int64 = 0
    var partial = false
    var note: String?
}

enum ArchiveError: Error { case unreadable, unsupported }

enum Archives {
    static func kind(of url: URL) -> String? {
        let n = url.lastPathComponent.lowercased()
        if n.hasSuffix(".tar.gz") || n.hasSuffix(".tgz") { return "tgz" }
        switch url.pathExtension.lowercased() {
        case "zip", "jar", "apk", "epub", "ipa", "docx", "xlsx", "pptx": return "zip"
        case "tar": return "tar"
        case "gz": return "gz"
        case "rar": return "rar"
        case "7z": return "7z"
        case "dmg": return "dmg"
        default: return nil
        }
    }

    static func listing(for url: URL) throws -> Listing {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return folder(url)
        }
        switch kind(of: url) {
        case "zip": return try zip(url)
        case "tar": return try tar(url, gzip: false)
        case "tgz": return try tar(url, gzip: true)
        case "gz": return try gz(url)
        case "rar": return try rar(url)
        case "7z": return try sevenZip(url)
        case "dmg": return try dmg(url)
        default: throw ArchiveError.unsupported
        }
    }

    // MARK: Dossier

    private static func folder(_ url: URL) -> Listing {
        func load(_ dir: URL) -> [TreeNode] {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isPackageKey]
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return TreeNode.sorted(items.map { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                let d = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
                return TreeNode(name: u.lastPathComponent, isDir: d, size: Int64(v?.fileSize ?? 0), url: u, loader: d ? { load(u) } : nil)
            })
        }
        let top = load(url)
        var l = Listing(roots: top)
        for n in top { if n.isDir { l.dirCount += 1 } else { l.fileCount += 1; l.totalSize += n.size } }
        return l
    }

    // MARK: Construction d'un arbre à partir de chemins

    private struct Builder {
        var root = TreeNode(name: "", isDir: true)
        var files = 0, dirs = 0
        var total: Int64 = 0

        mutating func add(path: String, size: Int64, isDir: Bool) {
            let parts = path.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
            guard !parts.isEmpty, parts.first != "__MACOSX", parts.last != ".DS_Store" else { return }
            var node = root
            for (i, p) in parts.enumerated() {
                let last = i == parts.count - 1
                if let c = node.children.first(where: { $0.name == p }) {
                    node = c
                    if last, !isDir { c.size = size }
                } else {
                    let dir = !last || isDir
                    let c = TreeNode(name: p, isDir: dir, size: dir ? 0 : size)
                    node.children.append(c)
                    if dir { dirs += 1 } else { files += 1; total += size }
                    node = c
                }
            }
        }

        func finish() -> Listing {
            func sort(_ n: TreeNode) {
                n.children = TreeNode.sorted(n.children)
                for c in n.children where c.isDir { sort(c) }
            }
            func sum(_ n: TreeNode) -> Int64 {
                if !n.isDir { return n.size }
                n.size = n.children.reduce(0) { $0 + sum($1) }
                return n.size
            }
            sort(root); _ = sum(root)
            return Listing(roots: root.children, fileCount: files, dirCount: dirs, totalSize: total)
        }
    }

    // MARK: Zip

    private static func zip(_ url: URL) throws -> Listing {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw ArchiveError.unreadable }
        defer { try? fh.close() }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        let tailLen = min(fileSize, 70_000)
        try fh.seek(toOffset: fileSize - tailLen)
        guard let tail = try fh.read(upToCount: Int(tailLen)), tail.count >= 22 else { throw ArchiveError.unreadable }
        let t = [UInt8](tail)
        func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ b: [UInt8], _ i: Int) -> UInt64 { (0..<4).reduce(0) { $0 | UInt64(b[i + $1]) << (8 * UInt64($1)) } }
        func u64(_ b: [UInt8], _ i: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(b[i + $1]) << (8 * UInt64($1)) } }
        var eocd = -1
        var i = t.count - 22
        while i >= 0 { if t[i] == 0x50, t[i + 1] == 0x4B, t[i + 2] == 5, t[i + 3] == 6 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { throw ArchiveError.unreadable }
        var count = UInt64(u16(t, eocd + 10)), cdSize = u32(t, eocd + 12), cdOff = u32(t, eocd + 16)
        if eocd >= 20, t[eocd - 20] == 0x50, t[eocd - 19] == 0x4B, t[eocd - 18] == 6, t[eocd - 17] == 7 {   // zip64
            let off64 = u64(t, eocd - 20 + 8)
            try fh.seek(toOffset: off64)
            if let rec = try fh.read(upToCount: 56), rec.count >= 56 {
                let r = [UInt8](rec)
                count = u64(r, 32); cdSize = u64(r, 40); cdOff = u64(r, 48)
            }
        }
        guard cdSize < 1 << 30, cdOff < fileSize else { throw ArchiveError.unreadable }
        try fh.seek(toOffset: cdOff)
        guard let cdData = try fh.read(upToCount: Int(cdSize)) else { throw ArchiveError.unreadable }
        let cd = [UInt8](cdData)
        var b = Builder()
        var p = 0
        var n: UInt64 = 0
        while p + 46 <= cd.count, n < min(count, 200_000), u32(cd, p) == 0x02014B50 {
            let flags = u16(cd, p + 8)
            var usize = u32(cd, p + 24)
            let nl = u16(cd, p + 28), el = u16(cd, p + 30), cl = u16(cd, p + 32)
            guard p + 46 + nl + el <= cd.count else { break }
            let nameBytes = Array(cd[(p + 46)..<(p + 46 + nl)])
            if usize == 0xFFFF_FFFF {                                              // taille zip64 dans le champ supplémentaire
                var q = p + 46 + nl; let endx = q + el
                while q + 4 <= endx {
                    let id = u16(cd, q), sz = u16(cd, q + 2)
                    if id == 1, sz >= 8 { usize = u64(cd, q + 4); break }
                    q += 4 + sz
                }
            }
            var name = String(bytes: nameBytes, encoding: .utf8)
            if name == nil || flags & 0x800 == 0 { name = name ?? String(bytes: nameBytes, encoding: .isoLatin1) }
            let path = name ?? ""
            b.add(path: path, size: Int64(usize), isDir: path.hasSuffix("/"))
            p += 46 + nl + el + cl
            n += 1
        }
        var l = b.finish()
        l.partial = n < count
        return l
    }

    // MARK: Flux (tar, tar.gz)

    private protocol Stream { mutating func read(_ n: Int) -> [UInt8]; mutating func skip(_ n: Int) -> Bool }

    private struct PlainStream: Stream {
        let fh: FileHandle
        mutating func read(_ n: Int) -> [UInt8] { [UInt8]((try? fh.read(upToCount: n)) ?? Data()) }
        mutating func skip(_ n: Int) -> Bool {
            guard let pos = try? fh.offset(), (try? fh.seek(toOffset: pos + UInt64(n))) != nil else { return false }
            return true
        }
    }

    /// Décompression gzip en continu ; on lit avant tout les en-têtes, le reste est jeté.
    private final class GzStream: Stream {
        let fh: FileHandle
        var zs = z_stream()
        var inBuf = [UInt8](repeating: 0, count: 1 << 16)
        var pending: [UInt8] = []
        var done = false
        var produced: Int64 = 0
        let limit: Int64
        var truncated = false
        init(fh: FileHandle, limit: Int64) {
            self.fh = fh; self.limit = limit
            inflateInit2_(&zs, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        }
        deinit { inflateEnd(&zs) }

        private func fill(_ want: Int) {
            var out = [UInt8](repeating: 0, count: 1 << 16)
            while pending.count < want, !done {
                if zs.avail_in == 0 {
                    guard let d = try? fh.read(upToCount: inBuf.count), !d.isEmpty else { done = true; return }
                    inBuf.replaceSubrange(0..<d.count, with: d)
                    zs.avail_in = UInt32(d.count)
                    inBuf.withUnsafeMutableBufferPointer { zs.next_in = $0.baseAddress }
                }
                var got = 0
                let rc: Int32 = out.withUnsafeMutableBufferPointer { ob in
                    zs.next_out = ob.baseAddress; zs.avail_out = UInt32(ob.count)
                    let r = inflate(&zs, Z_NO_FLUSH)
                    got = ob.count - Int(zs.avail_out)
                    return r
                }
                if got > 0 { pending.append(contentsOf: out[0..<got]); produced += Int64(got) }
                if rc == Z_STREAM_END {
                    // membres gzip concaténés
                    if zs.avail_in > 0 || ((try? fh.read(upToCount: 1))?.isEmpty == false) { _ = inflateReset(&zs); zs.avail_in = 0 } else { done = true }
                } else if rc != Z_OK, rc != Z_BUF_ERROR { done = true }
                if produced > limit { truncated = true; done = true }
            }
        }
        func read(_ n: Int) -> [UInt8] {
            fill(n)
            let k = min(n, pending.count)
            let r = Array(pending[0..<k]); pending.removeFirst(k)
            return r
        }
        func skip(_ n: Int) -> Bool {
            var left = n
            while left > 0 {
                fill(min(left, 1 << 16))
                if pending.isEmpty { return false }
                let k = min(left, pending.count)
                pending.removeFirst(k); left -= k
            }
            return true
        }
    }

    private static func tar(_ url: URL, gzip: Bool) throws -> Listing {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw ArchiveError.unreadable }
        defer { try? fh.close() }
        var s: Stream
        var gz: GzStream?
        if gzip { let g = GzStream(fh: fh, limit: 3 << 30); gz = g; s = g } else { s = PlainStream(fh: fh) }
        var b = Builder()
        var longName: String?
        var entries = 0
        func oct(_ h: [UInt8], _ at: Int, _ len: Int) -> Int64 {
            if h[at] & 0x80 != 0 { return (1..<len).reduce(Int64(0)) { $0 << 8 | Int64(h[at + $1]) } }       // base 256
            let str = String(decoding: h[at..<(at + len)].prefix { $0 != 0 && $0 != 32 }, as: UTF8.self)
            return Int64(str.trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
        }
        func cstr(_ h: [UInt8], _ at: Int, _ len: Int) -> String { String(decoding: h[at..<(at + len)].prefix { $0 != 0 }, as: UTF8.self) }
        var partial = false
        while entries < 200_000 {
            let h = s.read(512)
            if h.count < 512 { partial = h.count > 0 && gz?.truncated == true; break }
            if h.allSatisfy({ $0 == 0 }) { break }
            let type = h[156]
            var size = oct(h, 124, 12)
            var name = cstr(h, 0, 100)
            if cstr(h, 257, 5) == "ustar" { let pre = cstr(h, 345, 155); if !pre.isEmpty { name = pre + "/" + name } }
            let padded = Int((size + 511) / 512 * 512)
            if type == 0x4C {                                                          // 'L' : nom long GNU
                let d = s.read(padded)
                longName = String(decoding: d.prefix(Int(size)).prefix { $0 != 0 }, as: UTF8.self)
                continue
            }
            if type == 0x78 || type == 0x67 {                                          // pax : clé path=
                let d = s.read(padded)
                let text = String(decoding: d.prefix(Int(size)), as: UTF8.self)
                for line in text.split(separator: "\n") {
                    if let r = line.range(of: " path=") { longName = String(line[r.upperBound...]) }
                }
                continue
            }
            if let l = longName { name = l; longName = nil }
            let isDir = type == 0x35 || name.hasSuffix("/")
            if type == 0x30 || type == 0 || isDir || type == 0x32 { b.add(path: name, size: isDir ? 0 : size, isDir: isDir); entries += 1 }
            if type == 0x32 { size = 0 }                                               // lien symbolique : pas de données
            if !s.skip(padded) { partial = gz?.truncated == true; break }
        }
        var l = b.finish()
        l.partial = partial || entries >= 200_000
        return l
    }

    private static func gz(_ url: URL) throws -> Listing {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw ArchiveError.unreadable }
        defer { try? fh.close() }
        // Fichier .gz seul : nom d'origine sans l'extension, taille lue dans les 4 derniers octets (modulo 2^32).
        let end = (try? fh.seekToEnd()) ?? 0
        guard end >= 18 else { throw ArchiveError.unreadable }
        try fh.seek(toOffset: end - 4)
        let t = [UInt8]((try? fh.read(upToCount: 4)) ?? Data())
        guard t.count == 4 else { throw ArchiveError.unreadable }
        let size = (0..<4).reduce(Int64(0)) { $0 | Int64(t[$1]) << (8 * Int64($1)) }
        var b = Builder()
        b.add(path: url.deletingPathExtension().lastPathComponent, size: size, isDir: false)
        return b.finish()
    }

    // MARK: Lecture d'octets

    private static func head(_ fh: FileHandle, at off: UInt64, _ n: Int) -> [UInt8] {
        guard (try? fh.seek(toOffset: off)) != nil else { return [] }
        return [UInt8]((try? fh.read(upToCount: n)) ?? Data())
    }
    private static func le(_ b: [UInt8], _ i: Int, _ n: Int) -> UInt64 {
        guard i + n <= b.count else { return 0 }
        return (0..<n).reduce(0) { $0 | UInt64(b[i + $1]) << (8 * UInt64($1)) }
    }
    private static func be(_ b: [UInt8], _ i: Int, _ n: Int) -> UInt64 {
        guard i + n <= b.count else { return 0 }
        return (0..<n).reduce(0) { $0 << 8 | UInt64(b[i + $1]) }
    }

    // MARK: RAR (3/4 et 5) : en-têtes seulement, rien n'est décompressé

    private static func rar(_ url: URL) throws -> Listing {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw ArchiveError.unreadable }
        defer { try? fh.close() }
        let end = (try? fh.seekToEnd()) ?? 0
        let sig = head(fh, at: 0, 8)
        var b = Builder()
        var count = 0
        if sig.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01]) {
            var pos: UInt64 = 8
            while pos + 8 < end, count < 200_000 {
                let buf = head(fh, at: pos, 4096)
                guard buf.count > 8 else { break }
                func vint(_ i: inout Int) -> UInt64 {
                    var r: UInt64 = 0, sh: UInt64 = 0
                    while i < buf.count { let c = buf[i]; i += 1; r |= UInt64(c & 0x7F) << sh; if c & 0x80 == 0 { break }; sh += 7; if sh > 63 { break } }
                    return r
                }
                var i = 4
                let hsize = vint(&i)
                let afterSize = i
                let type = vint(&i), flags = vint(&i)
                if type == 4 { throw ArchiveError.unreadable }                          // en-têtes chiffrés
                if flags & 1 != 0 { _ = vint(&i) }
                let dataSize = flags & 2 != 0 ? vint(&i) : 0
                if type == 2 {
                    let ff = vint(&i)
                    let usize = vint(&i)
                    _ = vint(&i)                                                       // attributs
                    if ff & 2 != 0 { i += 4 }
                    if ff & 4 != 0 { i += 4 }
                    _ = vint(&i); _ = vint(&i)
                    let nl = Int(vint(&i))
                    if i + nl <= buf.count {
                        let name = String(decoding: buf[i..<(i + nl)], as: UTF8.self)
                        let isDir = ff & 1 != 0
                        b.add(path: name, size: Int64(usize), isDir: isDir); count += 1
                    }
                }
                if type == 5 { break }
                pos += UInt64(afterSize) + hsize + dataSize
            }
        } else if sig.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]) {
            var pos: UInt64 = 7
            while pos + 7 < end, count < 200_000 {
                let h = head(fh, at: pos, 32 + 4096)
                guard h.count >= 7 else { break }
                let type = h[2], flags = Int(le(h, 3, 2)), hsize = Int(le(h, 5, 2))
                guard hsize >= 7 else { break }
                if type == 0x73, flags & 0x80 != 0 { throw ArchiveError.unreadable }    // en-têtes chiffrés
                var add = flags & 0x8000 != 0 ? le(h, 7, 4) : 0
                if type == 0x74 {
                    add = le(h, 7, 4)
                    var usize = le(h, 11, 4)
                    let nl = Int(le(h, 26, 2))
                    var o = 32
                    if flags & 0x100 != 0 { add |= le(h, 32, 4) << 32; usize |= le(h, 36, 4) << 32; o = 40 }
                    if o + nl <= h.count {
                        var raw = Array(h[o..<(o + nl)])
                        if flags & 0x200 != 0, let z = raw.firstIndex(of: 0) { raw = Array(raw[0..<z]) }
                        let name = (String(bytes: raw, encoding: .utf8) ?? String(bytes: raw, encoding: .isoLatin1) ?? "").replacingOccurrences(of: "\\", with: "/")
                        b.add(path: name, size: Int64(usize), isDir: flags & 0xE0 == 0xE0); count += 1
                    }
                }
                if type == 0x7B { break }
                pos += UInt64(hsize) + add
            }
        } else { throw ArchiveError.unreadable }
        return b.finish()
    }

    // MARK: 7z

    private struct SZReader {
        let b: [UInt8]
        var p = 0
        init(_ b: [UInt8]) { self.b = b }
        mutating func byte() throws -> UInt8 { guard p < b.count else { throw ArchiveError.unreadable }; defer { p += 1 }; return b[p] }
        mutating func num() throws -> UInt64 {
            let first = try byte()
            var mask: UInt8 = 0x80, v: UInt64 = 0
            for i in 0..<8 {
                if first & mask == 0 { return v | UInt64(first & (mask &- 1)) << (8 * UInt64(i)) }
                v |= UInt64(try byte()) << (8 * UInt64(i))
                mask >>= 1
            }
            return v
        }
        mutating func skip(_ n: Int) throws { guard n >= 0, p + n <= b.count else { throw ArchiveError.unreadable }; p += n }
        mutating func bits(_ n: Int) throws -> [Bool] {
            var r: [Bool] = []; var cur: UInt8 = 0
            for i in 0..<n { if i % 8 == 0 { cur = try byte() }; r.append(cur & (0x80 >> UInt8(i % 8)) != 0) }
            return r
        }
        mutating func defined(_ n: Int) throws -> [Bool] {
            let all = try byte()
            return all != 0 ? [Bool](repeating: true, count: n) : try bits(n)
        }
    }

    private struct SZFolder { var crcDefined = false; var coders: [(id: [UInt8], props: [UInt8], nOut: Int)] = []; var unpack: [UInt64] = []; var packIndices: [Int] = [] }

    private struct SZStreams {
        var packPos: UInt64 = 0
        var packSizes: [UInt64] = []
        var folders: [SZFolder] = []
        var subCounts: [Int] = []
        var subSizes: [UInt64] = []
        var folderSize: (SZFolder) -> UInt64 = { $0.unpack.last ?? 0 }
    }

    private static func szStreams(_ r: inout SZReader) throws -> SZStreams {
        var s = SZStreams()
        func skipDigests(_ r: inout SZReader, _ n: Int) throws {
            let d = try r.defined(n)
            for x in d where x { try r.skip(4) }
        }
        while true {
            let id = try r.byte()
            switch id {
            case 0x00: return s
            case 0x06:
                s.packPos = try r.num()
                let n = Int(try r.num())
                while true {
                    let t = try r.byte()
                    if t == 0 { break }
                    if t == 9 { for _ in 0..<n { s.packSizes.append(try r.num()) } }
                    else if t == 10 { try skipDigests(&r, n) }
                    else { throw ArchiveError.unreadable }
                }
            case 0x07:
                guard try r.byte() == 0x0B else { throw ArchiveError.unreadable }
                let nf = Int(try r.num())
                guard try r.byte() == 0 else { throw ArchiveError.unreadable }
                for _ in 0..<nf {
                    var f = SZFolder()
                    let nc = Int(try r.num())
                    var totalIn = 0, totalOut = 0
                    for _ in 0..<nc {
                        let flag = try r.byte()
                        let idLen = Int(flag & 0xF)
                        var id: [UInt8] = []; for _ in 0..<idLen { id.append(try r.byte()) }
                        var nIn = 1, nOut = 1
                        if flag & 0x10 != 0 { nIn = Int(try r.num()); nOut = Int(try r.num()) }
                        var props: [UInt8] = []
                        if flag & 0x20 != 0 { let n = Int(try r.num()); for _ in 0..<n { props.append(try r.byte()) } }
                        f.coders.append((id, props, nOut)); totalIn += nIn; totalOut += nOut
                    }
                    let nb = totalOut - 1
                    for _ in 0..<nb { _ = try r.num(); _ = try r.num() }
                    let np = totalIn - nb
                    if np > 1 { for _ in 0..<np { f.packIndices.append(Int(try r.num())) } }
                    f.unpack = []
                    s.folders.append(f)
                }
                guard try r.byte() == 0x0C else { throw ArchiveError.unreadable }
                for i in 0..<nf {
                    let outs = s.folders[i].coders.reduce(0) { $0 + $1.nOut }
                    for _ in 0..<outs { s.folders[i].unpack.append(try r.num()) }
                }
                while true {
                    let t = try r.byte()
                    if t == 0 { break }
                    if t == 0x0A {
                        let d = try r.defined(nf)
                        for (i, x) in d.enumerated() where x { try r.skip(4); s.folders[i].crcDefined = true }
                    } else { throw ArchiveError.unreadable }
                }
            case 0x08:
                s.subCounts = s.folders.map { _ in 1 }
                var t = try r.byte()
                if t == 0x0D { s.subCounts = []; for _ in s.folders { s.subCounts.append(Int(try r.num())) }; t = try r.byte() }
                if t == 0x09 {
                    for (i, f) in s.folders.enumerated() {
                        var sum: UInt64 = 0
                        let n = s.subCounts[i]
                        if n == 0 { continue }
                        for _ in 0..<(n - 1) { let v = try r.num(); s.subSizes.append(v); sum += v }
                        s.subSizes.append((f.unpack.last ?? 0) &- sum)
                    }
                    t = try r.byte()
                } else {
                    for (i, f) in s.folders.enumerated() where s.subCounts[i] == 1 { s.subSizes.append(f.unpack.last ?? 0) }
                }
                while t != 0 {
                    if t == 0x0A {
                        // résumés : un par flux dont la somme n'est pas déjà connue
                        var n = 0
                        for (i, f) in s.folders.enumerated() { n += (s.subCounts[i] == 1 && f.crcDefined) ? 0 : s.subCounts[i] }
                        try skipDigests(&r, n)
                    } else { throw ArchiveError.unreadable }
                    t = try r.byte()
                }
            default: throw ArchiveError.unreadable
            }
        }
    }

    private static func sevenZip(_ url: URL) throws -> Listing {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw ArchiveError.unreadable }
        defer { try? fh.close() }
        let sh = head(fh, at: 0, 32)
        guard sh.count == 32, sh.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) else { throw ArchiveError.unreadable }
        let off = le(sh, 12, 8), size = le(sh, 20, 8)
        guard size > 0, size < 1 << 28 else { throw ArchiveError.unreadable }
        var hdr = head(fh, at: 32 + off, Int(size))
        guard hdr.count == Int(size) else { throw ArchiveError.unreadable }
        var rounds = 0
        while hdr.first == 0x17, rounds < 3 {                                           // en-tête compressé
            rounds += 1
            var r = SZReader(hdr); r.p = 1
            let st = try szStreams(&r)
            guard let f = st.folders.first, let c = f.coders.first, st.packSizes.count >= 1 else { throw ArchiveError.unsupported }
            let packed = head(fh, at: 32 + st.packPos, Int(st.packSizes[0]))
            let outSize = Int(f.unpack.last ?? 0)
            if c.id == [0x03, 0x01, 0x01], f.coders.count == 1 {
                guard let d = LZMA.decode(props: c.props, input: packed, outSize: outSize) else { throw ArchiveError.unreadable }
                hdr = d
            } else if c.id == [0x00], f.coders.count == 1 { hdr = packed }
            else { throw ArchiveError.unsupported }
        }
        guard hdr.first == 0x01 else { throw ArchiveError.unreadable }
        var r = SZReader(hdr); r.p = 1
        var streams = SZStreams()
        var b = Builder()
        loop: while true {
            let id = try r.byte()
            switch id {
            case 0x00: break loop
            case 0x02: while true { let t = try r.byte(); if t == 0 { break }; try r.skip(Int(try r.num())) }
            case 0x03: _ = try szStreams(&r)
            case 0x04: streams = try szStreams(&r)
            case 0x05:
                let n = Int(try r.num())
                guard n < 1_000_000 else { throw ArchiveError.unreadable }
                var names: [String] = []
                var emptyStream = [Bool](repeating: false, count: n)
                var emptyFile: [Bool] = []
                while true {
                    let t = try r.byte()
                    if t == 0 { break }
                    let sz = Int(try r.num())
                    let endP = r.p + sz
                    switch t {
                    case 0x11:
                        _ = try r.byte()
                        var cur: [UInt16] = []
                        while r.p + 1 < endP + 0, names.count < n {
                            let u = UInt16(try r.byte()) | UInt16(try r.byte()) << 8
                            if u == 0 { names.append(String(decoding: cur, as: UTF16.self)); cur = [] } else { cur.append(u) }
                        }
                    case 0x0E: emptyStream = try r.bits(n)
                    case 0x0F: emptyFile = try r.bits(emptyStream.filter { $0 }.count)
                    default: break
                    }
                    r.p = endP
                }
                var si = 0, ei = 0
                for i in 0..<min(n, names.count) {
                    if emptyStream[i] {
                        let isFile = ei < emptyFile.count && emptyFile[ei]; ei += 1
                        b.add(path: names[i], size: 0, isDir: !isFile)
                    } else {
                        let sz = si < streams.subSizes.count ? streams.subSizes[si] : 0; si += 1
                        b.add(path: names[i], size: Int64(sz), isDir: false)
                    }
                }
            default: break loop
            }
        }
        return b.finish()
    }

    // MARK: DMG : description du disque (les fichiers ne sont lisibles qu'une fois l'image montée)

    private static func dmg(_ url: URL) throws -> Listing {
        guard let disk = UDIFDisk(url: url) else { throw ArchiveError.unsupported }
        func tree(_ entries: [VolEntry], rootParent: UInt64) -> [TreeNode] {
            var kids: [UInt64: [VolEntry]] = [:]
            for e in entries where !e.name.hasPrefix(".") && !e.name.hasPrefix("\u{0}") { kids[e.parent, default: []].append(e) }
            func build(_ e: VolEntry, _ depth: Int) -> TreeNode {
                if e.isDir, depth < 24 {
                    let c = TreeNode.sorted((kids[e.id] ?? []).map { build($0, depth + 1) })
                    return TreeNode(name: e.name, isDir: true, size: c.reduce(0) { $0 + $1.size }, children: c)
                }
                return TreeNode(name: e.name, isDir: e.isDir, size: e.size)
            }
            return TreeNode.sorted((kids[rootParent] ?? []).map { build($0, 0) })
        }
        var roots: [TreeNode] = []
        var seen = Set<UInt64>()
        for p in disk.partitions where p.sectors > 64 {
            guard seen.insert(p.start).inserted else { continue }
            let vol = DiskVolume(disk: disk, base: p.start * 512)
            if let e = HFSPlus.entries(vol) {
                let t = tree(e, rootParent: 2)
                roots += t
            } else if let vols = APFS.volumes(vol) {
                if vols.count == 1 { roots += tree(vols[0].entries, rootParent: 2) }
                else { for v in vols { let t = tree(v.entries, rootParent: 2); roots.append(TreeNode(name: v.name, isDir: true, size: t.reduce(0) { $0 + $1.size }, children: t)) } }
            }
        }
        if roots.isEmpty { return try dmgPartitions(url) }
        var l = Listing(roots: TreeNode.sorted(roots))
        func count(_ ns: [TreeNode]) { for n in ns { if n.isDir { l.dirCount += 1; count(n.children) } else { l.fileCount += 1; l.totalSize += n.size } } }
        count(l.roots)
        return l
    }

    private static func dmgPartitions(_ url: URL) throws -> Listing {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw ArchiveError.unreadable }
        defer { try? fh.close() }
        let end = (try? fh.seekToEnd()) ?? 0
        guard end > 512 else { throw ArchiveError.unreadable }
        let k = head(fh, at: end - 512, 512)
        guard k.starts(with: Array("koly".utf8)) else { throw ArchiveError.unsupported }
        let xmlOff = be(k, 0xD8, 8), xmlLen = be(k, 0xE0, 8)
        guard xmlLen > 0, xmlLen < 1 << 26 else { throw ArchiveError.unreadable }
        let xml = Data(head(fh, at: xmlOff, Int(xmlLen)))
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil) as? [String: Any],
              let rs = plist["resource-fork"] as? [String: Any], let blkx = rs["blkx"] as? [[String: Any]] else { throw ArchiveError.unreadable }
        var b = Builder()
        for e in blkx {
            var name = (e["Name"] as? String) ?? ""
            if name.trimmingCharacters(in: .whitespaces).isEmpty { name = (e["CFName"] as? String) ?? "?" }
            name = name.trimmingCharacters(in: .whitespaces)
            if ["Apple_Free", "GPT", "MBR", "Protective", "Driver Descriptor", "partition_map"].contains(where: { name.contains($0) }) { continue }
            var bytes: Int64 = 0
            if let d = e["Data"] as? Data, d.count >= 0x28, String(decoding: d.prefix(4), as: UTF8.self) == "mish" {
                let a = [UInt8](d)
                bytes = Int64(be(a, 0x10, 8)) * 512                                     // nombre de secteurs
            }
            b.add(path: name, size: bytes, isDir: false)
        }
        var l = b.finish()
        l.note = "dmg"
        return l
    }
}
