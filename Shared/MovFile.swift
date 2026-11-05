// qLOOKS — lecture minimale d'un conteneur QuickTime (.MOV) : piste vidéo, codec et table des images.
// Sert aux codecs que macOS ne décode plus (PNG, Animation) : on lit nous-mêmes chaque image dans le fichier.
import Foundation

struct MovFile {
    struct Sample { let offset: UInt64; let size: Int }

    let codec: String              // code à quatre lettres : "png ", "rle ", "ap4h"…
    let width: Int
    let height: Int
    let depth: Int                 // 32 = couche alpha
    let timescale: Double
    let durations: [Double]        // durée de chaque image, en secondes
    let samples: [Sample]
    let syncSamples: [Int]?        // images clés (indices croissants, base 0) ; nil = toutes

    var frameCount: Int { samples.count }
    var hasAlpha: Bool { depth == 32 }
    var totalSeconds: Double { durations.reduce(0, +) }
    var frameDuration: Double { frameCount > 0 ? max(totalSeconds / Double(frameCount), 1.0 / 240) : 1.0 / 24 }

    enum ParseError: Error { case notMov, noVideo, damaged }

    init(url: URL) throws {
        let moov = try Self.readMoov(url)
        let b = Bytes(moov)
        let all = 0..<moov.count
        var found: (String, Int, Int, Int, Double, [Double], [Sample], [Int]?)?
        for (type, trak) in b.children(all) where type == "trak" {
            guard let mdia = b.child("mdia", trak), let hdlr = b.child("hdlr", mdia),
                  b.fourcc(hdlr.lowerBound + 8) == "vide",
                  let mdhd = b.child("mdhd", mdia),
                  let stbl = b.child("minf", mdia).flatMap({ b.child("stbl", $0) }) else { continue }
            let version = b.u8(mdhd.lowerBound)
            let scale = Double(b.u32(mdhd.lowerBound + (version == 1 ? 20 : 12)))
            guard scale > 0, let stsd = b.child("stsd", stbl), b.u32(stsd.lowerBound + 4) > 0 else { continue }
            let e = stsd.lowerBound + 8
            guard e + 86 <= stsd.upperBound else { throw ParseError.damaged }
            let codec = b.fourcc(e + 4)
            let width = b.u16(e + 32), height = b.u16(e + 34), depth = b.u16(e + 82)
            let samples = try Self.samples(b, stbl)
            let durations = Self.durations(b, stbl, count: samples.count, scale: scale)
            var sync: [Int]?
            if let stss = b.child("stss", stbl) {
                let n = min(b.u32(stss.lowerBound + 4), (stss.count - 8) / 4)
                sync = (0..<n).map { b.u32(stss.lowerBound + 8 + $0 * 4) - 1 }.filter { $0 >= 0 }.sorted()
            }
            found = (codec, width, height, depth, scale, durations, samples, sync)
            break
        }
        guard let f = found, f.1 > 0, f.2 > 0, !f.6.isEmpty else { throw ParseError.noVideo }
        (codec, width, height, depth, timescale, durations, samples, syncSamples) = f
    }

    /// Image clé la plus proche avant (ou à) l'image demandée.
    func keyFrame(atOrBefore i: Int) -> Int {
        guard let sync = syncSamples, !sync.isEmpty else { return i }
        var lo = 0, hi = sync.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if sync[mid] <= i { best = sync[mid]; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }

    // MARK: Lecture

    /// Parcourt les atomes de premier niveau (sans lire le gros « mdat ») et renvoie le contenu de « moov ».
    private static func readMoov(_ url: URL) throws -> [UInt8] {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let end = try h.seekToEnd()
        var offset: UInt64 = 0
        while offset + 8 <= end {
            try h.seek(toOffset: offset)
            guard let head = try h.read(upToCount: 16), head.count >= 8 else { break }
            let hb = Bytes([UInt8](head))
            var size = UInt64(hb.u32(0)), header: UInt64 = 8
            let type = hb.fourcc(4)
            if size == 1 { guard head.count >= 16 else { break }; size = hb.u64(8); header = 16 }
            else if size == 0 { size = end - offset }
            guard size >= header, offset + size <= end else { break }
            if type == "moov" {
                guard size < 512 << 20 else { throw ParseError.damaged }
                try h.seek(toOffset: offset + header)
                guard let body = try h.read(upToCount: Int(size - header)), body.count == Int(size - header) else { throw ParseError.damaged }
                return [UInt8](body)
            }
            if offset == 0, !["ftyp", "wide", "mdat", "free", "skip", "pnot", "moov", "uuid"].contains(type) { throw ParseError.notMov }
            offset += size
        }
        throw ParseError.notMov
    }

    private static func samples(_ b: Bytes, _ stbl: Range<Int>) throws -> [Sample] {
        guard let stsz = b.child("stsz", stbl), let stsc = b.child("stsc", stbl) else { throw ParseError.damaged }
        let fixed = b.u32(stsz.lowerBound + 4)
        let count = b.u32(stsz.lowerBound + 8)
        let sizes: [Int] = fixed != 0 ? Array(repeating: fixed, count: count)
            : (0..<min(count, (stsz.count - 12) / 4)).map { b.u32(stsz.lowerBound + 12 + $0 * 4) }
        var chunks: [UInt64] = []
        if let stco = b.child("stco", stbl) {
            let n = min(b.u32(stco.lowerBound + 4), (stco.count - 8) / 4)
            chunks = (0..<n).map { UInt64(b.u32(stco.lowerBound + 8 + $0 * 4)) }
        } else if let co64 = b.child("co64", stbl) {
            let n = min(b.u32(co64.lowerBound + 4), (co64.count - 8) / 8)
            chunks = (0..<n).map { b.u64(co64.lowerBound + 8 + $0 * 8) }
        } else { throw ParseError.damaged }
        let entries = min(b.u32(stsc.lowerBound + 4), (stsc.count - 8) / 12)
        let runs = (0..<entries).map { (first: b.u32(stsc.lowerBound + 8 + $0 * 12), perChunk: b.u32(stsc.lowerBound + 12 + $0 * 12)) }
        guard !runs.isEmpty else { throw ParseError.damaged }

        var out: [Sample] = []
        out.reserveCapacity(sizes.count)
        var run = 0, s = 0
        for (ci, start) in chunks.enumerated() {
            while run + 1 < runs.count, runs[run + 1].first <= ci + 1 { run += 1 }
            var off = start
            for _ in 0..<runs[run].perChunk where s < sizes.count {
                out.append(Sample(offset: off, size: sizes[s]))
                off += UInt64(sizes[s]); s += 1
            }
            if s >= sizes.count { break }
        }
        return out
    }

    private static func durations(_ b: Bytes, _ stbl: Range<Int>, count: Int, scale: Double) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(count)
        if let stts = b.child("stts", stbl) {
            let n = min(b.u32(stts.lowerBound + 4), (stts.count - 8) / 8)
            for i in 0..<n where out.count < count {
                let c = b.u32(stts.lowerBound + 8 + i * 8), d = Double(b.u32(stts.lowerBound + 12 + i * 8)) / scale
                out.append(contentsOf: repeatElement(d, count: min(c, count - out.count)))
            }
        }
        let last = out.last ?? 1.0 / 24
        if out.count < count { out.append(contentsOf: repeatElement(last, count: count - out.count)) }
        return out
    }
}

/// Lecture big-endian dans un tampon, sans jamais sortir de ses bornes (0 au-delà).
struct Bytes {
    let b: [UInt8]
    init(_ b: [UInt8]) { self.b = b }

    func u8(_ i: Int) -> Int { i >= 0 && i < b.count ? Int(b[i]) : 0 }
    func u16(_ i: Int) -> Int { u8(i) << 8 | u8(i + 1) }
    func u32(_ i: Int) -> Int { u16(i) << 16 | u16(i + 2) }
    func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) << 32 | UInt64(u32(i + 4)) }
    func fourcc(_ i: Int) -> String { String(decoding: (0..<4).map { UInt8(u8(i + $0)) }, as: UTF8.self) }

    func children(_ r: Range<Int>) -> [(String, Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var i = r.lowerBound
        while i + 8 <= r.upperBound {
            var size = u32(i), header = 8
            if size == 1 { guard i + 16 <= r.upperBound else { break }; size = Int(clamping: u64(i + 8)); header = 16 }
            else if size == 0 { size = r.upperBound - i }
            guard size >= header, i + size <= r.upperBound else { break }
            out.append((fourcc(i + 4), (i + header)..<(i + size)))
            i += size
        }
        return out
    }

    func child(_ type: String, _ r: Range<Int>) -> Range<Int>? { children(r).first { $0.0 == type }?.1 }
}
