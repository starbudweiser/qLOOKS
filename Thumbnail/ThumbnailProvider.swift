// qLOOKS — extension de vignettes QuickLook pour les .MOV : image la plus « remplie » de la vidéo, sur le fond choisi.
import AppKit
import CoreGraphics
import QuickLookThumbnailing

@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL, maxSize = request.maximumSize
        if FontFile.handles(url) {
            guard let face = FontFile.thumbnailFace(url) else { handler(nil, FrameError.unreadable); return }
            let side = min(maxSize.width, maxSize.height)
            let size = CGSize(width: side, height: side)
            handler(QLThumbnailReply(contextSize: size) { ctx in
                // Le contexte est en pixels : on applique l'échelle si le système ne l'a pas déjà fait.
                let k = CGFloat(ctx.width) / size.width / max(ctx.ctm.a, 0.0001)
                if abs(k - 1) > 0.01 { ctx.scaleBy(x: k, y: k) }
                let g = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
                FontFile.drawThumbnail(face, in: CGRect(origin: .zero, size: size))
                NSGraphicsContext.restoreGraphicsState()
                return true
            }, nil)
            return
        }
        if Model3D.handles(url) {
            Task {
                guard let loaded = await Model3D.load(url) else { handler(nil, FrameError.unreadable); return }
                let side = max(maxSize.width, maxSize.height) * request.scale
                var image: CGImage?
                if let root = loaded.root { image = Model3D.snapshot(root, size: CGSize(width: side, height: side)) }
                else if let p = loaded.preview { image = p.cgImage(forProposedRect: nil, context: nil, hints: nil) }
                guard let image else { handler(nil, FrameError.unreadable); return }
                let fit = Backdrops.fit(CGSize(width: image.width, height: image.height), in: CGRect(origin: .zero, size: maxSize)).size
                handler(QLThumbnailReply(contextSize: fit) { ctx in
                    ctx.interpolationQuality = .high
                    ctx.draw(image, in: CGRect(origin: .zero, size: fit)); return true
                }, nil)
            }
            return
        }
        if EPUB.handles(url) {
            Task.detached {
                guard let image = EPUB.coverImage(url) else { handler(nil, FrameError.unreadable); return }
                let size = Backdrops.fit(CGSize(width: image.width, height: image.height), in: CGRect(origin: .zero, size: maxSize)).size
                handler(QLThumbnailReply(contextSize: size) { ctx in
                    ctx.interpolationQuality = .high
                    ctx.draw(image, in: CGRect(origin: .zero, size: size)); return true
                }, nil)
            }
            return
        }
        if VectorImage.handles(url) {
            let px = max(maxSize.width, maxSize.height) * request.scale
            guard let image = VectorImage.render(url, maxPixel: px) else { handler(nil, FrameError.unreadable); return }
            let size = Backdrops.fit(CGSize(width: image.width, height: image.height), in: CGRect(origin: .zero, size: maxSize)).size
            handler(QLThumbnailReply(contextSize: size) { ctx in
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(origin: .zero, size: size))
                return true
            }, nil)
            return
        }
        Task {
            do {
                let src = try await Sources.open(url)
                let image = try Representative.frame(src)
                let rect = Backdrops.fit(src.pixelSize, in: CGRect(origin: .zero, size: maxSize))
                let size = rect.size
                let alpha = src.hasAlpha, backdrop = Prefs.backdrop
                let reply = QLThumbnailReply(contextSize: size) { ctx in
                    let r = CGRect(origin: .zero, size: size)
                    if alpha { Backdrops.draw(backdrop, in: ctx, rect: r, square: max(3, (size.width / 16).rounded())) }
                    ctx.interpolationQuality = .high
                    ctx.draw(image, in: r)
                    return true
                }
                handler(reply, nil)
            } catch {
                handler(nil, error)
            }
        }
    }
}
