// qLOOKS — lecture d'un fichier zip (entrées stockées ou compressées en deflate) : utilisé pour le 3MF.
import Foundation
import zlib

final class ZipFile {
    struct Entry { let method: Int; let csize: Int; let usize: Int; let offset: UInt64 }
    private let fh: FileHandle
    private(set) var entries: [String: Entry] = [:]

    private static func le(_ b: [UInt8], _ i: Int, _ n: Int) -> UInt64 {
        guard i + n <= b.count else { return 0 }
        return (0..<n).reduce(0) { $0 | UInt64(b[i + $1]) << (8 * UInt64($1)) }
    }

    init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        fh = h
        guard let size = try? h.seekToEnd(), size > 22 else { return nil }
        let tail = min(size, 70_000)
        guard (try? h.seek(toOffset: size - tail)) != nil, let td = try? h.read(upToCount: Int(tail)) else { return nil }
        let t = [UInt8](td)
        var e = t.count - 22
        while e >= 0, !(t[e] == 0x50 && t[e + 1] == 0x4B && t[e + 2] == 5 && t[e + 3] == 6) { e -= 1 }
        guard e >= 0 else { return nil }
        let count = Int(Self.le(t, e + 10, 2)), cdSize = Int(Self.le(t, e + 12, 4)), cdOff = Self.le(t, e + 16, 4)
        guard cdSize < 1 << 28, (try? h.seek(toOffset: cdOff)) != nil, let cdd = try? h.read(upToCount: cdSize) else { return nil }
        let cd = [UInt8](cdd)
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, Self.le(cd, p, 4) == 0x02014B50 else { break }
            let nl = Int(Self.le(cd, p + 28, 2)), el = Int(Self.le(cd, p + 30, 2)), cl = Int(Self.le(cd, p + 32, 2))
            guard p + 46 + nl <= cd.count else { break }
            let name = String(decoding: cd[(p + 46)..<(p + 46 + nl)], as: UTF8.self)
            entries[name] = Entry(method: Int(Self.le(cd, p + 10, 2)), csize: Int(Self.le(cd, p + 20, 4)), usize: Int(Self.le(cd, p + 24, 4)), offset: Self.le(cd, p + 42, 4))
            p += 46 + nl + el + cl
        }
        if entries.isEmpty { return nil }
    }
    deinit { try? fh.close() }

    func data(_ name: String) -> Data? {
        guard let e = entries[name], e.usize < 1 << 29, (try? fh.seek(toOffset: e.offset)) != nil,
              let lh = try? fh.read(upToCount: 30), lh.count == 30 else { return nil }
        let l = [UInt8](lh)
        let skip = Int(Self.le(l, 26, 2)) + Int(Self.le(l, 28, 2))
        guard (try? fh.seek(toOffset: e.offset + 30 + UInt64(skip))) != nil, let raw = try? fh.read(upToCount: e.csize), raw.count == e.csize else { return nil }
        if e.method == 0 { return raw }
        guard e.method == 8 else { return nil }
        var out = [UInt8](repeating: 0, count: e.usize)
        var zs = z_stream()
        guard inflateInit2_(&zs, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&zs) }
        var src = [UInt8](raw)
        let rc: Int32 = src.withUnsafeMutableBufferPointer { s in out.withUnsafeMutableBufferPointer { o in
            zs.next_in = s.baseAddress; zs.avail_in = UInt32(s.count); zs.next_out = o.baseAddress; zs.avail_out = UInt32(o.count)
            return inflate(&zs, Z_FINISH)
        } }
        return rc == Z_STREAM_END ? Data(out) : nil
    }
}
