// qLOOKS — polices (ttf, otf, ttc, otc, dfont) : aperçu et vignette rendus par CoreText depuis le fichier,
// sans jamais activer ni installer la police (CTFontManagerCreateFontDescriptorsFromURL ne l'enregistre pas).
import AppKit
import CoreText

enum FontFile {
    static let exts: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont"]
    static func handles(_ url: URL) -> Bool { exts.contains(url.pathExtension.lowercased()) }

    struct Face {
        let descriptor: CTFontDescriptor
        func font(_ size: CGFloat) -> CTFont { CTFontCreateWithFontDescriptor(descriptor, size, nil) }
        var family: String { name(kCTFontFamilyNameKey) ?? "" }
        var style: String { name(kCTFontStyleNameKey) ?? "" }
        var full: String { name(kCTFontFullNameKey) ?? family }
        func name(_ key: CFString) -> String? { CTFontCopyName(font(12), key) as String? }
        var glyphCount: Int { CTFontGetGlyphCount(font(12)) }
    }

    /// Toutes les fontes du fichier (une seule pour un .ttf/.otf, plusieurs pour une collection).
    static func faces(_ url: URL) -> [Face] {
        guard let arr = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return [] }
        return arr.map { Face(descriptor: $0) }
    }

    static let pangram = "Portez ce vieux whisky au juge blond qui fume"
    static let pangramEN = "The quick brown fox jumps over the lazy dog"
    static let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    static let lower = "abcdefghijklmnopqrstuvwxyz"
    static let digits = "0123456789  ! ? & @ # % € $ £ ( ) [ ] { } « » — – … ; : / \\"
    static let accents = "àâäçéèêëîïôöùûüÿœæ ÀÂÄÇÉÈÊËÎÏÔÖÙÛÜŸŒÆ ñ ß ø å"

    // MARK: Couleurs neutres (fond clair, texte sombre)
    static let paper = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.955, alpha: 1)
    static let ink = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
    static let muted = NSColor(srgbRed: 0.45, green: 0.45, blue: 0.47, alpha: 1)

    static func attr(_ s: String, _ font: CTFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, .foregroundColor: color])
    }

    /// Texte qui tient dans une largeur : la taille est réduite jusqu'à ce qu'il tienne sur une ligne.
    static func fitSize(_ s: String, face: Face, size: CGFloat, width: CGFloat) -> CGFloat {
        var sz = size
        while sz > 6 {
            let w = attr(s, face.font(sz), ink).size().width
            if w <= width { break }
            sz *= 0.92
        }
        return sz
    }

    // MARK: Vignette
    /// Dessine la vignette dans le contexte courant (origine en bas à gauche) : « Aa » et nom de la famille.
    static func drawThumbnail(_ face: Face, in rect: CGRect) {
        paper.setFill(); rect.fill()
        let w = rect.width, h = rect.height
        let pad = max(2, w * 0.08)
        let showName = h >= 70
        // « Aa » : le plus grand possible dans la zone haute.
        let zone = CGRect(x: rect.minX + pad, y: rect.minY + (showName ? h * 0.30 : pad), width: w - 2 * pad, height: h * (showName ? 0.62 : 1) - (showName ? 0 : 2 * pad))
        let sample = "Aa"
        var sz = min(zone.height * 0.78, zone.width * 0.62)
        sz = fitSize(sample, face: face, size: sz, width: zone.width)
        let aa = attr(sample, face.font(sz), ink)
        let s = aa.size()
        // Centrage sur la hauteur des majuscules plutôt que sur la ligne complète (rendu plus équilibré).
        let capH = CTFontGetCapHeight(face.font(sz))
        let base = zone.midY - capH / 2
        aa.draw(at: CGPoint(x: zone.midX - s.width / 2, y: base - CTFontGetDescent(face.font(sz)) - CTFontGetLeading(face.font(sz))))
        guard showName else { return }
        let ns = max(8, min(h * 0.075, 22))
        let label = face.family.isEmpty ? face.full : face.family
        let sys = CTFontCreateWithName("Helvetica Neue" as CFString, ns, nil)
        let nameAttr = attr(label, sys, muted)
        let nw = nameAttr.size().width
        var line = nameAttr
        if nw > w - 2 * pad {
            let k = (w - 2 * pad) / nw
            line = attr(label, CTFontCreateWithName("Helvetica Neue" as CFString, max(6, ns * k), nil), muted)
        }
        let ls = line.size()
        line.draw(at: CGPoint(x: rect.midX - ls.width / 2, y: rect.minY + h * 0.10))
        if h >= 110, !face.style.isEmpty {
            let st = attr(face.style, CTFontCreateWithName("Helvetica Neue" as CFString, ns * 0.85, nil), muted.withAlphaComponent(0.8))
            let ss = st.size()
            st.draw(at: CGPoint(x: rect.midX - ss.width / 2, y: rect.minY + h * 0.10 - ss.height - 1))
        }
    }

    /// Image de la vignette (carrée) pour un fichier : première fonte de la collection.
    static func thumbnailFace(_ url: URL) -> Face? { faces(url).first }
}

/// Page d'aperçu : en-tête (nom, style), alphabet, chiffres, pangramme, corps de texte, dessinée en vue défilante.
final class FontSheetView: NSView {
    private let faces: [FontFile.Face]
    private let fileName: String
    private var contentHeight: CGFloat = 800
    override var isFlipped: Bool { true }

    init(faces: [FontFile.Face], fileName: String) {
        self.faces = faces; self.fileName = fileName
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 800))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        FontFile.paper.setFill(); bounds.fill()
        var y: CGFloat = 28
        let x: CGFloat = 36
        let w = bounds.width - 2 * x
        let sys = { (s: CGFloat) in CTFontCreateWithName("Helvetica Neue" as CFString, s, nil) }
        let sysB = { (s: CGFloat) in CTFontCreateWithName("HelveticaNeue-Bold" as CFString, s, nil) }

        func para(_ text: String, _ font: CTFont, _ color: NSColor = FontFile.ink, lead: CGFloat = 1.25) {
            let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byWordWrapping
            let a = NSMutableAttributedString(attributedString: FontFile.attr(text, font, color))
            a.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: a.length))
            let r = a.boundingRect(with: NSSize(width: w, height: 10_000), options: [.usesLineFragmentOrigin])
            a.draw(with: NSRect(x: x, y: y, width: w, height: ceil(r.height) + 2), options: [.usesLineFragmentOrigin])
            y += ceil(r.height) + 6 * lead
        }
        func label(_ s: String) {
            y += 10
            FontFile.attr(s.uppercased(), sysB(10), FontFile.muted).draw(at: CGPoint(x: x, y: y)); y += 18
        }
        func rule() { FontFile.muted.withAlphaComponent(0.25).setFill(); NSRect(x: x, y: y, width: w, height: 1).fill(); y += 14 }

        for (i, face) in faces.enumerated() {
            if i > 0 { y += 20; rule() }
            let title = face.full.isEmpty ? fileName : face.full
            para(title, face.font(40))
            var meta = [face.family, face.style].filter { !$0.isEmpty }.joined(separator: " — ")
            meta += (meta.isEmpty ? "" : "  ·  ") + L.t("font.glyphs", face.glyphCount)
            meta += "  ·  " + fileName
            para(meta, sys(12), FontFile.muted)
            for (k, key) in [("font.designer", kCTFontDesignerNameKey), ("font.license", kCTFontLicenseNameKey), ("font.copyright", kCTFontCopyrightNameKey)] {
                if let v = face.name(key), !v.isEmpty { para(L.t(k) + " : " + String(v.prefix(200)), sys(11), FontFile.muted, lead: 0.5) }
            }
            rule()
            label(L.t("font.alphabet"))
            para(FontFile.upper, face.font(34)); para(FontFile.lower, face.font(34))
            para(FontFile.accents, face.font(26))
            label(L.t("font.digits"))
            para("0123456789", face.font(34)); para(FontFile.digits, face.font(22))
            label(L.t("font.pangram"))
            para(FontFile.pangram, face.font(28)); para(FontFile.pangramEN, face.font(28))
            label(L.t("font.sizes"))
            for sz in [12, 14, 18, 24, 36] as [CGFloat] {
                para("\(Int(sz)) pt — " + FontFile.pangramEN + ". " + FontFile.pangram + ".", face.font(sz), lead: 0.6)
            }
        }
        let needed = y + 30
        if abs(needed - contentHeight) > 1 {
            contentHeight = needed
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setFrameSize(NSSize(width: self.frame.width, height: self.contentHeight))
            }
        }
    }
}
