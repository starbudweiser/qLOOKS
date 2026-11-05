// aLPHALOOK — décodeur du codec QuickTime Animation (« rle »), profondeurs 32 (ARVB), 24 (RVB) et 16 bits (RVB 555).
// Chaque image ne décrit que les lignes qui changent : le décodeur garde l'image précédente et la met à jour.
import CoreGraphics
import Foundation

final class QTRLEDecoder {
    let width: Int, height: Int, depth: Int
    private var buffer: [UInt8]          // A, R, V, B par pixel

    init?(width: Int, height: Int, depth: Int) {
        guard [16, 24, 32].contains(depth), width > 0, height > 0 else { return nil }
        self.width = width; self.height = height; self.depth = depth
        buffer = [UInt8](repeating: 0, count: width * height * 4)
    }

    func reset() { buffer.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0, $0.count) } }

    func decode(_ data: [UInt8]) {
        guard data.count >= 8 else { return }            // image inchangée
        var p = 4                                         // taille du bloc, ignorée
        let header = Int(data[p]) << 8 | Int(data[p + 1]); p += 2
        var start = 0, lines = height
        if header & 0x0008 != 0 {
            guard data.count >= 14 else { return }
            start = Int(data[p]) << 8 | Int(data[p + 1]); p += 4
            lines = Int(data[p]) << 8 | Int(data[p + 1]); p += 4
            guard start + lines <= height else { return }
        }
        let bpp = depth / 8, stride = width * 4
        buffer.withUnsafeMutableBufferPointer { out in
            data.withUnsafeBufferPointer { src in
                let n = src.count
                @inline(__always) func pixel(_ q: Int, _ o: Int) {
                    switch bpp {
                    case 4: out[o] = src[q]; out[o + 1] = src[q + 1]; out[o + 2] = src[q + 2]; out[o + 3] = src[q + 3]
                    case 3: out[o] = 255; out[o + 1] = src[q]; out[o + 2] = src[q + 1]; out[o + 3] = src[q + 2]
                    default:
                        let v = Int(src[q]) << 8 | Int(src[q + 1])
                        let r = (v >> 10) & 31, g = (v >> 5) & 31, b = v & 31
                        out[o] = 255; out[o + 1] = UInt8(r << 3 | r >> 2); out[o + 2] = UInt8(g << 3 | g >> 2); out[o + 3] = UInt8(b << 3 | b >> 2)
                    }
                }
                var row = start * stride
                for _ in 0..<lines {
                    guard p < n else { return }
                    let limit = row + stride
                    var px = row + (Int(src[p]) - 1) * 4; p += 1
                    while p < n {
                        let code = Int(Int8(bitPattern: src[p])); p += 1
                        if code == -1 { break }
                        if code == 0 {
                            guard p < n else { return }
                            px += (Int(src[p]) - 1) * 4; p += 1
                        } else if code < 0 {
                            guard p + bpp <= n else { return }
                            for _ in 0..<(-code) {
                                guard px >= row, px + 4 <= limit else { return }
                                pixel(p, px); px += 4
                            }
                            p += bpp
                        } else {
                            for _ in 0..<code {
                                guard p + bpp <= n, px >= row, px + 4 <= limit else { return }
                                pixel(p, px); px += 4; p += bpp
                            }
                        }
                    }
                    row += stride
                }
            }
        }
    }

    /// Copie de l'image courante (alpha non prémultiplié, comme dans le fichier).
    func image() -> CGImage? {
        let data = Data(buffer) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let alpha: CGImageAlphaInfo = depth == 32 ? .first : .noneSkipFirst
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
