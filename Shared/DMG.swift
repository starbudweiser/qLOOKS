// qLOOKS — contenu d'une image disque .dmg (UDIF) : lecture des blocs, puis des volumes HFS+ et APFS ; rien n'est monté.
import Compression
import Foundation
import zlib

/// Disque virtuel d'une image UDIF : accès à n'importe quel octet, blocs décompressés à la demande.
final class UDIFDisk {
    struct Chunk { let type: UInt32; let start: UInt64; let count: UInt64; let fileOff: UInt64; let fileLen: UInt64 }
    struct Partition { let name: String; let start: UInt64; let sectors: UInt64 }

    private let fh: FileHandle
    private(set) var chunks: [Chunk] = []
    private(set) var partitions: [Partition] = []
    private var cache: [Int: [UInt8]] = [:]
    private var order: [Int] = []
    private let lock = NSLock()

    private static func be(_ b: [UInt8], _ i: Int, _ n: Int) -> UInt64 {
        guard i + n <= b.count else { return 0 }
        return (0..<n).reduce(0) { $0 << 8 | UInt64(b[i + $1]) }
    }

    init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        fh = h
        guard let end = try? h.seekToEnd(), end > 512, (try? h.seek(toOffset: end - 512)) != nil,
              let kd = try? h.read(upToCount: 512), kd.count == 512 else { return nil }
        let k = [UInt8](kd)
        guard k.starts(with: Array("koly".utf8)) else { return nil }
        let dataFork = Self.be(k, 0x18, 8), xmlOff = Self.be(k, 0xD8, 8), xmlLen = Self.be(k, 0xE0, 8)
        guard xmlLen > 0, xmlLen < 1 << 26, (try? h.seek(toOffset: xmlOff)) != nil, let xml = try? h.read(upToCount: Int(xmlLen)),
              let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil) as? [String: Any],
              let rs = plist["resource-fork"] as? [String: Any], let blkx = rs["blkx"] as? [[String: Any]] else { return nil }
        for e in blkx {
            guard let d = e["Data"] as? Data, d.count >= 204 else { continue }
            let a = [UInt8](d)
            guard a.starts(with: Array("mish".utf8)) else { continue }
            let first = Self.be(a, 8, 8), total = Self.be(a, 16, 8), dataOff = Self.be(a, 24, 8)
            var name = (e["Name"] as? String) ?? ""
            if name.trimmingCharacters(in: .whitespaces).isEmpty { name = (e["CFName"] as? String) ?? "" }
            partitions.append(Partition(name: name.trimmingCharacters(in: .whitespaces), start: first, sectors: total))
            var p = 204
            while p + 40 <= a.count {
                let type = UInt32(Self.be(a, p, 4))
                if type == 0xFFFF_FFFF { break }
                if type != 0x7FFF_FFFE {
                    chunks.append(Chunk(type: type, start: first + Self.be(a, p + 8, 8), count: Self.be(a, p + 16, 8),
                                        fileOff: dataFork + dataOff + Self.be(a, p + 24, 8), fileLen: Self.be(a, p + 32, 8)))
                }
                p += 40
            }
        }
        chunks.sort { $0.start < $1.start }
        if chunks.isEmpty { return nil }
    }

    deinit { try? fh.close() }

    private func decode(_ c: Chunk) -> [UInt8]? {
        let outLen = Int(c.count * 512)
        switch c.type {
        case 0, 2: return [UInt8](repeating: 0, count: outLen)
        default: break
        }
        guard c.fileLen > 0, c.fileLen < 1 << 28, (try? fh.seek(toOffset: c.fileOff)) != nil,
              let d = try? fh.read(upToCount: Int(c.fileLen)), d.count == Int(c.fileLen) else { return nil }
        let src = [UInt8](d)
        switch c.type {
        case 1: return src
        case 0x8000_0005:
            var out = [UInt8](repeating: 0, count: outLen)
            var n = uLongf(outLen)
            let rc = out.withUnsafeMutableBufferPointer { o in src.withUnsafeBufferPointer { s in uncompress(o.baseAddress, &n, s.baseAddress, uLong(s.count)) } }
            return rc == Z_OK ? out : nil
        case 0x8000_0006:
            typealias Fn = @convention(c) (UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<CChar>?, UInt32, Int32, Int32) -> Int32
            guard let h = dlopen("/usr/lib/libbz2.1.0.dylib", RTLD_NOW) ?? dlopen("libbz2.dylib", RTLD_NOW), let sym = dlsym(h, "BZ2_bzBuffToBuffDecompress") else { return nil }
            let f = unsafeBitCast(sym, to: Fn.self)
            var out = [UInt8](repeating: 0, count: outLen)
            var n = UInt32(outLen)
            var s2 = src
            let rc = out.withUnsafeMutableBytes { o in s2.withUnsafeMutableBytes { s in
                f(o.baseAddress!.assumingMemoryBound(to: CChar.self), &n, s.baseAddress!.assumingMemoryBound(to: CChar.self), UInt32(s.count), 0, 0) } }
            return rc == 0 ? out : nil
        case 0x8000_0007:
            var out = [UInt8](repeating: 0, count: outLen)
            let n = out.withUnsafeMutableBufferPointer { o in src.withUnsafeBufferPointer { s in
                compression_decode_buffer(o.baseAddress!, outLen, s.baseAddress!, s.count, nil, COMPRESSION_LZFSE) } }
            return n == outLen ? out : nil
        case 0x8000_0004:                                                  // ADC
            var out = [UInt8](); out.reserveCapacity(outLen)
            var i = 0
            while i < src.count, out.count < outLen {
                let b = Int(src[i]); i += 1
                if b & 0x80 != 0 {
                    let n = (b & 0x7F) + 1
                    guard i + n <= src.count else { return nil }
                    out.append(contentsOf: src[i..<(i + n)]); i += n
                } else {
                    var len: Int, off: Int
                    if b & 0x40 != 0 { guard i + 2 <= src.count else { return nil }; len = (b & 0x3F) + 4; off = Int(src[i]) << 8 | Int(src[i + 1]); i += 2 }
                    else { guard i + 1 <= src.count else { return nil }; len = (b >> 2) + 3; off = (b & 3) << 8 | Int(src[i]); i += 1 }
                    off += 1
                    guard off <= out.count else { return nil }
                    for _ in 0..<len { out.append(out[out.count - off]) }
                }
            }
            return out
        default: return nil
        }
    }

    private func chunkIndex(sector: UInt64) -> Int? {
        var lo = 0, hi = chunks.count - 1
        while lo <= hi {
            let m = (lo + hi) / 2
            let c = chunks[m]
            if sector < c.start { hi = m - 1 } else if sector >= c.start + c.count { lo = m + 1 } else { return m }
        }
        return nil
    }

    /// Octets du disque virtuel ; zéros là où rien n'est défini.
    func read(_ offset: UInt64, _ n: Int) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        var out = [UInt8](); out.reserveCapacity(n)
        var pos = offset
        while out.count < n {
            let sector = pos / 512
            guard let ci = chunkIndex(sector: sector) else {
                let take = min(n - out.count, 512 - Int(pos % 512))
                out.append(contentsOf: [UInt8](repeating: 0, count: take)); pos += UInt64(take); continue
            }
            let data: [UInt8]
            if let d = cache[ci] { data = d }
            else {
                guard let d = decode(chunks[ci]) else { return out + [UInt8](repeating: 0, count: n - out.count) }
                cache[ci] = d; order.append(ci)
                if order.count > 24 { cache[order.removeFirst()] = nil }
                data = d
            }
            let inChunk = Int(pos - chunks[ci].start * 512)
            let take = min(n - out.count, data.count - inChunk)
            guard take > 0 else { break }
            out.append(contentsOf: data[inChunk..<(inChunk + take)]); pos += UInt64(take)
        }
        return out
    }
}

/// Un volume : fenêtre sur le disque virtuel.
struct DiskVolume {
    let disk: UDIFDisk
    let base: UInt64
    func read(_ off: UInt64, _ n: Int) -> [UInt8] { disk.read(base + off, n) }
}

private func be(_ b: [UInt8], _ i: Int, _ n: Int) -> UInt64 {
    guard i >= 0, i + n <= b.count else { return 0 }
    return (0..<n).reduce(0) { $0 << 8 | UInt64(b[i + $1]) }
}
private func le(_ b: [UInt8], _ i: Int, _ n: Int) -> UInt64 {
    guard i >= 0, i + n <= b.count else { return 0 }
    return (0..<n).reduce(0) { $0 | UInt64(b[i + $1]) << (8 * UInt64($1)) }
}

struct VolEntry { let id: UInt64; let parent: UInt64; let name: String; let isDir: Bool; let size: Int64 }

enum HFSPlus {
    static func entries(_ v: DiskVolume) -> [VolEntry]? {
        let vh = v.read(1024, 512)
        let sig = be(vh, 0, 2)
        guard sig == 0x482B || sig == 0x4858 else { return nil }                // 'H+' ou 'HX'
        let blockSize = Int(be(vh, 40, 4))
        guard blockSize >= 512, blockSize <= 1 << 20 else { return nil }
        // Fichier du catalogue : fork à l'offset 272 (taille logique, puis 8 extents).
        let logical = Int(be(vh, 272, 8))
        guard logical > 0, logical < 256 << 20 else { return nil }
        var catalog = [UInt8](); catalog.reserveCapacity(logical)
        for i in 0..<8 {
            let start = Int(be(vh, 272 + 16 + i * 8, 4)), count = Int(be(vh, 272 + 20 + i * 8, 4))
            if count == 0 { break }
            let want = min(count * blockSize, logical - catalog.count)
            catalog += v.read(UInt64(start) * UInt64(blockSize), want)
            if catalog.count >= logical { break }
        }
        guard catalog.count >= 512 else { return nil }
        let nodeSize = Int(be(catalog, 32, 2))
        guard nodeSize >= 512, nodeSize <= 65536 else { return nil }
        var node = Int(be(catalog, 24, 4))                                      // premier nœud feuille
        var out: [VolEntry] = []
        var guardN = 0
        while node != 0, guardN < 2_000_000 {
            guardN += 1
            let base = node * nodeSize
            guard base + nodeSize <= catalog.count else { break }
            let n = Array(catalog[base..<(base + nodeSize)])
            let kind = n[8]
            guard kind == 0xFF else { break }                                   // feuille = -1
            let num = Int(be(n, 10, 2))
            for r in 0..<num {
                let off = Int(be(n, nodeSize - 2 * (r + 1), 2))
                guard off + 8 < nodeSize else { continue }
                let keyLen = Int(be(n, off, 2))
                let parent = be(n, off + 2, 4)
                let nameLen = Int(be(n, off + 6, 2))
                guard off + 8 + nameLen * 2 <= nodeSize else { continue }
                let nameBytes = Array(n[(off + 8)..<(off + 8 + nameLen * 2)])
                let units = stride(from: 0, to: nameBytes.count, by: 2).map { UInt16(nameBytes[$0]) << 8 | UInt16(nameBytes[$0 + 1]) }
                var recOff = off + 2 + keyLen
                if recOff % 2 == 1 { recOff += 1 }
                guard recOff + 4 <= nodeSize else { continue }
                let rt = Int(be(n, recOff, 2))
                let name = String(decoding: units, as: UTF16.self).precomposedStringWithCanonicalMapping
                if rt == 1, recOff + 12 <= nodeSize {
                    out.append(VolEntry(id: be(n, recOff + 8, 4), parent: parent, name: name, isDir: true, size: 0))
                } else if rt == 2, recOff + 96 <= nodeSize {
                    out.append(VolEntry(id: be(n, recOff + 8, 4), parent: parent, name: name, isDir: false, size: Int64(be(n, recOff + 88, 8))))
                }
            }
            node = Int(be(n, 0, 4))
        }
        return out
    }
}

enum APFS {
    private final class Ctx {
        let v: DiskVolume; let bs: Int
        init(_ v: DiskVolume, _ bs: Int) { self.v = v; self.bs = bs }
        func block(_ paddr: UInt64) -> [UInt8] { v.read(paddr * UInt64(bs), bs) }
    }

    private struct Node {
        let d: [UInt8]
        var level: Int { Int(le(d, 34, 2)) }
        var flags: Int { Int(le(d, 32, 2)) }
        func records(fixedKey: Int = 16, fixedVal: Int = 16) -> [(k: Range<Int>, v: Range<Int>)] {
            let n = Int(le(d, 36, 4))
            let tsOff = Int(le(d, 40, 2)), tsLen = Int(le(d, 42, 2))
            let toc = 56 + tsOff, keyBase = toc + tsLen
            let valEnd = d.count - (flags & 1 != 0 ? 40 : 0)
            let fixed = flags & 4 != 0
            var out: [(Range<Int>, Range<Int>)] = []
            for i in 0..<min(n, 100_000) {
                if fixed {
                    let k = Int(le(d, toc + i * 4, 2)), v = Int(le(d, toc + i * 4 + 2, 2))
                    let vl = level > 0 ? 8 : fixedVal
                    let ks = keyBase + k, vs = valEnd - v
                    guard ks + fixedKey <= d.count, vs >= 0, vs + vl <= d.count else { continue }
                    out.append((ks..<(ks + fixedKey), vs..<(vs + vl)))
                } else {
                    let k = Int(le(d, toc + i * 8, 2)), kl = Int(le(d, toc + i * 8 + 2, 2))
                    let v = Int(le(d, toc + i * 8 + 4, 2)), vl = Int(le(d, toc + i * 8 + 6, 2))
                    let ks = keyBase + k, vs = valEnd - v
                    guard ks + kl <= d.count, vs >= 0, vs + vl <= d.count else { continue }
                    out.append((ks..<(ks + kl), vs..<(vs + vl)))
                }
            }
            return out
        }
    }

    /// oid → adresse physique, pour la version la plus récente (≤ maxXid).
    private static func omap(_ c: Ctx, omapPaddr: UInt64, maxXid: UInt64) -> [UInt64: UInt64] {
        let om = c.block(omapPaddr)
        let tree = le(om, 48, 8)
        var best: [UInt64: (UInt64, UInt64)] = [:]
        func walk(_ paddr: UInt64, _ depth: Int) {
            guard depth < 12 else { return }
            let n = Node(d: c.block(paddr))
            for r in n.records() {
                if n.level > 0 { walk(le(n.d, r.v.lowerBound, 8), depth + 1) }
                else {
                    let oid = le(n.d, r.k.lowerBound, 8), xid = le(n.d, r.k.lowerBound + 8, 8)
                    let flags = le(n.d, r.v.lowerBound, 4), paddrV = le(n.d, r.v.lowerBound + 8, 8)
                    if flags & 1 != 0 || xid > maxXid { continue }
                    if let b = best[oid], b.0 >= xid { continue }
                    best[oid] = (xid, paddrV)
                }
            }
        }
        walk(tree, 0)
        return best.mapValues { $0.1 }
    }

    static func volumes(_ v: DiskVolume) -> [(name: String, entries: [VolEntry])]? {
        let b0 = v.read(0, 4096)
        guard le(b0, 32, 4) == 0x4253_584E else { return nil }                  // 'NXSB'
        let bs = Int(le(b0, 36, 4))
        guard bs >= 4096, bs <= 65536 else { return nil }
        let c = Ctx(v, bs)
        // Point de contrôle le plus récent : on cherche le dernier superbloc de conteneur dans la zone des descripteurs.
        var sb = b0
        let descBase = le(b0, 112, 8), descBlocks = Int(le(b0, 104, 4) & 0x7FFF_FFFF)
        var bestXid = le(b0, 16, 8)
        if descBlocks > 0, descBlocks < 4096 {
            for i in 0..<descBlocks {
                let b = c.block(descBase + UInt64(i))
                if le(b, 32, 4) == 0x4253_584E, le(b, 24, 4) & 0xFFFF == 1, le(b, 16, 8) >= bestXid { bestXid = le(b, 16, 8); sb = b }
            }
        }
        let maxFS = Int(le(sb, 180, 4))
        let omapOid = le(sb, 160, 8)
        let cmap = omap(c, omapPaddr: omapOid, maxXid: bestXid)
        var result: [(String, [VolEntry])] = []
        for i in 0..<min(maxFS, 100) {
            let fsOid = le(sb, 184 + i * 8, 8)
            guard fsOid != 0, let vp = cmap[fsOid] else { continue }
            let vs = c.block(vp)
            guard le(vs, 32, 4) == 0x4253_5041 else { continue }                  // 'APSB'
            let incompat = le(vs, 56, 8)
            if incompat & 0x4 != 0 || le(vs, 264, 8) != 0 && false { continue }
            let vname = String(decoding: vs[704..<min(vs.count, 960)].prefix { $0 != 0 }, as: UTF8.self)
            let vOmap = le(vs, 128, 8), rootOid = le(vs, 136, 8)
            let vmap = omap(c, omapPaddr: vOmap, maxXid: le(vs, 16, 8))
            guard let rootP = vmap[rootOid] else { continue }
            var inodes: [UInt64: (parent: UInt64, dir: Bool, size: Int64)] = [:]
            var drecs: [(parent: UInt64, child: UInt64, name: String)] = []
            var count = 0
            func walk(_ paddr: UInt64, _ depth: Int) {
                guard depth < 12, count < 400_000 else { return }
                let n = Node(d: c.block(paddr))
                for r in n.records() {
                    if n.level > 0 {
                        let child = le(n.d, r.v.lowerBound, 8)
                        if let p = vmap[child] { walk(p, depth + 1) }
                        continue
                    }
                    let hdr = le(n.d, r.k.lowerBound, 8)
                    let type = hdr >> 60, id = hdr & 0x0FFF_FFFF_FFFF_FFFF
                    let val = Array(n.d[r.v])
                    if type == 3, val.count >= 84 {
                        let mode = Int(le(val, 80, 2))
                        var size: Int64 = 0
                        if le(val, 48, 8) & 0x40000 != 0 { size = Int64(le(val, 84, 8)) }
                        if val.count > 96 {
                            let num = Int(le(val, 92, 2))
                            var p = 96 + num * 4
                            for e in 0..<num {
                                let xt = val[96 + e * 4], xs = Int(le(val, 96 + e * 4 + 2, 2))
                                if xt == 8, p + 8 <= val.count, size == 0 { size = Int64(le(val, p, 8)) }
                                p += (xs + 7) & ~7
                            }
                        }
                        inodes[id] = (le(val, 0, 8), mode & 0xF000 == 0x4000, size)
                        count += 1
                    } else if type == 9, r.k.count > 12, val.count >= 18 {
                        let nl = Int(le(n.d, r.k.lowerBound + 8, 4) & 0x3FF)
                        let s = r.k.lowerBound + 12
                        guard nl > 0, s + nl <= n.d.count else { continue }
                        let name = String(decoding: n.d[s..<(s + nl - 1)], as: UTF8.self)
                        drecs.append((id, le(val, 0, 8), name)); count += 1
                    }
                }
            }
            walk(rootP, 0)
            var entries: [VolEntry] = []
            for d in drecs where d.parent >= 2 {
                let ino = inodes[d.child]
                entries.append(VolEntry(id: d.child, parent: d.parent, name: d.name, isDir: ino?.dir ?? false, size: ino?.size ?? 0))
            }
            result.append((vname, entries))
        }
        return result.isEmpty ? nil : result
    }
}
