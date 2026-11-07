// qLOOKS — registre des formats pris en charge, version par version. Pour ajouter un format : une ligne dans `all` avec la version
// qui l'apporte (et, pour une nouvelle version, l'ajouter à `versions`) ; la page « Formats » se met à jour toute seule.
import Foundation

enum FormatCategory: String, CaseIterable, Identifiable {
    case video, image, model, archive, document, dev, geo
    var id: String { rawValue }
    var titleKey: String { "fm.cat." + rawValue }
    var symbol: String {
        switch self {
        case .video: return "film"
        case .image: return "photo"
        case .model: return "cube"
        case .archive: return "archivebox"
        case .document: return "doc.text"
        case .dev: return "chevron.left.forwardslash.chevron.right"
        case .geo: return "map"
        }
    }
}

struct FormatEntry: Identifiable {
    let name: String
    let exts: [String]
    let category: FormatCategory
    let since: String
    let preview: Bool
    let thumbnail: Bool
    var noteKey: String?
    var id: String { name }
}

enum Formats {
    /// Versions de qLOOKS, de la plus ancienne à la plus récente.
    static let versions = ["1.0.0", "1.1.0"]

    static let all: [FormatEntry] = [
        // 1.0.0
        FormatEntry(name: "QuickTime", exts: ["mov"], category: .video, since: "1.0.0", preview: true, thumbnail: true, noteKey: "fm.note.mov"),
        FormatEntry(name: "Matroska", exts: ["mkv"], category: .video, since: "1.0.0", preview: true, thumbnail: true, noteKey: "fm.note.mkv"),
        // 1.1.0
        FormatEntry(name: "SVG", exts: ["svg"], category: .image, since: "1.1.0", preview: true, thumbnail: true),
        FormatEntry(name: "EPS", exts: ["eps"], category: .image, since: "1.1.0", preview: true, thumbnail: true, noteKey: "fm.note.eps"),
        FormatEntry(name: "Illustrator / FreeHand", exts: ["ai"], category: .image, since: "1.1.0", preview: true, thumbnail: false, noteKey: "fm.note.ai"),
        FormatEntry(name: "STL", exts: ["stl"], category: .model, since: "1.1.0", preview: true, thumbnail: true),
        FormatEntry(name: "OBJ", exts: ["obj"], category: .model, since: "1.1.0", preview: true, thumbnail: true),
        FormatEntry(name: "PLY", exts: ["ply"], category: .model, since: "1.1.0", preview: true, thumbnail: true),
        FormatEntry(name: "USD", exts: ["usd", "usda", "usdc", "usdz"], category: .model, since: "1.1.0", preview: true, thumbnail: true),
        FormatEntry(name: "Alembic", exts: ["abc"], category: .model, since: "1.1.0", preview: true, thumbnail: true),
        FormatEntry(name: "Collada", exts: ["dae"], category: .model, since: "1.1.0", preview: true, thumbnail: true),
        FormatEntry(name: "SceneKit", exts: ["scn"], category: .model, since: "1.1.0", preview: true, thumbnail: true),
        FormatEntry(name: "3MF", exts: ["3mf"], category: .model, since: "1.1.0", preview: true, thumbnail: true),
        FormatEntry(name: "3D Studio", exts: ["3ds"], category: .model, since: "1.1.0", preview: true, thumbnail: true),
        FormatEntry(name: "LightWave", exts: ["lwo", "lws"], category: .model, since: "1.1.0", preview: true, thumbnail: true),
        FormatEntry(name: "Cinema 4D", exts: ["c4d"], category: .model, since: "1.1.0", preview: true, thumbnail: true, noteKey: "fm.note.c4d"),
        FormatEntry(name: "3ds Max", exts: ["max"], category: .model, since: "1.1.0", preview: true, thumbnail: true, noteKey: "fm.note.max"),
        FormatEntry(name: "ZIP", exts: ["zip"], category: .archive, since: "1.1.0", preview: true, thumbnail: false),
        FormatEntry(name: "TAR / TGZ / GZ", exts: ["tar", "tgz", "tar.gz", "gz"], category: .archive, since: "1.1.0", preview: true, thumbnail: false),
        FormatEntry(name: "RAR", exts: ["rar"], category: .archive, since: "1.1.0", preview: true, thumbnail: false),
        FormatEntry(name: "7-Zip", exts: ["7z"], category: .archive, since: "1.1.0", preview: true, thumbnail: false),
        FormatEntry(name: "DMG", exts: ["dmg"], category: .archive, since: "1.1.0", preview: true, thumbnail: false, noteKey: "fm.note.dmg"),
        FormatEntry(name: "Dossiers", exts: [], category: .archive, since: "1.1.0", preview: true, thumbnail: false),
        FormatEntry(name: "Markdown", exts: ["md", "markdown", "qmd", "rmd"], category: .document, since: "1.1.0", preview: true, thumbnail: false),
        FormatEntry(name: "Code source", exts: ["swift", "py", "js", "ts", "c", "cpp", "h", "m", "java", "go", "rs", "rb", "php", "sh", "json", "yml", "xml", "sql", "css"], category: .dev, since: "1.1.0", preview: true, thumbnail: false, noteKey: "fm.note.code"),
        FormatEntry(name: "Applications et modules", exts: ["app", "appex", "framework", "bundle", "plugin", "dylib"], category: .dev, since: "1.1.0", preview: true, thumbnail: false, noteKey: "fm.note.apps"),
        FormatEntry(name: "GPX", exts: ["gpx"], category: .geo, since: "1.1.0", preview: true, thumbnail: false),
    ]

    static func supported(in version: String) -> [FormatEntry] { all.filter { $0.since.compare(version, options: .numeric) != .orderedDescending } }
    static func isNew(_ e: FormatEntry, in version: String) -> Bool { e.since == version }
}
