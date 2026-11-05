// qLOOKS — extension de décodage vidéo (MediaExtension) : PNG et Animation, pour que macOS lise ces codecs partout
// (aperçu Quick Look d'Apple, QuickTime Player…). Sortie en BGRA avec alpha prémultiplié.
import CoreMedia
import CoreVideo
import CoreGraphics
import Foundation
import ImageIO
import MediaExtension

enum DecodeFailure: Error { case badData, noBuffer, unsupported }

/// Octets d'un échantillon vidéo.
private func bytes(of sample: CMSampleBuffer) throws -> [UInt8] {
    guard let block = CMSampleBufferGetDataBuffer(sample) else { throw DecodeFailure.badData }
    let n = CMBlockBufferGetDataLength(block)
    var out = [UInt8](repeating: 0, count: n)
    let status = out.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
    guard status == kCMBlockBufferNoErr else { throw DecodeFailure.badData }
    return out
}

private func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
    guard let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]], let a = arr.first else { return true }
    return (a[kCMSampleAttachmentKey_NotSync] as? Bool) != true
}

class BaseDecoder: NSObject, MEVideoDecoder {
    let manager: MEVideoDecoderPixelBufferManager
    let width: Int, height: Int

    init(format: CMVideoFormatDescription, manager: MEVideoDecoderPixelBufferManager) {
        let d = CMVideoFormatDescriptionGetDimensions(format)
        width = Int(d.width); height = Int(d.height)
        self.manager = manager
        super.init()
        manager.pixelBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
    }

    var isReadyForMoreMediaData: Bool { true }
    var contentHasInterframeDependencies: Bool { false }

    func canAccept(_ formatDescription: CMFormatDescription) -> Bool { true }

    /// Dessine l'image décodée dans un tampon BGRA fourni par le système.
    func render(_ image: CGImage) throws -> CVPixelBuffer {
        let pb = try manager.makePixelBuffer()
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw DecodeFailure.noBuffer }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)))
        return pb
    }

    func image(from sample: CMSampleBuffer) throws -> CGImage { throw DecodeFailure.unsupported }

    func decodeFrame(from sampleBuffer: CMSampleBuffer, options: MEDecodeFrameOptions,
                     completionHandler: @escaping (CVImageBuffer?, MEDecodeFrameStatus, Error?) -> Void) {
        do {
            let img = try image(from: sampleBuffer)
            if options.doNotOutputFrame { completionHandler(nil, .frameDropped, nil); return }
            completionHandler(try render(img), [], nil)
        } catch {
            completionHandler(nil, [], error)
        }
    }
}

final class PNGFrameDecoder: BaseDecoder {
    override func image(from sample: CMSampleBuffer) throws -> CGImage {
        let data = Data(try bytes(of: sample))
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw DecodeFailure.badData }
        return img
    }
}

final class AnimationFrameDecoder: BaseDecoder {
    private let rle: QTRLEDecoder

    init?(format: CMVideoFormatDescription, manager: MEVideoDecoderPixelBufferManager, depth: Int) {
        let d = CMVideoFormatDescriptionGetDimensions(format)
        guard let r = QTRLEDecoder(width: Int(d.width), height: Int(d.height), depth: depth) else { return nil }
        rle = r
        super.init(format: format, manager: manager)
    }

    override var contentHasInterframeDependencies: Bool { true }

    override func image(from sample: CMSampleBuffer) throws -> CGImage {
        if isKeyFrame(sample) { rle.reset() }
        rle.decode(try bytes(of: sample))
        guard let img = rle.image() else { throw DecodeFailure.badData }
        return img
    }
}

@objc(DecoderExtension)
final class DecoderExtension: NSObject, MEVideoDecoderExtension {
    override init() { super.init() }

    func makeVideoDecoder(codecType: CMVideoCodecType, videoFormatDescription: CMVideoFormatDescription,
                          videoDecoderSpecifications: [String: Any], pixelBufferManager: MEVideoDecoderPixelBufferManager) throws -> any MEVideoDecoder {
        switch codecType {
        case 0x706E6720:                                   // 'png '
            return PNGFrameDecoder(format: videoFormatDescription, manager: pixelBufferManager)
        case 0x726C6520:                                   // 'rle '
            let ext = CMFormatDescriptionGetExtensions(videoFormatDescription) as? [String: Any] ?? [:]
            let depth = ext[kCMFormatDescriptionExtension_Depth as String] as? Int ?? 32
            guard let d = AnimationFrameDecoder(format: videoFormatDescription, manager: pixelBufferManager, depth: depth) else {
                throw MEError(.unsupportedFeature)
            }
            return d
        default:
            throw MEError(.unsupportedFeature)
        }
    }
}
