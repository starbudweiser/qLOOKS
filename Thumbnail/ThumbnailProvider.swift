// qLOOKS — extension de vignettes QuickLook pour les .MOV : image la plus « remplie » de la vidéo, sur le fond choisi.
import CoreGraphics
import QuickLookThumbnailing

@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL, maxSize = request.maximumSize
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
