// qLOOKS — images vectorielles : SVG (rendu CoreSVG du système) et EPS (aperçu TIFF intégré au fichier DOS EPS).
import AppKit
import ImageIO

enum VectorImage {
    static let svgExtensions: Set<String> = ["svg", "svgz"]
    static let epsExtensions: Set<String> = ["eps", "epsf", "epsi"]
    static let aiExtensions: Set<String> = ["ai"]

    static func handles(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return svgExtensions.contains(e) || epsExtensions.contains(e) || aiExtensions.contains(e)
    }

    /// Taille d'origine (en points) du dessin.
    static func size(of url: URL) -> CGSize? {
        if isSVG(url) {
            guard let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 else { return nil }
            return img.size
        }
        if let ai = aiRenderer(url) { return ai.bounds.size }
        guard let p = epsPreview(url) else { return nil }
        return CGSize(width: p.width, height: p.height)
    }

    /// Image au plus `maxPixel` pixels de côté, fond transparent.
    static func render(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        if isSVG(url) { return renderSVG(url, maxPixel: maxPixel) }
        let isAI = aiExtensions.contains(url.pathExtension.lowercased())
        if let pdf = renderPDF(url, maxPixel: maxPixel) { return pdf }
        // Dessin exécuté par notre moteur ; pour un EPS, on garde l'aperçu intégré si le dessin est incomplet (texte, dégradés).
        if let ai = aiRenderer(url), let img = ai.render(maxPixel: maxPixel) {
            if isAI || ai.complete { return img }
            return epsPreview(url) ?? img
        }
        return epsPreview(url)
    }

    /// Partie PostScript d'un fichier : tout le fichier, ou la section indiquée par l'en-tête d'un EPS « DOS ».
    private static func aiRenderer(_ url: URL) -> AIRenderer? {
        guard var data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 16 else { return nil }
        if [UInt8](data.prefix(4)) == [0xC5, 0xD0, 0xD3, 0xC6] {
            func u32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(data[data.startIndex + at + $1]) << (8 * $1) } }
            let off = u32(4), len = u32(8)
            guard off >= 0, len > 0, off + len <= data.count else { return nil }
            data = data.subdata(in: (data.startIndex + off)..<(data.startIndex + off + len))
        }
        return AIRenderer(postscript: data)
    }

    /// AI récents (et autres) : le fichier commence par un PDF.
    private static func renderPDF(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let h = try? FileHandle(forReadingFrom: url), let head = try? h.read(upToCount: 5), head == Data("%PDF-".utf8) else { return nil }
        try? h.close()
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let k = maxPixel / max(box.width, box.height)
        let w = max(1, Int((box.width * k).rounded())), hh = max(1, Int((box.height * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: hh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: hh), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    private static func isSVG(_ url: URL) -> Bool { svgExtensions.contains(url.pathExtension.lowercased()) }

    private static func renderSVG(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 else { return nil }
        let k = maxPixel / max(img.size.width, img.size.height)
        let w = max(1, Int((img.size.width * k).rounded())), h = max(1, Int((img.size.height * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// EPS « DOS » (en-tête C5 D0 D3 C6) : le fichier porte un aperçu TIFF à l'adresse indiquée dans l'en-tête.
    private static func epsPreview(_ url: URL) -> CGImage? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 30), head.count == 30,
              [UInt8](head.prefix(4)) == [0xC5, 0xD0, 0xD3, 0xC6] else { return nil }
        func u32(_ at: Int) -> UInt64 { (0..<4).reduce(0) { $0 | UInt64(head[at + $1]) << (8 * UInt64($1)) } }
        let off = u32(20), len = u32(24)
        guard len > 0, len < 200 << 20, (try? h.seek(toOffset: off)) != nil, let data = try? h.read(upToCount: Int(len)),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
