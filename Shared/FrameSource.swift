// qLOOKS — sources d'images : PNG et Animation lus par nos soins, tout le reste (ProRes 4444, HEVC alpha…) par AVFoundation.
import AVFoundation
import CoreGraphics
import ImageIO
import VideoToolbox

protocol FrameSource: AnyObject, Sendable {
    var pixelSize: CGSize { get }
    var frameCount: Int { get }
    var frameDuration: Double { get }
    var hasAlpha: Bool { get }
    /// Décodage dans n'importe quel ordre (PNG) ; sinon, images lues de préférence à la suite.
    var randomAccess: Bool { get }
    var codecName: String { get }
    func frame(_ index: Int) throws -> CGImage
}

enum FrameError: LocalizedError {
    case unsupported(String), unreadable
    var errorDescription: String? {
        switch self {
        case .unsupported(let c): return L.t("err.codec", c)
        case .unreadable: return L.t("err.read")
        }
    }
}

enum Sources {
    /// Vrai quand l'aperçu du système ne convient pas : codec qu'il ne lit pas, ou couche alpha à montrer sur un damier.
    static func needsAlphaView(_ url: URL) -> Bool {
        if MatroskaFile.isMatroska(url) { return true }
        guard let mov = try? MovFile(url: url) else { return false }
        return ["png ", "rle "].contains(mov.codec) || mov.hasAlpha
    }

    static func open(_ url: URL) async throws -> FrameSource {
        if MatroskaFile.isMatroska(url) { return try MKVSource(url: url) }
        if let mov = try? MovFile(url: url) {
            switch mov.codec {
            case "png ": return try PNGSource(url: url, mov: mov)
            case "rle ": return try RLESource(url: url, mov: mov)
            default: return try await AVSource(url: url, mov: mov)
            }
        }
        return try await AVSource(url: url, mov: nil)
    }

    static func codecName(_ fourcc: String) -> String {
        switch fourcc {
        case "png ": return "PNG"
        case "rle ": return "Animation"
        case "ap4h": return "ProRes 4444"
        case "ap4x": return "ProRes 4444 XQ"
        case "apch": return "ProRes 422 HQ"
        case "apcn": return "ProRes 422"
        case "hvc1", "hev1": return "HEVC"
        case "avc1": return "H.264"
        default: return fourcc.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }
}

/// Lecture d'un échantillon dans le fichier (pread : sûr depuis plusieurs fils à la fois).
private final class SampleReader {
    private let fd: Int32
    init(_ url: URL) throws {
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw FrameError.unreadable }
    }
    deinit { close(fd) }

    func read(_ s: MovFile.Sample) throws -> [UInt8] {
        guard s.size > 0, s.size < 1 << 30 else { throw FrameError.unreadable }
        var out = [UInt8](repeating: 0, count: s.size)
        let got = out.withUnsafeMutableBytes { pread(fd, $0.baseAddress, s.size, off_t(s.offset)) }
        guard got == s.size else { throw FrameError.unreadable }
        return out
    }
}

final class PNGSource: FrameSource, @unchecked Sendable {
    let mov: MovFile
    private let reader: SampleReader
    init(url: URL, mov: MovFile) throws { self.mov = mov; reader = try SampleReader(url) }

    var pixelSize: CGSize { CGSize(width: mov.width, height: mov.height) }
    var frameCount: Int { mov.frameCount }
    var frameDuration: Double { mov.frameDuration }
    var hasAlpha: Bool { mov.hasAlpha }
    var randomAccess: Bool { true }
    var codecName: String { Sources.codecName(mov.codec) }

    func frame(_ index: Int) throws -> CGImage {
        let bytes = try reader.read(mov.samples[max(0, min(index, frameCount - 1))])
        guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw FrameError.unreadable }
        return img
    }
}

final class RLESource: FrameSource, @unchecked Sendable {
    let mov: MovFile
    private let reader: SampleReader
    private let decoder: QTRLEDecoder
    private let lock = NSLock()
    private var last = -1
    private var lastImage: CGImage?

    init(url: URL, mov: MovFile) throws {
        guard let d = QTRLEDecoder(width: mov.width, height: mov.height, depth: mov.depth) else {
            throw FrameError.unsupported("Animation \(mov.depth) bits")
        }
        self.mov = mov; decoder = d; reader = try SampleReader(url)
    }

    var pixelSize: CGSize { CGSize(width: mov.width, height: mov.height) }
    var frameCount: Int { mov.frameCount }
    var frameDuration: Double { mov.frameDuration }
    var hasAlpha: Bool { mov.hasAlpha }
    var randomAccess: Bool { false }
    var codecName: String { Sources.codecName(mov.codec) }

    func frame(_ index: Int) throws -> CGImage {
        lock.lock(); defer { lock.unlock() }
        let i = max(0, min(index, frameCount - 1))
        if i == last, let img = lastImage { return img }
        let key = mov.keyFrame(atOrBefore: i)
        var from = last + 1
        if last < 0 || i < last || key > last { decoder.reset(); from = key }
        for k in from...i { decoder.decode(try reader.read(mov.samples[k])) }
        guard let img = decoder.image() else { throw FrameError.unreadable }
        last = i; lastImage = img
        return img
    }
}

final class AVSource: FrameSource, @unchecked Sendable {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var next = -1
    let pixelSize: CGSize
    let frameCount: Int
    let frameDuration: Double
    let hasAlpha: Bool
    let codecName: String
    var randomAccess: Bool { false }

    init(url: URL, mov: MovFile?) async throws {
        asset = AVURLAsset(url: url)
        guard let t = try await asset.loadTracks(withMediaType: .video).first else { throw FrameError.unreadable }
        track = t
        let (size, rate, formats) = try await t.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
        let duration = try await asset.load(.duration).seconds
        guard let format = formats.first else { throw FrameError.unreadable }
        let fourcc = CMFormatDescriptionGetMediaSubType(format)
        let code = String(decoding: withUnsafeBytes(of: fourcc.bigEndian) { Array($0) }, as: UTF8.self)
        codecName = Sources.codecName(code)
        let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let depth = (ext[kCMFormatDescriptionExtension_Depth as String] as? Int) ?? mov?.depth ?? 24
        let alphaFlag = ext[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool ?? false
        hasAlpha = depth == 32 || alphaFlag
        pixelSize = size
        frameDuration = rate > 0 ? 1 / Double(rate) : (mov?.frameDuration ?? 1.0 / 24)
        frameCount = max(1, mov?.frameCount ?? Int((duration / frameDuration).rounded()))
    }

    private func restart(at index: Int) throws {
        reader?.cancelReading()
        let r = try AVAssetReader(asset: asset)
        let start = CMTime(seconds: Double(index) * frameDuration, preferredTimescale: 600_000)
        r.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        o.alwaysCopiesSampleData = false
        guard r.canAdd(o) else { throw FrameError.unreadable }
        r.add(o)
        guard r.startReading() else { throw r.error ?? FrameError.unreadable }
        reader = r; output = o; next = index
    }

    func frame(_ index: Int) throws -> CGImage {
        lock.lock(); defer { lock.unlock() }
        let i = max(0, min(index, frameCount - 1))
        if i != next || reader == nil { try restart(at: i) }
        guard let sample = output?.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sample) else {
            reader = nil
            throw FrameError.unreadable
        }
        next = i + 1
        var img: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)
        guard let img else { throw FrameError.unreadable }
        return img
    }
}

/// Image représentative d'une vidéo pour sa vignette : la plus « remplie » parmi quelques images réparties
/// (beaucoup d'éléments détourés commencent ou finissent vides).
enum Representative {
    static func frame(_ src: FrameSource) throws -> CGImage {
        let n = src.frameCount
        let picks = n < 4 ? [n / 2] : [n * 15 / 100, n * 35 / 100, n / 2, n * 65 / 100, n * 85 / 100]
        guard src.hasAlpha else { return try src.frame(n / 3) }
        var best: (CGImage, Double)?
        for i in picks {
            guard let img = try? src.frame(i) else { continue }
            let c = coverage(img)
            if best == nil || c > best!.1 { best = (img, c) }
        }
        guard let best else { return try src.frame(0) }
        return best.0
    }

    /// Part moyenne d'opacité, mesurée sur une réduction 24 × 24.
    static func coverage(_ img: CGImage) -> Double {
        let s = 24
        var px = [UInt8](repeating: 0, count: s * s * 4)
        guard let ctx = CGContext(data: &px, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: s, height: s))
        var sum = 0
        for i in stride(from: 3, to: px.count, by: 4) { sum += Int(px[i]) }
        return Double(sum) / Double(s * s * 255)
    }
}
