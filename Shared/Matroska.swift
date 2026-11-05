// qLOOKS — lecture minimale d'un conteneur Matroska (.mkv, .webm) : pistes, codecs et index des blocs vidéo et audio.
// Les images ne sont pas lues ici : on garde seulement leur position dans le fichier, comme pour MovFile.
import Foundation

final class MatroskaFile {
    struct Track {
        var number = 0, type = 0
        var codecID = ""
        var codecPrivate: [UInt8] = []
        var width = 0, height = 0
        var defaultDuration = 0.0            // secondes par image
        var sampleRate = 0.0, channels = 0
    }
    struct Block {
        let offset: UInt64
        let size: Int
        let pts: Double                      // secondes
        let key: Bool
    }

    private(set) var tracks: [Track] = []
    private(set) var duration = 0.0
    private(set) var blocks: [Int: [Block]] = [:]      // par numéro de piste, dans l'ordre du fichier
    private var timecodeScale = 1_000_000.0

    enum ParseError: Error { case notMatroska, damaged, noVideo }

    var video: Track? { tracks.first { $0.type == 1 } }
    var audio: Track? { tracks.first { $0.type == 2 } }
    var videoBlocks: [Block] { video.flatMap { blocks[$0.number] } ?? [] }
    var audioBlocks: [Block] { audio.flatMap { blocks[$0.number] } ?? [] }

    static func isMatroska(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: 4) else { return false }
        try? h.close()
        return [UInt8](d) == [0x1A, 0x45, 0xDF, 0xA3]
    }

    // MARK: Lecture bas niveau

    private let fd: Int32
    private let fileSize: UInt64

    init(url: URL) throws {
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw ParseError.damaged }
        var st = stat()
        fstat(fd, &st)
        fileSize = UInt64(st.st_size)
        guard MatroskaFile.isMatroska(url) else { throw ParseError.notMatroska }
        try parse()
        guard video != nil, !videoBlocks.isEmpty else { throw ParseError.noVideo }
    }

    private func read(_ at: UInt64, _ n: Int) -> [UInt8] {
        guard n > 0, at < fileSize else { return [] }
        let count = Int(min(UInt64(n), fileSize - at))
        var out = [UInt8](repeating: 0, count: count)
        let got = out.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(at)) }
        return got == count ? out : Array(out.prefix(max(0, got)))
    }

    /// Identifiant (marqueur conservé) et taille d'un élément ; taille nil = inconnue.
    private func header(at pos: UInt64) -> (id: UInt32, size: UInt64?, headerLen: Int)? {
        let b = read(pos, 12)
        guard let first = b.first, first != 0 else { return nil }
        let idLen = first.leadingZeroBitCount + 1
        guard idLen <= 4, b.count > idLen else { return nil }
        var id: UInt32 = 0
        for i in 0..<idLen { id = id << 8 | UInt32(b[i]) }
        let s0 = b[idLen]
        guard s0 != 0 else { return nil }
        let sLen = s0.leadingZeroBitCount + 1
        guard idLen + sLen <= b.count else { return nil }
        var size = UInt64(s0) & (0xFF >> UInt64(sLen))
        var allOnes = size == (0xFF >> UInt64(sLen))
        for i in 1..<sLen { size = size << 8 | UInt64(b[idLen + i]); if b[idLen + i] != 0xFF { allOnes = false } }
        return (id, allOnes ? nil : size, idLen + sLen)
    }

    private func uint(_ bytes: [UInt8]) -> UInt64 { bytes.reduce(0) { $0 << 8 | UInt64($1) } }

    private func float(_ bytes: [UInt8]) -> Double {
        if bytes.count == 4 { return Double(Float(bitPattern: UInt32(uint(bytes)))) }
        if bytes.count == 8 { return Double(bitPattern: uint(bytes)) }
        return 0
    }

    // MARK: Analyse

    private static let topLevel: Set<UInt32> = [0x1F43B675, 0x1C53BB6B, 0x1254C367, 0x1941A469, 0x1043A770, 0x114D9B74, 0x1549A966, 0x1654AE6B]

    private func parse() throws {
        guard let ebml = header(at: 0), ebml.id == 0x1A45DFA3, let esize = ebml.size else { throw ParseError.notMatroska }
        var pos = UInt64(ebml.headerLen) + esize
        while pos < fileSize, let h = header(at: pos) {
            let start = pos + UInt64(h.headerLen)
            if h.id == 0x18538067 {                                     // Segment
                let end = h.size.map { min(start + $0, fileSize) } ?? fileSize
                try parseSegment(start, end)
                return
            }
            guard let s = h.size else { break }
            pos = start + s
        }
        throw ParseError.damaged
    }

    private func parseSegment(_ start: UInt64, _ end: UInt64) throws {
        var pos = start
        while pos < end, let h = header(at: pos) {
            let body = pos + UInt64(h.headerLen)
            switch h.id {
            case 0x1549A966:                                            // Info
                guard let s = h.size else { return }
                parseInfo(body, body + s)
                pos = body + s
            case 0x1654AE6B:                                            // Tracks
                guard let s = h.size else { return }
                parseTracks(body, body + s)
                pos = body + s
            case 0x1F43B675:                                            // Cluster
                pos = parseCluster(body, h.size.map { body + $0 }, limit: end)
            default:
                guard let s = h.size else { return }
                pos = body + s
            }
        }
    }

    private func children(_ start: UInt64, _ end: UInt64, _ visit: (UInt32, UInt64, Int) -> Void) {
        var pos = start
        while pos < end, let h = header(at: pos) {
            let body = pos + UInt64(h.headerLen)
            guard let s = h.size, body + s <= end else { return }
            visit(h.id, body, Int(s))
            pos = body + s
        }
    }

    private func parseInfo(_ start: UInt64, _ end: UInt64) {
        var rawDuration = 0.0
        children(start, end) { id, body, size in
            switch id {
            case 0x2AD7B1: timecodeScale = Double(uint(read(body, size)))
            case 0x4489: rawDuration = float(read(body, size))
            default: break
            }
        }
        duration = rawDuration * timecodeScale / 1e9
    }

    private func parseTracks(_ start: UInt64, _ end: UInt64) {
        children(start, end) { id, body, size in
            guard id == 0xAE else { return }
            var t = Track()
            children(body, body + UInt64(size)) { id, b, s in
                switch id {
                case 0xD7: t.number = Int(uint(read(b, s)))
                case 0x83: t.type = Int(uint(read(b, s)))
                case 0x86: t.codecID = String(decoding: read(b, s), as: UTF8.self)
                case 0x63A2: t.codecPrivate = read(b, s)
                case 0x23E383: t.defaultDuration = Double(uint(read(b, s))) / 1e9
                case 0xE0:
                    children(b, b + UInt64(s)) { id, bb, ss in
                        if id == 0xB0 { t.width = Int(uint(read(bb, ss))) }
                        if id == 0xBA { t.height = Int(uint(read(bb, ss))) }
                    }
                case 0xE1:
                    children(b, b + UInt64(s)) { id, bb, ss in
                        if id == 0xB5 { t.sampleRate = float(read(bb, ss)) }
                        if id == 0x9F { t.channels = Int(uint(read(bb, ss))) }
                    }
                default: break
                }
            }
            tracks.append(t)
        }
    }

    /// Lit les blocs d'une grappe ; renvoie la position qui suit la grappe.
    private func parseCluster(_ start: UInt64, _ known: UInt64?, limit: UInt64) -> UInt64 {
        var pos = start
        let end = known ?? limit
        var clusterTime = 0.0
        while pos < end, let h = header(at: pos) {
            if known == nil, MatroskaFile.topLevel.contains(h.id) { return pos }
            let body = pos + UInt64(h.headerLen)
            guard let s = h.size else { return end }
            switch h.id {
            case 0xE7: clusterTime = Double(uint(read(body, Int(s))))
            case 0xA3: addBlock(body, Int(s), clusterTime, key: nil)
            case 0xA0:                                                  // BlockGroup
                var blockBody: UInt64?, blockSize = 0, hasRef = false
                children(body, body + s) { id, b, sz in
                    if id == 0xA1 { blockBody = b; blockSize = sz }
                    if id == 0xFB { hasRef = true }
                }
                if let b = blockBody { addBlock(b, blockSize, clusterTime, key: !hasRef) }
            default: break
            }
            pos = body + s
        }
        return min(max(pos, start), end)
    }

    private func addBlock(_ body: UInt64, _ size: Int, _ clusterTime: Double, key: Bool?) {
        let head = read(body, 8)
        guard let f = head.first, f != 0 else { return }
        let tl = f.leadingZeroBitCount + 1
        guard head.count >= tl + 3 else { return }
        var track = Int(f) & (0xFF >> tl)
        for i in 1..<tl { track = track << 8 | Int(head[i]) }
        let rel = Int(Int16(bitPattern: UInt16(head[tl]) << 8 | UInt16(head[tl + 1])))
        let flags = head[tl + 2]
        let isKey = key ?? (flags & 0x80 != 0)
        let payload = tl + 3
        guard size > payload else { return }
        let pts = (clusterTime + Double(rel)) * timecodeScale / 1e9
        blocks[track, default: []].append(Block(offset: body + UInt64(payload), size: size - payload, pts: pts, key: isKey))
    }

    /// Octets d'un bloc.
    func data(of block: Block) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: block.size)
        let got = out.withUnsafeMutableBytes { pread(fd, $0.baseAddress, block.size, off_t(block.offset)) }
        return got == block.size ? out : nil
    }

    deinit { close(fd) }
}
