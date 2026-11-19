// qLOOKS — livres ePUB : couverture, métadonnées, résumé, table des matières et début du texte (page HTML locale) ; couverture pour la vignette.
// Un ePUB est un zip : container.xml → fichier OPF (métadonnées, manifeste, ordre de lecture) → chapitres XHTML.
import CoreGraphics
import Foundation
import ImageIO

enum EPUB {
    static func handles(_ url: URL) -> Bool { url.pathExtension.lowercased() == "epub" }

    struct Book {
        var title = "", authors: [String] = [], publisher = "", date = "", language = "", summary = ""
        var subjects: [String] = []
        var chapters: [String] = []
        var cover: Data?
        var coverType = "image/jpeg"
        var excerpt: [String] = []
        var words = 0
        var encrypted = false
    }

    private struct Item { var id = "", href = "", type = "", props = "" }

    // MARK: Lecture

    static func load(_ url: URL, wantText: Bool = true) -> Book? {
        guard let zip = ZipFile(url: url), let cont = zip.data("META-INF/container.xml") else { return nil }
        let cs = String(decoding: cont, as: UTF8.self)
        guard let opfPath = attr("full-path", inTag: "rootfile", in: cs).map(decodePath),
              let opfData = zip.data(opfPath) else { return nil }
        let p = OPFParser()
        let xp = XMLParser(data: opfData)
        xp.delegate = p
        xp.shouldProcessNamespaces = false
        xp.parse()
        var book = Book()
        book.title = clean(p.title)
        book.authors = p.creators.map(clean).filter { !$0.isEmpty }
        book.publisher = clean(p.publisher)
        book.date = String(clean(p.date).prefix(10))
        book.language = clean(p.language)
        book.summary = clean(strip(p.summaryText))
        book.subjects = p.subjects.map(clean).filter { !$0.isEmpty }
        book.encrypted = zip.entries["META-INF/encryption.xml"] != nil

        let dir = (opfPath as NSString).deletingLastPathComponent
        func path(_ href: String) -> String { resolve(dir, decodePath(href.components(separatedBy: "#")[0])) }
        let byID = Dictionary(p.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Couverture : EPUB 3 (propriété cover-image), EPUB 2 (meta cover), sinon une image nommée « cover ».
        var coverItem = p.items.first { $0.props.split(separator: " ").contains("cover-image") }
        if coverItem == nil, let id = p.coverID { coverItem = byID[id] }
        if coverItem == nil || !(coverItem!.type.hasPrefix("image/")) {
            coverItem = p.items.first { $0.type.hasPrefix("image/") && ($0.id + $0.href).lowercased().contains("cover") }
        }
        if let c = coverItem, c.type.hasPrefix("image/"), let d = zip.data(path(c.href)), d.count < 8 << 20 {
            book.cover = d; book.coverType = c.type
        }

        // Table des matières : EPUB 3 (nav) ou EPUB 2 (NCX).
        if let nav = p.items.first(where: { $0.props.split(separator: " ").contains("nav") }), let d = zip.data(path(nav.href)) {
            book.chapters = navTitles(String(decoding: d, as: UTF8.self))
        }
        if book.chapters.isEmpty, let ncx = p.items.first(where: { $0.type == "application/x-dtbncx+xml" }) ?? p.tocID.flatMap({ byID[$0] }),
           let d = zip.data(path(ncx.href)) {
            let n = NCXParser(); let x = XMLParser(data: d); x.delegate = n; x.parse()
            book.chapters = n.titles.map(clean).filter { !$0.isEmpty }
        }

        // Texte : parcours de l'ordre de lecture (couverture et pages quasi vides ignorées pour l'extrait).
        guard wantText else { return book }
        var seen = Set<String>()
        for ref in p.spine {
            guard let it = byID[ref], it.type.contains("html"), seen.insert(it.id).inserted,
                  let d = zip.data(path(it.href)) else { continue }
            let paras = paragraphs(String(decoding: d, as: UTF8.self))
            let w = paras.reduce(0) { $0 + $1.split(whereSeparator: { $0.isWhitespace }).count }
            book.words += w
            if w >= 40, book.excerpt.joined().count < 3200 { book.excerpt += paras }
        }
        return book
    }

    // MARK: Page d'aperçu

    static func html(for url: URL) -> String? {
        guard let b = load(url) else { return nil }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let title = b.title.isEmpty ? url.deletingPathExtension().lastPathComponent : b.title
        var meta: [(String, String)] = []
        if !b.authors.isEmpty { meta.append((L.t("epub.author"), b.authors.joined(separator: ", "))) }
        if !b.publisher.isEmpty { meta.append((L.t("epub.publisher"), b.publisher)) }
        if !b.date.isEmpty { meta.append((L.t("epub.date"), b.date)) }
        if !b.language.isEmpty {
            let code = b.language.split(separator: "-").first.map(String.init) ?? b.language
            meta.append((L.t("epub.language"), L.locale.localizedString(forLanguageCode: code)?.capitalized ?? b.language))
        }
        if !b.subjects.isEmpty { meta.append((L.t("epub.genre"), b.subjects.prefix(4).joined(separator: ", "))) }
        if b.words > 0 { meta.append((L.t("epub.length"), L.t("epub.words", NumberFormatter.localizedString(from: NSNumber(value: b.words), number: .decimal)))) }
        let cover = b.cover.map { "<img class=\"cover\" src=\"data:\(b.coverType);base64,\($0.base64EncodedString())\">" } ?? ""
        let rows = meta.map { "<tr><th>\(esc($0.0))</th><td>\(esc($0.1))</td></tr>" }.joined()
        var body = "<header>\(cover)<div class=\"info\"><h1>\(esc(title))</h1><table>\(rows)</table></div></header>"
        if !b.summary.isEmpty { body += "<p class=\"summary\">\(esc(b.summary))</p>" }
        if !b.chapters.isEmpty {
            body += "<h2>\(esc(L.t("epub.chapters")))</h2><ol class=\"toc\">" + b.chapters.prefix(60).map { "<li>\(esc($0))</li>" }.joined() + "</ol>"
        }
        if !b.excerpt.isEmpty {
            var text = "", n = 0
            for p in b.excerpt { text += "<p>\(esc(p))</p>"; n += p.count; if n > 3200 { break } }
            body += "<h2>\(esc(L.t("epub.excerpt")))</h2><div class=\"text\">\(text)</div>"
        } else if b.encrypted {
            body += "<p class=\"note\">\(esc(L.t("epub.drm")))</p>"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>
        :root{color-scheme:dark light;--bg:#1e1e1e;--sunk:#181818;--t:#ddd;--ts:#fff;--tm:#999;--bd:#333;--ac:#38bdf8}
        @media (prefers-color-scheme:light){:root{--bg:#fff;--sunk:#f4f1ea;--t:#222;--ts:#111;--tm:#666;--bd:#d9d9d9;--ac:#0369a1}}
        html,body{margin:0;background:var(--bg);color:var(--t);font:14px/1.55 -apple-system,BlinkMacSystemFont,sans-serif}
        .doc{max-width:820px;margin:0 auto;padding:28px 32px 56px}
        header{display:flex;gap:28px;align-items:flex-start}
        .cover{width:210px;max-height:320px;object-fit:contain;border-radius:4px;box-shadow:0 6px 22px rgba(0,0,0,.4);flex:none}
        .info{flex:1;min-width:0}h1{font-size:26px;line-height:1.2;color:var(--ts);margin:4px 0 14px}
        table{border-collapse:collapse}th{color:var(--tm);font-weight:500;text-align:left;padding:3px 16px 3px 0;vertical-align:top;white-space:nowrap}td{padding:3px 0;color:var(--ts)}
        .summary{margin:22px 0 0;padding:12px 16px;background:var(--sunk);border-left:3px solid var(--ac);border-radius:4px;color:var(--t)}
        h2{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--tm);border-bottom:1px solid var(--bd);padding-bottom:6px;margin:30px 0 12px}
        .toc{columns:2;column-gap:32px;margin:0;padding-left:22px;color:var(--t)}.toc li{break-inside:avoid;padding:2px 0}
        .text{font:15.5px/1.7 Georgia,'Times New Roman',serif;color:var(--t)}.text p{margin:0 0 .8em;text-indent:1.4em}.text p:first-child{text-indent:0}
        .note{color:var(--tm)}
        </style></head><body><div class="doc">\(body)</div></body></html>
        """
    }

    // MARK: Vignette

    /// Couverture du livre (nil si le livre n'en a pas : le Finder garde alors l'icône générique).
    static func coverImage(_ url: URL) -> CGImage? {
        guard let b = load(url, wantText: false) else { return nil }
        if let d = b.cover, let src = CGImageSourceCreateWithData(d as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { return img }
        return nil
    }

    // MARK: Outils

    private static func clean(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func decodePath(_ s: String) -> String { s.removingPercentEncoding ?? s }

    private static func resolve(_ dir: String, _ rel: String) -> String {
        var parts = dir.isEmpty ? [] : dir.split(separator: "/").map(String.init)
        for c in rel.split(separator: "/") {
            if c == ".." { _ = parts.popLast() } else if c != "." { parts.append(String(c)) }
        }
        return parts.joined(separator: "/")
    }

    private static func attr(_ name: String, inTag tag: String, in s: String) -> String? {
        guard let r = s.range(of: "<\(tag)[^>]*?\(name)\\s*=\\s*[\"']([^\"']*)[\"']", options: .regularExpression) else { return nil }
        let m = String(s[r])
        guard let q = m.range(of: "\(name)\\s*=\\s*[\"']([^\"']*)", options: .regularExpression) else { return nil }
        return String(m[q]).components(separatedBy: CharacterSet(charactersIn: "\"'")).dropFirst().first
    }

    /// Titres des liens de la table des matières EPUB 3.
    private static func navTitles(_ s: String) -> [String] {
        var scope = s
        if let r = s.range(of: "<nav[^>]*epub:type\\s*=\\s*[\"'][^\"']*toc[^\"']*[\"'][^>]*>[\\s\\S]*?</nav>", options: .regularExpression) { scope = String(s[r]) }
        var out: [String] = []
        var rest = Substring(scope)
        while let r = rest.range(of: "<a\\b[^>]*>([\\s\\S]*?)</a>", options: .regularExpression) {
            let t = clean(decodeEntities(strip(String(rest[r]))))
            if !t.isEmpty { out.append(t) }
            rest = rest[r.upperBound...]
        }
        return out
    }

    private static func strip(_ s: String) -> String {
        decodeEntities(s.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression))
    }

    /// Paragraphes de texte d'un chapitre XHTML.
    private static func paragraphs(_ html: String) -> [String] {
        var s = html
        for tag in ["head", "script", "style"] {
            s = s.replacingOccurrences(of: "<\(tag)[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "</(p|div|h[1-6]|li|blockquote|tr)>|<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        return decodeEntities(s).components(separatedBy: "\n").map(clean).filter { !$0.isEmpty }
    }

    private static let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "laquo": "«", "raquo": "»",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "hellip": "…", "mdash": "—", "ndash": "–", "eacute": "é", "egrave": "è", "agrave": "à", "ecirc": "ê", "ccedil": "ç"]

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = "", i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var rep: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X"), let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { rep = String(u) }
                else if name.hasPrefix("#"), let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) { rep = String(u) }
                else { rep = named[name] }
                if let rep { out += rep; i = s.index(after: semi); continue }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }

    // MARK: Analyseurs XML

    private final class OPFParser: NSObject, XMLParserDelegate {
        var title = "", publisher = "", date = "", language = "", summaryText = ""
        var creators: [String] = [], subjects: [String] = []
        var items: [Item] = [], spine: [String] = []
        var coverID: String?, tocID: String?
        private var text = "", inMeta = false

        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            let n = e.lowercased()
            text = ""
            if n == "metadata" { inMeta = true }
            if n == "meta", a["name"] == "cover" { coverID = a["content"] }
            if n == "item" { items.append(Item(id: a["id"] ?? "", href: a["href"] ?? "", type: a["media-type"] ?? "", props: a["properties"] ?? "")) }
            if n == "spine" { tocID = a["toc"] }
            if n == "itemref", let r = a["idref"] { spine.append(r) }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
        func parser(_ p: XMLParser, foundCDATA b: Data) { text += String(decoding: b, as: UTF8.self) }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            let n = e.lowercased().replacingOccurrences(of: "dc:", with: "")
            guard inMeta else { return }
            switch n {
            case "title": if title.isEmpty { title = text }
            case "creator": creators.append(text)
            case "publisher": if publisher.isEmpty { publisher = text }
            case "date": if date.isEmpty { date = text }
            case "language": if language.isEmpty { language = text }
            case "description": if summaryText.isEmpty { summaryText = text }
            case "subject": subjects.append(text)
            case "metadata": inMeta = false
            default: break
            }
        }
    }

    private final class NCXParser: NSObject, XMLParserDelegate {
        var titles: [String] = []
        private var text = "", inLabel = false
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            if e.lowercased() == "navlabel" { inLabel = true; text = "" }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inLabel { text += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e.lowercased() == "navlabel" { inLabel = false; titles.append(text) }
        }
    }
}
