// qLOOKS — source d'images pour Matroska (.mkv, .webm) : blocs lus par MatroskaFile, décodage par VideoToolbox.
// Codecs vidéo : H.264, HEVC, VP9 (profil 0), AV1 (si le Mac le décode).
import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

final class MKVSource: FrameSource, @unchecked Sendable {
    private let mkv: MatroskaFile
    private let video: MatroskaFile.Track
    private let blocks: [MatroskaFile.Block]       // ordre du fichier (ordre de décodage)
    private let order: [Int]                       // rang de présentation → indice de bloc
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var decoded: [Int: CVPixelBuffer] = [:]
    private var nextFeed = 0
    private var lengthSize = 4
    private let codec: CMVideoCodecType

    let pixelSize: CGSize
    let frameCount: Int
    let frameDuration: Double
    let hasAlpha = false
    var randomAccess: Bool { false }
    let codecName: String

    init(url: URL) throws {
        let file = try MatroskaFile(url: url)
        mkv = file
        guard let v = file.video else { throw FrameError.unreadable }
        video = v
        let bl = file.videoBlocks
        blocks = bl
        let ord = bl.indices.sorted { bl[$0].pts < bl[$1].pts }
        order = ord
        pixelSize = CGSize(width: v.width, height: v.height)
        frameCount = bl.count
        let span = (ord.last.map { bl[$0].pts } ?? 0) - (ord.first.map { bl[$0].pts } ?? 0)
        let measured = bl.count > 1 ? span / Double(bl.count - 1) : 1.0 / 24
        frameDuration = v.defaultDuration > 0 ? v.defaultDuration : max(measured, 1.0 / 240)
        switch v.codecID {
        case "V_MPEG4/ISO/AVC": codec = kCMVideoCodecType_H264; codecName = "H.264 (MKV)"
        case "V_MPEGH/ISO/HEVC": codec = kCMVideoCodecType_HEVC; codecName = "HEVC (MKV)"
        case "V_VP9": codec = kCMVideoCodecType_VP9; codecName = "VP9 (MKV)"
        case "V_AV1": codec = kCMVideoCodecType_AV1; codecName = "AV1 (MKV)"
        default: throw FrameError.unsupported(v.codecID)
        }
        if codec == kCMVideoCodecType_VP9 { VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9) }
        if codec == kCMVideoCodecType_AV1 { VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1) }
        try makeFormat()
    }

    // MARK: Format et session

    private func makeFormat() throws {
        var atoms: [String: Data] = [:]
        switch codec {
        case kCMVideoCodecType_H264:
            atoms["avcC"] = Data(video.codecPrivate)
            if video.codecPrivate.count > 4 { lengthSize = Int(video.codecPrivate[4] & 3) + 1 }
        case kCMVideoCodecType_HEVC:
            atoms["hvcC"] = Data(video.codecPrivate)
            if video.codecPrivate.count > 21 { lengthSize = Int(video.codecPrivate[21] & 3) + 1 }
        case kCMVideoCodecType_VP9:
            // vpcC minimal : profil 0, 8 bits, 4:2:0 ; les paramètres exacts viennent du flux.
            atoms["vpcC"] = Data([1, 0, 0, 0, 0, 0, 0x82, 1, 1, 1, 0, 0])
        default:
            if !video.codecPrivate.isEmpty { atoms["av1C"] = Data(video.codecPrivate) }
        }
        let ext: [String: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms]
        var fd: CMVideoFormatDescription?
        let st = CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: Int32(video.width), height: Int32(video.height),
                                                extensions: ext as CFDictionary, formatDescriptionOut: &fd)
        guard st == noErr, let fd else { throw FrameError.unsupported(codecName) }
        format = fd
    }

    private func startSession() throws {
        if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
        var s: VTDecompressionSession?
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: format!, decoderSpecification: nil,
                                              imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard st == noErr, let s else { throw FrameError.unsupported(codecName) }
        session = s
    }

    private func sampleBuffer(_ index: Int) -> CMSampleBuffer? {
        let b = blocks[index]
        guard var bytes = mkv.data(of: b) else { return nil }
        var block: CMBlockBuffer?
        let size = bytes.count
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            var mem: CMBlockBuffer?
            let s = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil,
                                                       customBlockSource: nil, offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &mem)
            guard s == noErr, let mem else { return s }
            _ = CMBlockBufferAssureBlockMemory(mem)
            let c = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: mem, offsetIntoDestination: 0, dataLength: size)
            block = mem
            return c
        }
        guard status == noErr, let block else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: b.pts, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var sizes = [size]
        var sb: CMSampleBuffer?
        let st = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sb)
        guard st == noErr, let sb else { return nil }
        if !b.key, let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }

    private func keyIndex(atOrBefore j: Int) -> Int {
        var k = j
        while k > 0, !blocks[k].key { k -= 1 }
        return k
    }

    // MARK: Lecture d'une image

    func frame(_ index: Int) throws -> CGImage {
        lock.lock(); defer { lock.unlock() }
        let i = max(0, min(index, frameCount - 1))
        let j = order[i]
        if let pb = decoded[j] { return try image(pb) }

        if session == nil || j < nextFeed - 24 || j > nextFeed + 90 || (j < nextFeed && decoded[j] == nil) {
            try startSession()
            decoded.removeAll()
            nextFeed = keyIndex(atOrBefore: j)
        }
        let target = min(blocks.count - 1, j + 8)           // marge pour les images réordonnées (B)
        guard let session else { throw FrameError.unreadable }
        while nextFeed <= target {
            let k = nextFeed
            nextFeed += 1
            guard let sb = sampleBuffer(k) else { continue }
            let pts = blocks[k].pts
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { [weak self] status, _, buffer, time, _ in
                guard status == noErr, let buffer, let self else { return }
                let t = time.seconds.isFinite ? time.seconds : pts
                self.store(buffer, at: t)
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        flushPending()
        // Garde en mémoire seulement les images proches.
        let keep = Set(order[max(0, i - 1)..<min(frameCount, i + 14)])
        for k in decoded.keys where !keep.contains(k) { decoded[k] = nil }
        guard let pb = decoded[j] else { throw FrameError.unreadable }
        return try image(pb)
    }

    private let storeLock = NSLock()
    private func store(_ buffer: CVPixelBuffer, at time: Double) {
        // Retrouve le bloc dont l'horodatage correspond.
        var lo = 0, hi = order.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if blocks[order[mid]].pts < time - 1e-6 { lo = mid + 1 } else { hi = mid }
        }
        guard abs(blocks[order[lo]].pts - time) < 0.002 else { return }
        storeLock.lock(); decodedPending[order[lo]] = buffer; storeLock.unlock()
    }

    private var decodedPending: [Int: CVPixelBuffer] = [:]
    private func flushPending() {
        storeLock.lock()
        for (k, v) in decodedPending { decoded[k] = v }
        decodedPending.removeAll()
        storeLock.unlock()
    }

    private func image(_ pb: CVPixelBuffer) throws -> CGImage {
        var img: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)
        guard let img else { throw FrameError.unreadable }
        return img
    }

    deinit { if let s = session { VTDecompressionSessionInvalidate(s) } }
}
