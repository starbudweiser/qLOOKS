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
}
