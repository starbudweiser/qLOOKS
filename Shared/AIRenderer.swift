// qLOOKS — moteur de rendu pour les fichiers Illustrator « PostScript » (.ai des versions 3 à 8, exports FreeHand,
// EPS Illustrator). Le corps de ces fichiers n'utilise qu'un petit jeu d'opérateurs (m l c v y h f s b n, couleurs, groupes,
// tracés composés, masques d'écrêtage) : on les exécute directement, sans interpréteur PostScript.
import CoreGraphics
import Foundation

final class AIRenderer {
    /// Cadre du dessin, en points PostScript.
    let bounds: CGRect
    /// Faux quand le fichier utilise des éléments non gérés (dégradés, motifs, images) : le rendu est alors approximatif.
    private(set) var complete = true
    private(set) var paintCount = 0

    private let bytes: [UInt8]
    private let start: Int
    private let end: Int

    static func looksLikeAI(_ data: Data) -> Bool {
        let h = data.prefix(64)
        return h.starts(with: Array("%!PS-Adobe".utf8))
    }

    init?(postscript data: Data) {
        guard AIRenderer.looksLikeAI(data) else { return nil }
        bytes = [UInt8](data)
        guard let box = AIRenderer.boundingBox(bytes), box.width > 0, box.height > 0 else { return nil }
        bounds = box
        // Début du dessin : après l'initialisation (%%EndSetup, sinon %%EndProlog, sinon fin des commentaires).
        var s = 0
        for key in ["%%EndSetup", "%%EndProlog", "%%EndComments"] {
            if let r = AIRenderer.find(Array(key.utf8), in: bytes, from: 0) { s = r + key.utf8.count; break }
        }
        start = s
        end = AIRenderer.find(Array("%%PageTrailer".utf8), in: bytes, from: s) ?? AIRenderer.find(Array("%%Trailer".utf8), in: bytes, from: s) ?? bytes.count
    }

    // MARK: En-tête

    private static func find(_ pat: [UInt8], in b: [UInt8], from: Int) -> Int? {
        guard !pat.isEmpty, b.count >= pat.count, from <= b.count - pat.count else { return nil }
        var i = from
        let last = b.count - pat.count
        while i <= last {
            if b[i] == pat[0] {
                var k = 1
                while k < pat.count, b[i + k] == pat[k] { k += 1 }
                if k == pat.count { return i }
            }
            i += 1
        }
        return nil
    }

    private static func boundingBox(_ b: [UInt8]) -> CGRect? {
        let head = String(decoding: b.prefix(20000), as: UTF8.self)
        for key in ["%%HiResBoundingBox:", "%%BoundingBox:"] {
            guard let r = head.range(of: key) else { continue }
            let line = head[r.upperBound...].prefix { $0 != "\n" && $0 != "\r" }
            let v = line.split(separator: " ").compactMap { Double($0) }
            if v.count >= 4, v[2] > v[0], v[3] > v[1] { return CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1]) }
        }
        return nil
    }

    // MARK: Jetons

    private enum Tok { case num(Double), str([UInt8]), name(String), op(String), open, close }

    private func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 0 }
    private func isDelim(_ c: UInt8) -> Bool { c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93 || c == 123 || c == 125 || c == 47 || c == 37 }

    private var pos = 0

    private func skipLine() { while pos < end, bytes[pos] != 10, bytes[pos] != 13 { pos += 1 } }

    private func next() -> Tok? {
        while pos < end {
            let c = bytes[pos]
            if isSpace(c) { pos += 1; continue }
            if c == 37 {                                                   // commentaire
                if matches("%AI5_Begin_NonPrinting") { skipTo("%AI5_End_NonPrinting"); continue }
                if matches("%AI5_BeginGradient") || matches("%AI5_BeginPattern") || matches("%AI5_BeginBrushPattern") {
                    skipTo("%AI5_End"); continue
                }
                if matches("%%BeginData") || matches("%%BeginBinary") { complete = false; skipTo("%%EndData", alt: "%%EndBinary"); continue }
                skipLine(); continue
            }
            if c == 40 {                                                   // chaîne
                pos += 1
                var depth = 1, out: [UInt8] = []
                while pos < end, depth > 0 {
                    let d = bytes[pos]; pos += 1
                    if d == 92, pos < end {
                        let e = bytes[pos]; pos += 1
                        switch e {
                        case 110: out.append(10)
                        case 114: out.append(13)
                        case 116: out.append(9)
                        case 48...55:
                            var v = Int(e - 48), n = 1
                            while n < 3, pos < end, bytes[pos] >= 48, bytes[pos] <= 55 { v = v * 8 + Int(bytes[pos] - 48); pos += 1; n += 1 }
                            out.append(UInt8(v & 255))
                        case 10, 13: break
                        default: out.append(e)
                        }
                    } else if d == 40 { depth += 1; out.append(d) }
                    else if d == 41 { depth -= 1; if depth > 0 { out.append(d) } }
                    else { out.append(d) }
                }
                return .str(out)
            }
            if c == 60 {                                                   // chaîne hexadécimale ou dictionnaire : ignorée
                pos += 1
                if pos < end, bytes[pos] == 60 { pos += 1; continue }
                while pos < end, bytes[pos] != 62 { pos += 1 }
                pos += 1
                return .str([])
            }
            if c == 62 { pos += 1; continue }
            if c == 91 { pos += 1; return .open }
            if c == 93 { pos += 1; return .close }
            if c == 123 || c == 125 || c == 41 { pos += 1; continue }
            if c == 47 {                                                   // /nom
                pos += 1
                let s = pos
                while pos < end, !isSpace(bytes[pos]), !isDelim(bytes[pos]) { pos += 1 }
                return .name(String(decoding: bytes[s..<pos], as: UTF8.self))
            }
            let s = pos
            while pos < end, !isSpace(bytes[pos]), !isDelim(bytes[pos]) { pos += 1 }
            if pos == s { pos += 1; continue }
            let word = String(decoding: bytes[s..<pos], as: UTF8.self)
            if let v = Double(word) { return .num(v) }
            return .op(word)
        }
        return nil
    }

    private func matches(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard pos + u.count <= end else { return false }
        for i in 0..<u.count where bytes[pos + i] != u[i] { return false }
        return true
    }

    private func skipTo(_ s: String, alt: String? = nil) {
        let a = AIRenderer.find(Array(s.utf8), in: bytes, from: pos)
        let b = alt.flatMap { AIRenderer.find(Array($0.utf8), in: bytes, from: pos) }
        let hit = [a, b].compactMap { $0 }.min()
        pos = hit ?? end
        skipLine()
    }

    // MARK: Exécution

    private struct Style {
        var fill: CGColor?
        var stroke: CGColor?
        var width: CGFloat = 1
        var cap: CGLineCap = .butt
        var join: CGLineJoin = .miter
        var miter: CGFloat = 10
        var dash: [CGFloat] = []
        var phase: CGFloat = 0
        var evenOdd = false
    }

    private static let cmyk = CGColorSpace(name: CGColorSpace.genericCMYK) ?? CGColorSpaceCreateDeviceCMYK()
    private static let rgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let grayCS = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) ?? CGColorSpaceCreateDeviceGray()

    private func cmykColor(_ c: Double, _ m: Double, _ y: Double, _ k: Double) -> CGColor {
        let f = { (v: Double) in CGFloat(min(1, max(0, v))) }
        return CGColor(colorSpace: AIRenderer.cmyk, components: [f(c), f(m), f(y), f(k), 1]) ?? CGColor(gray: 0, alpha: 1)
    }

    /// Dessine tout le fichier dans `ctx` (origine du dessin à (0,0) de bounds).
    func draw(in ctx: CGContext) {
        pos = start
        complete = true
        paintCount = 0
        var st = Style(fill: CGColor(gray: 0, alpha: 1), stroke: CGColor(gray: 0, alpha: 1))
        var stack: [Style] = []
        var ops: [Double] = []
        var arr: [Double]?
        var path = CGMutablePath()
        var cur = CGPoint.zero
        var hasCurrent = false
        var compound = false
        var pendingPaint: String?
        var clipPending = false
        var hidden = 0                                                    // calques masqués
        var layerStack: [Bool] = []

        func applyStyle() {
            ctx.setLineWidth(max(st.width, 0.01))
            ctx.setLineCap(st.cap); ctx.setLineJoin(st.join); ctx.setMiterLimit(st.miter)
            ctx.setLineDash(phase: st.phase, lengths: st.dash)
        }
        func paint(_ op: String) {
            guard hidden == 0 else { return }
            if op == "n" || op == "N" { return }
            let close = op == "f" || op == "s" || op == "b"
            if close, hasCurrent { path.closeSubpath() }
            let doFill = "fFbB".contains(op), doStroke = "sSbB".contains(op)
            if doFill, let f = st.fill {
                ctx.addPath(path); ctx.setFillColor(f)
                ctx.fillPath(using: st.evenOdd ? .evenOdd : .winding)
                paintCount += 1
            }
            if doStroke, let s = st.stroke {
                applyStyle()
                ctx.addPath(path); ctx.setStrokeColor(s); ctx.strokePath()
                paintCount += 1
            }
        }
        func endPath(_ op: String) {
            if clipPending {
                clipPending = false
                if hidden == 0 { ctx.addPath(path); ctx.clip(using: st.evenOdd ? .evenOdd : .winding) }
            } else {
                paint(op)
            }
            path = CGMutablePath(); hasCurrent = false
        }

        while let t = next() {
            switch t {
            case .num(let v): ops.append(v)
            case .str, .name: break
            case .open: arr = []
            case .close:
                if let a = arr { st.dash = a.map { CGFloat($0) }; arr = nil }
            case .op(let o):
                func n(_ i: Int) -> CGFloat { i < ops.count ? CGFloat(ops[i]) : 0 }
                switch o {
                case "m":
                    cur = CGPoint(x: n(0), y: n(1)); path.move(to: cur); hasCurrent = true
                case "l", "L":
                    if hasCurrent { cur = CGPoint(x: n(0), y: n(1)); path.addLine(to: cur) }
                case "c", "C":
                    if hasCurrent { cur = CGPoint(x: n(4), y: n(5)); path.addCurve(to: cur, control1: CGPoint(x: n(0), y: n(1)), control2: CGPoint(x: n(2), y: n(3))) }
                case "v", "V":
                    if hasCurrent { let p = cur; cur = CGPoint(x: n(2), y: n(3)); path.addCurve(to: cur, control1: p, control2: CGPoint(x: n(0), y: n(1))) }
                case "y", "Y":
                    if hasCurrent { cur = CGPoint(x: n(2), y: n(3)); path.addCurve(to: cur, control1: CGPoint(x: n(0), y: n(1)), control2: cur) }
                case "h", "H":
                    if o == "h", hasCurrent { path.closeSubpath() }
                case "f", "F", "s", "S", "b", "B", "n", "N":
                    if compound { pendingPaint = o; if o == "N" || o == "n" || true { /* le tracé continue à s'accumuler */ } }
                    else { if o == "N" || o == "n" { if o == "n", hasCurrent, !clipPending { path.closeSubpath() } }; endPath(o) }
                case "*u": compound = true; pendingPaint = nil; path = CGMutablePath(); hasCurrent = false
                case "*U":
                    compound = false
                    if clipPending { endPath("n") }
                    else if let p = pendingPaint { endPath(p) }
                    else { path = CGMutablePath(); hasCurrent = false }
                    pendingPaint = nil
                case "W": clipPending = true
                case "q": stack.append(st); ctx.saveGState()
                case "Q": if let s = stack.popLast() { st = s; ctx.restoreGState() }
                case "g": st.fill = CGColor(colorSpace: AIRenderer.grayCS, components: [n(0), 1])
                case "G": st.stroke = CGColor(colorSpace: AIRenderer.grayCS, components: [n(0), 1])
                case "k": st.fill = cmykColor(ops.count > 0 ? ops[0] : 0, ops.count > 1 ? ops[1] : 0, ops.count > 2 ? ops[2] : 0, ops.count > 3 ? ops[3] : 0)
                case "K": st.stroke = cmykColor(ops.count > 0 ? ops[0] : 0, ops.count > 1 ? ops[1] : 0, ops.count > 2 ? ops[2] : 0, ops.count > 3 ? ops[3] : 0)
                case "x", "X":
                    // c m y k (nom) teinte x : encre d'accompagnement ; la teinte 0 donne l'encre pleine.
                    let tint = ops.count > 4 ? ops[4] : 0
                    let f = 1 - tint
                    let col = cmykColor((ops.count > 0 ? ops[0] : 0) * f, (ops.count > 1 ? ops[1] : 0) * f, (ops.count > 2 ? ops[2] : 0) * f, (ops.count > 3 ? ops[3] : 0) * f)
                    if o == "x" { st.fill = col } else { st.stroke = col }
                case "Xa": st.fill = CGColor(colorSpace: AIRenderer.rgb, components: [n(0), n(1), n(2), 1])
                case "XA": st.stroke = CGColor(colorSpace: AIRenderer.rgb, components: [n(0), n(1), n(2), 1])
                case "w": st.width = n(0)
                case "j": st.join = [CGLineJoin.miter, .round, .bevel][max(0, min(2, Int(n(0))))]
                case "J": st.cap = [CGLineCap.butt, .round, .square][max(0, min(2, Int(n(0))))]
                case "M": st.miter = max(1, n(0))
                case "d": st.phase = n(0); if arr == nil, st.dash.isEmpty == false, st.dash.allSatisfy({ $0 == 0 }) { st.dash = [] }
                case "XR": st.evenOdd = n(0) != 0
                case "Lb":
                    let visible = ops.first.map { $0 != 0 } ?? true
                    layerStack.append(visible)
                    if !visible { hidden += 1 }
                case "LB":
                    if let v = layerStack.popLast(), !v { hidden -= 1 }
                case "Bb", "Bg", "BB", "Bm", "Bc", "Bh": complete = false
                case "Tx", "TX", "Tp", "TP", "To", "TO", "XI", "XF", "Xh", "Xm", "p", "P": complete = false
                default: break
                }
                if o != "d" || arr == nil { ops.removeAll(keepingCapacity: true) }
            }
        }
        // Un tracé écrêtant non fermé ne doit pas déborder du fichier.
        while !stack.isEmpty { stack.removeLast(); ctx.restoreGState() }
    }

    /// Image du dessin, au plus `maxPixel` de côté, fond transparent.
    func render(maxPixel: CGFloat) -> CGImage? {
        let k = maxPixel / max(bounds.width, bounds.height)
        let w = max(1, Int((bounds.width * k).rounded())), h = max(1, Int((bounds.height * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: AIRenderer.rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.scaleBy(x: CGFloat(w) / bounds.width, y: CGFloat(h) / bounds.height)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        ctx.clip(to: bounds)
        draw(in: ctx)
        guard paintCount > 0 else { return nil }
        return ctx.makeImage()
    }
}
