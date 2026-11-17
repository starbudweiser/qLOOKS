// qLOOKS — source d'images par FFmpeg réduit (LGPL, statique) pour les formats que macOS ne lit pas :
// WebM/MKV à codec exotique (VP8, MPEG-4…), AVI, WMV/ASF, FLV, OGV, RealMedia, MXF… Décodage logiciel, une image à la fois.
import CoreGraphics
import Foundation

final class FFSource: FrameSource, @unchecked Sendable {
    static let extensions: Set<String> = ["avi", "wmv", "asf", "flv", "f4v", "ogv", "ogm", "rm", "rmvb", "mxf", "gxf", "divx", "webm", "mkv"]
    static func handles(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    private let lock = NSLock()
    private var fmt: UnsafeMutablePointer<AVFormatContext>?
    private var ctx: UnsafeMutablePointer<AVCodecContext>?
    private var sws: UnsafeMutablePointer<SwsContext>?
    private var pkt: UnsafeMutablePointer<AVPacket>?
    private var frm: UnsafeMutablePointer<AVFrame>?
    private var stream: Int32 = 0
    private var timeBase = 0.0
    private var startPTS: Int64 = 0
    private var lastIndex = -2                       // dernière image rendue, pour enchaîner sans se repositionner
    private var cache: (Int, CGImage)?

    private(set) var pixelSize = CGSize.zero
    private(set) var frameCount = 1
    private(set) var frameDuration = 1.0 / 25
    let hasAlpha = false
    var randomAccess: Bool { false }
    private(set) var codecName = ""

    init(url: URL) throws {
        av_log_set_level(-8) /* AV_LOG_QUIET */
        pkt = av_packet_alloc(); frm = av_frame_alloc()
        guard pkt != nil, frm != nil else { throw FrameError.unreadable }
        var f: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&f, url.path, nil, nil) == 0, let f else { throw FrameError.unreadable }
        fmt = f
        guard avformat_find_stream_info(f, nil) >= 0 else { close(); throw FrameError.unreadable }
        var codec: UnsafePointer<AVCodec>?
        let s = av_find_best_stream(f, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0)
        guard s >= 0, let codec, let st = f.pointee.streams[Int(s)], let par = st.pointee.codecpar else { close(); throw FrameError.unsupported(url.pathExtension) }
        stream = s
        guard let c = avcodec_alloc_context3(codec), avcodec_parameters_to_context(c, par) >= 0 else { close(); throw FrameError.unreadable }
        c.pointee.thread_count = 0
        guard avcodec_open2(c, codec, nil) == 0 else { avcodec_free_context(&ctx); close(); throw FrameError.unsupported(String(cString: avcodec_get_name(par.pointee.codec_id))) }
        ctx = c
        codecName = String(cString: avcodec_get_name(par.pointee.codec_id)).uppercased()
        timeBase = av_q2d(st.pointee.time_base)
        startPTS = st.pointee.start_time == Int64.min ? 0 : st.pointee.start_time
        var fps = av_q2d(st.pointee.avg_frame_rate)
        if fps <= 0 || fps > 1000 { fps = av_q2d(st.pointee.r_frame_rate) }
        if fps <= 0 || fps > 1000 { fps = 25 }
        frameDuration = 1 / fps
        var seconds = st.pointee.duration > 0 ? Double(st.pointee.duration) * timeBase : Double(f.pointee.duration) / 1_000_000
        if !(seconds > 0) { seconds = frameDuration }
        frameCount = max(1, Int((seconds * fps).rounded()))
        let sar = st.pointee.sample_aspect_ratio.num > 0 && st.pointee.sample_aspect_ratio.den > 0 ? av_q2d(st.pointee.sample_aspect_ratio) : 1
        pixelSize = CGSize(width: (Double(par.pointee.width) * sar).rounded(), height: Double(par.pointee.height))
        guard pixelSize.width > 0, pixelSize.height > 0 else { close(); throw FrameError.unreadable }
    }

    deinit { close() }

    private func close() {
        if sws != nil { sws_freeContext(sws); sws = nil }
        if ctx != nil { avcodec_free_context(&ctx) }
        if fmt != nil { avformat_close_input(&fmt) }
        av_packet_free(&pkt); av_frame_free(&frm)
    }

    func frame(_ index: Int) throws -> CGImage {
        lock.lock(); defer { lock.unlock() }
        let i = min(max(index, 0), frameCount - 1)
        if let c = cache, c.0 == i { return c.1 }
        let target = Int64(Double(i) * frameDuration / timeBase) + startPTS
        let tolerance = Int64(frameDuration / timeBase / 2)
        if i != lastIndex + 1 {
            av_seek_frame(fmt, stream, target, AVSEEK_FLAG_BACKWARD)
            avcodec_flush_buffers(ctx)
        }
        var reads = 0
        while reads < 100_000 {
            reads += 1
            let r = avcodec_receive_frame(ctx, frm)
            if r == 0 {
                let pts = frm!.pointee.best_effort_timestamp == Int64.min ? target : frm!.pointee.best_effort_timestamp
                if pts + tolerance >= target {
                    let img = try image(frm!); av_frame_unref(frm)
                    lastIndex = i; cache = (i, img); return img
                }
                av_frame_unref(frm)
                continue
            }
            if r == -EAGAIN {
                let e = av_read_frame(fmt, pkt)
                if e < 0 { avcodec_send_packet(ctx, nil); continue }
                if pkt!.pointee.stream_index == stream { avcodec_send_packet(ctx, pkt) }
                av_packet_unref(pkt)
                continue
            }
            break
        }
        // Fin de fichier : on rend la dernière image décodable plutôt qu'une erreur.
        if let c = cache { return c.1 }
        throw FrameError.unreadable
    }

    private func image(_ f: UnsafeMutablePointer<AVFrame>) throws -> CGImage {
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        sws = sws_getCachedContext(sws, f.pointee.width, f.pointee.height, AVPixelFormat(rawValue: f.pointee.format),
                                   Int32(w), Int32(h), AV_PIX_FMT_BGRA, 2 /* SWS_BILINEAR */, nil, nil, nil)
        guard let sws else { throw FrameError.unreadable }
        let stride = w * 4
        var data = Data(count: stride * h)
        let ok: Bool = data.withUnsafeMutableBytes { raw in
            var dst: [UnsafeMutablePointer<UInt8>?] = [raw.bindMemory(to: UInt8.self).baseAddress, nil, nil, nil]
            var dstStride: [Int32] = [Int32(stride), 0, 0, 0]
            let src = withUnsafePointer(to: &f.pointee.data) { $0.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { Array(UnsafeBufferPointer(start: $0, count: 8)) } }
            let srcStride = withUnsafePointer(to: &f.pointee.linesize) { $0.withMemoryRebound(to: Int32.self, capacity: 8) { Array(UnsafeBufferPointer(start: $0, count: 8)) } }
            return sws_scale(sws, src, srcStride, 0, f.pointee.height, &dst, &dstStride) > 0
        }
        guard ok, let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw FrameError.unreadable }
        return img
    }
}
