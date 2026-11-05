// qLOOKS — extension de lecture de format (MediaExtension) : fait lire les fichiers Matroska (.mkv) à tout macOS
// (Finder, Quick Look, QuickTime Player…). Pistes : H.264, HEVC, VP9, AV1, AAC, AC-3, E-AC-3, MP3.
import AVFoundation
import CoreMedia
import Foundation
import MediaExtension

private final class ByteAdapter: MKVByteSource {
    let source: MEByteSource
    init(_ s: MEByteSource) { source = s }
    var size: UInt64 { UInt64(max(0, source.fileLength)) }
    func read(_ at: UInt64, _ n: Int) -> [UInt8] {
        guard n > 0, at < size else { return [] }
        let count = Int(min(UInt64(n), size - at))
        var out = [UInt8](repeating: 0, count: count)
        let got = out.withUnsafeMutableBytes { QLReadSync(source, $0.baseAddress, count, Int64(at)) }
        return got == count ? out : Array(out.prefix(got))
    }
}

private struct Sample {
    let offset: Int64
    let size: Int
    let pts: CMTime
    let dts: CMTime
    let duration: CMTime
    let key: Bool
}

private final class TrackData {
    let number: Int
    let mediaType: CMMediaType
    let format: CMFormatDescription
    var samples: [Sample] = []
    var presentationOrder: [Int] = []       // rang de présentation → indice (ordre de décodage)
    var rank: [Int] = []                    // indice (ordre de décodage) → rang
    var requiresReordering = false
    let info: MatroskaFile.Track

    init(number: Int, mediaType: CMMediaType, format: CMFormatDescription, info: MatroskaFile.Track) {
        self.number = number; self.mediaType = mediaType; self.format = format; self.info = info
    }

    func build(_ blocks: [MatroskaFile.Block]) {
        let ts: CMTimeScale = 1_000_000
        let pts = blocks.map { CMTime(seconds: $0.pts, preferredTimescale: ts) }
        let order = blocks.indices.sorted { blocks[$0].pts < blocks[$1].pts }
        presentationOrder = order
        rank = [Int](repeating: 0, count: blocks.count)
        for (r, i) in order.enumerated() { rank[i] = r }
        requiresReordering = order.enumerated().contains { $0.offset != $0.element }
        // DTS : i-ième plus petit PTS, décalé pour rester inférieur ou égal au PTS.
        let sorted = order.map { blocks[$0].pts }
        var delay = 0.0
        for i in blocks.indices { delay = max(delay, sorted[i] - blocks[i].pts) }
        let fallback = info.defaultDuration > 0 ? info.defaultDuration : 1.0 / 24
        var durations = [Double](repeating: fallback, count: blocks.count)
        for (r, i) in order.enumerated() {
            if r + 1 < order.count { durations[i] = max(blocks[order[r + 1]].pts - blocks[i].pts, 0.0001) }
            else if r > 0 { durations[i] = durations[order[r - 1]] }
        }
        samples = blocks.indices.map { i in
            Sample(offset: Int64(blocks[i].offset), size: blocks[i].size, pts: pts[i],
                   dts: CMTime(seconds: sorted[i] - delay, preferredTimescale: ts),
                   duration: CMTime(seconds: durations[i], preferredTimescale: ts), key: blocks[i].key)
        }
    }
}

// MARK: Formats

private func videoFormat(_ t: MatroskaFile.Track) -> CMFormatDescription? {
    var atoms: [String: Data] = [:]
    let codec: CMVideoCodecType
    switch t.codecID {
    case "V_MPEG4/ISO/AVC": codec = kCMVideoCodecType_H264; atoms["avcC"] = Data(t.codecPrivate)
    case "V_MPEGH/ISO/HEVC": codec = kCMVideoCodecType_HEVC; atoms["hvcC"] = Data(t.codecPrivate)
    case "V_VP9": codec = kCMVideoCodecType_VP9; atoms["vpcC"] = Data([1, 0, 0, 0, 0, 0, 0x82, 1, 1, 1, 0, 0])
    case "V_AV1": codec = kCMVideoCodecType_AV1; if !t.codecPrivate.isEmpty { atoms["av1C"] = Data(t.codecPrivate) }
    default: return nil
    }
    let ext: [String: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms]
    var fd: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: Int32(t.width), height: Int32(t.height),
                                         extensions: ext as CFDictionary, formatDescriptionOut: &fd) == noErr else { return nil }
    return fd
}

/// Descripteur « esds » contenant l'AudioSpecificConfig, tel que l'attend CoreAudio pour l'AAC.
private func esds(_ asc: [UInt8]) -> [UInt8] {
    let decoderConfig: [UInt8] = [0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + [0x05, UInt8(asc.count)] + asc
    let dcd: [UInt8] = [0x04, UInt8(decoderConfig.count)] + decoderConfig
    let sl: [UInt8] = [0x06, 0x01, 0x02]
    let body: [UInt8] = [0, 0, 0] + dcd + sl
    return [0x03, UInt8(body.count)] + body
}

private func audioFormat(_ t: MatroskaFile.Track) -> CMFormatDescription? {
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = t.sampleRate > 0 ? t.sampleRate : 48000
    asbd.mChannelsPerFrame = UInt32(max(1, t.channels))
    var cookie: [UInt8] = []
    switch t.codecID {
    case "A_AAC", "A_AAC/MPEG4/LC", "A_AAC/MPEG4/LC/SBR":
        asbd.mFormatID = kAudioFormatMPEG4AAC; asbd.mFramesPerPacket = 1024
        cookie = esds(t.codecPrivate)
    case "A_AC3": asbd.mFormatID = kAudioFormatAC3; asbd.mFramesPerPacket = 1536
    case "A_EAC3": asbd.mFormatID = kAudioFormatEnhancedAC3; asbd.mFramesPerPacket = 1536
    case "A_MPEG/L3": asbd.mFormatID = kAudioFormatMPEGLayer3; asbd.mFramesPerPacket = 1152
    default: return nil
    }
    var fd: CMAudioFormatDescription?
    let st = cookie.withUnsafeBytes {
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: cookie.count,
                                       magicCookie: cookie.isEmpty ? nil : $0.baseAddress, extensions: nil, formatDescriptionOut: &fd)
    }
    return st == noErr ? fd : nil
}

// MARK: Extension

@objc(ReaderExtension)
final class ReaderExtension: NSObject, MEFormatReaderExtension {
    override init() { super.init() }

    func formatReader(with primaryByteSource: MEByteSource, options: MEFormatReaderInstantiationOptions?) throws -> any MEFormatReader {
        MKVFormatReader(source: primaryByteSource)
    }
}

final class MKVFormatReader: NSObject, MEFormatReader {
    private let source: MEByteSource
    private var parsed: (duration: CMTime, tracks: [TrackData])?
    private let lock = NSLock()

    init(source: MEByteSource) { self.source = source }

    private func load() throws -> (duration: CMTime, tracks: [TrackData]) {
        lock.lock(); defer { lock.unlock() }
        if let p = parsed { return p }
        let mkv = try MatroskaFile(source: ByteAdapter(source))
        var tracks: [TrackData] = []
        for t in mkv.tracks {
            guard let blocks = mkv.blocks[t.number], !blocks.isEmpty else { continue }
            if t.type == 1, let f = videoFormat(t) {
                let d = TrackData(number: t.number, mediaType: kCMMediaType_Video, format: f, info: t); d.build(blocks); tracks.append(d)
            } else if t.type == 2, let f = audioFormat(t) {
                let d = TrackData(number: t.number, mediaType: kCMMediaType_Audio, format: f, info: t); d.build(blocks); tracks.append(d)
            }
        }
        guard !tracks.isEmpty else { throw MEError(.unsupportedFeature) }
        let result = (CMTime(seconds: mkv.duration, preferredTimescale: 1_000_000), tracks)
        parsed = result
        return result
    }

    func loadFileInfo(completionHandler: @escaping (MEFileInfo?, (any Error)?) -> Void) {
        do {
            let p = try load()
            let info = MEFileInfo()
            info.duration = p.duration
            completionHandler(info, nil)
        } catch { completionHandler(nil, error) }
    }

    func loadMetadata(completionHandler: @escaping ([AVMetadataItem]?, (any Error)?) -> Void) { completionHandler([], nil) }

    func loadTrackReaders(completionHandler: @escaping ([any METrackReader]?, (any Error)?) -> Void) {
        do {
            let p = try load()
            completionHandler(p.tracks.map { MKVTrackReader(track: $0, source: source) }, nil)
        } catch { completionHandler(nil, error) }
    }
}

private final class MKVTrackReader: NSObject, METrackReader {
    let track: TrackData
    let source: MEByteSource
    init(track: TrackData, source: MEByteSource) { self.track = track; self.source = source }

    func loadTrackInfo(completionHandler: @escaping (METrackInfo?, (any Error)?) -> Void) {
        let info = METrackInfo(__mediaType: track.mediaType, trackID: CMPersistentTrackID(track.number), formatDescriptions: [track.format])
        info.isEnabled = true
        info.naturalTimescale = 1_000_000
        if track.mediaType == kCMMediaType_Video {
            info.naturalSize = CGSize(width: track.info.width, height: track.info.height)
            info.nominalFrameRate = track.info.defaultDuration > 0 ? Float(1 / track.info.defaultDuration) : 0
            info.requiresFrameReordering = track.requiresReordering
        }
        completionHandler(info, nil)
    }

    func generateSampleCursor(atPresentationTimeStamp presentationTimeStamp: CMTime,
                              completionHandler: @escaping ((any MESampleCursor)?, (any Error)?) -> Void) {
        var lo = 0, hi = track.presentationOrder.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if track.samples[track.presentationOrder[mid]].pts <= presentationTimeStamp { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        completionHandler(MKVCursor(track: track, source: source, index: track.presentationOrder[best]), nil)
    }

    func generateSampleCursorAtFirstSampleInDecodeOrder(completionHandler: @escaping ((any MESampleCursor)?, (any Error)?) -> Void) {
        completionHandler(MKVCursor(track: track, source: source, index: 0), nil)
    }

    func generateSampleCursorAtLastSampleInDecodeOrder(completionHandler: @escaping ((any MESampleCursor)?, (any Error)?) -> Void) {
        completionHandler(MKVCursor(track: track, source: source, index: track.samples.count - 1), nil)
    }

    func loadTotalSampleDataLength(completionHandler: @escaping (Int64, (any Error)?) -> Void) {
        completionHandler(track.samples.reduce(0) { $0 + Int64($1.size) }, nil)
    }

    func loadUneditedDuration(completionHandler: @escaping (CMTime, (any Error)?) -> Void) {
        let last = track.presentationOrder.last.map { track.samples[$0] }
        completionHandler(last.map { $0.pts + $0.duration } ?? .invalid, nil)
    }
}

private final class MKVCursor: NSObject, MESampleCursor {
    let track: TrackData
    let source: MEByteSource
    var index: Int

    init(track: TrackData, source: MEByteSource, index: Int) { self.track = track; self.source = source; self.index = index }

    private var sample: Sample { track.samples[index] }

    var presentationTimeStamp: CMTime { sample.pts }
    var decodeTimeStamp: CMTime { sample.dts }
    var currentSampleDuration: CMTime { sample.duration }
    var currentSampleFormatDescription: CMFormatDescription? { track.format }

    func copy(with zone: NSZone? = nil) -> Any { MKVCursor(track: track, source: source, index: index) }

    func stepInDecodeOrder(by stepCount: Int64, completionHandler: @escaping (Int64, (any Error)?) -> Void) {
        let target = max(0, min(track.samples.count - 1, index + Int(stepCount)))
        let actual = Int64(target - index)
        index = target
        completionHandler(actual, nil)
    }

    func stepInPresentationOrder(by stepCount: Int64, completionHandler: @escaping (Int64, (any Error)?) -> Void) {
        let r = track.rank[index]
        let target = max(0, min(track.samples.count - 1, r + Int(stepCount)))
        let actual = Int64(target - r)
        index = track.presentationOrder[target]
        completionHandler(actual, nil)
    }

    func stepByDecodeTime(_ deltaDecodeTime: CMTime, completionHandler: @escaping (CMTime, Bool, (any Error)?) -> Void) {
        let want = sample.dts + deltaDecodeTime
        var lo = 0, hi = track.samples.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if track.samples[mid].dts <= want { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let pinned = (best == 0 && want < track.samples[0].dts) || (best == track.samples.count - 1 && want > track.samples[best].dts + track.samples[best].duration)
        index = best
        completionHandler(sample.dts, pinned, nil)
    }

    func stepByPresentationTime(_ deltaPresentationTime: CMTime, completionHandler: @escaping (CMTime, Bool, (any Error)?) -> Void) {
        let want = sample.pts + deltaPresentationTime
        var lo = 0, hi = track.presentationOrder.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if track.samples[track.presentationOrder[mid]].pts <= want { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let last = track.samples[track.presentationOrder[track.presentationOrder.count - 1]]
        let pinned = (best == 0 && want < track.samples[track.presentationOrder[0]].pts) || (best == track.presentationOrder.count - 1 && want > last.pts + last.duration)
        index = track.presentationOrder[best]
        completionHandler(sample.pts, pinned, nil)
    }

    var syncInfo: AVSampleCursorSyncInfo {
        AVSampleCursorSyncInfo(sampleIsFullSync: ObjCBool(sample.key), sampleIsPartialSync: false, sampleIsDroppable: false)
    }

    var dependencyInfo: AVSampleCursorDependencyInfo {
        AVSampleCursorDependencyInfo(sampleIndicatesWhetherItHasDependentSamples: false, sampleHasDependentSamples: false,
                                     sampleIndicatesWhetherItDependsOnOthers: true, sampleDependsOnOthers: ObjCBool(!sample.key),
                                     sampleIndicatesWhetherItHasRedundantCoding: false, sampleHasRedundantCoding: false)
    }

    func sampleLocation() throws -> MESampleLocation {
        MESampleLocation(byteSource: source, sampleLocation: AVSampleCursorStorageRange(offset: sample.offset, length: Int64(sample.size)))
    }

    func chunkDetails() throws -> MESampleCursorChunk {
        MESampleCursorChunk(byteSource: source, chunkStorageRange: AVSampleCursorStorageRange(offset: sample.offset, length: Int64(sample.size)),
                            chunkInfo: AVSampleCursorChunkInfo(chunkSampleCount: 1, chunkHasUniformSampleSizes: true,
                                                               chunkHasUniformSampleDurations: true, chunkHasUniformFormatDescriptions: true),
                            sampleIndexWithinChunk: 0)
    }
}
