// qLOOKS — réglages partagés entre l'appli et ses extensions QuickLook (groupe d'applis), et fonds derrière la vidéo.
import CoreGraphics
import Foundation

enum Backdrop: String, CaseIterable {
    case checker, dark, light
    var labelKey: String { "bg.\(rawValue)" }
    var symbol: String {
        switch self {
        case .checker: return "checkerboard.rectangle"
        case .dark: return "square.fill"
        case .light: return "square"
        }
    }
}

enum Prefs {
    /// L'appli hôte écrit dans son domaine ; les extensions (sandbox) le lisent en lecture seule et écrivent le leur.
    /// La valeur la plus récente des deux gagne (horodatage « clé.t »).
    static let host = "fr.stephan.alphalook"

    private static func read(_ key: String) -> Any? {
        let own = (UserDefaults.standard.object(forKey: key), UserDefaults.standard.double(forKey: key + ".t"))
        let hostValue = CFPreferencesCopyAppValue(key as CFString, host as CFString)
        let hostT = (CFPreferencesCopyAppValue((key + ".t") as CFString, host as CFString) as? Double) ?? 0
        if Bundle.main.bundleIdentifier == host { return own.0 }
        return hostT > own.1 ? hostValue : (own.0 ?? hostValue)
    }

    private static func write(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key + ".t")
    }

    static var backdrop: Backdrop {
        get { Backdrop(rawValue: read("backdrop") as? String ?? "") ?? .checker }
        set { write("backdrop", newValue.rawValue) }
    }
    static var loop: Bool {
        get { read("loop") as? Bool ?? true }
        set { write("loop", newValue) }
    }
    static var autoplay: Bool {
        get { read("autoplay") as? Bool ?? true }
        set { write("autoplay", newValue) }
    }
}

enum Backdrops {
    static let checkerA = CGColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1)
    static let checkerB = CGColor(srgbRed: 0.70, green: 0.70, blue: 0.70, alpha: 1)
    static let dark = CGColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)
    static let light = CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)
    /// Hors de l'image (bandes autour de la vidéo) : fond creux de Socle.
    static let surround = CGColor(srgbRed: 0.0941, green: 0.0941, blue: 0.0941, alpha: 1)

    static func draw(_ b: Backdrop, in ctx: CGContext, rect: CGRect, square: CGFloat) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.clip(to: rect)
        switch b {
        case .dark: ctx.setFillColor(dark); ctx.fill(rect)
        case .light: ctx.setFillColor(light); ctx.fill(rect)
        case .checker:
            ctx.setFillColor(checkerA); ctx.fill(rect)
            ctx.setFillColor(checkerB)
            let s = max(2, square.rounded())
            var y = rect.minY, row = 0
            while y < rect.maxY {
                var x = rect.minX + (row % 2 == 0 ? 0 : s)
                while x < rect.maxX { ctx.fill(CGRect(x: x, y: y, width: s, height: s)); x += 2 * s }
                y += s; row += 1
            }
        }
    }

    /// Rectangle de l'image ajusté (sans déformation) au centre d'une zone.
    static func fit(_ size: CGSize, in area: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return area }
        let k = min(area.width / size.width, area.height / size.height)
        let w = (size.width * k).rounded(), h = (size.height * k).rounded()
        return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w, height: h)
    }
}
