// qLOOKS — fiche d'identité d'une application, d'un module ou d'un exécutable : version, signature, notarisation,
// architectures, droits (entitlements), contenu. Page HTML locale, comme le Markdown.
import AppKit
import Foundation
import Security

enum AppInfo {
    static let bundleExtensions: Set<String> = ["app", "appex", "framework", "bundle", "plugin", "kext", "prefpane", "xpc", "saver", "component", "qlgenerator", "mdimporter", "systemextension", "driverkit", "dext", "vst", "vst3", "audiounit", "wdgt", "colorpicker", "docset"]

    enum Kind { case bundle(URL), executable }

    static func kind(of url: URL) -> Kind? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return bundleExtensions.contains(url.pathExtension.lowercased()) ? .bundle(url) : nil }
        let e = url.pathExtension.lowercased()
        if e == "dylib" || e == "" || e == "so" { return machO(url) != nil ? .executable : nil }
        return nil
    }

    // MARK: Mach-O

    struct Arch { let name: String; let minOS: String? }

    private static func versionString(_ v: UInt32) -> String {
        let x = v >> 16, y = (v >> 8) & 0xFF, z = v & 0xFF
        return z == 0 ? "\(x).\(y)" : "\(x).\(y).\(z)"
    }

    static func machO(_ url: URL) -> [Arch]? {
        guard let h = try? FileHandle(forReadingFrom: url), let head = try? h.read(upToCount: 4096), head.count > 32 else { return nil }
        defer { try? h.close() }
        let b = [UInt8](head)
        func u32(_ d: [UInt8], _ i: Int, big: Bool) -> UInt32 {
            guard i + 4 <= d.count else { return 0 }
            let v = (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[i + $1]) << (8 * UInt32($1)) }
            return big ? v.byteSwapped : v
        }
        func cpu(_ t: UInt32, _ s: UInt32) -> String {
            switch t {
            case 0x0100000C: return (s & 0xFF) == 2 ? "arm64e" : "arm64"
            case 0x01000007: return "x86_64"
            case 0x00000007: return "i386"
            case 0x0000000C: return "arm"
            case 0x00000012, 0x01000012: return "ppc"
            default: return "?"
            }
        }
        func minOS(at offset: UInt64) -> String? {
            guard (try? h.seek(toOffset: offset)) != nil, let d = try? h.read(upToCount: 16384), d.count > 32 else { return nil }
            let a = [UInt8](d)
            let magic = u32(a, 0, big: false)
            guard magic == 0xFEEDFACF || magic == 0xFEEDFACE else { return nil }
            let n = Int(u32(a, 16, big: false))
            var p = magic == 0xFEEDFACF ? 32 : 28
            var legacy: String?
            for _ in 0..<min(n, 200) {
                guard p + 8 <= a.count else { break }
                let cmd = u32(a, p, big: false), size = Int(u32(a, p + 4, big: false))
                if cmd == 0x32 { return versionString(u32(a, p + 12, big: false)) }
                if cmd == 0x24 { legacy = versionString(u32(a, p + 8, big: false)) }
                guard size >= 8 else { break }
                p += size
            }
            return legacy
        }
        let m = u32(b, 0, big: false)
        if m == 0xFEEDFACF || m == 0xFEEDFACE {
            return [Arch(name: cpu(u32(b, 4, big: false), u32(b, 8, big: false)), minOS: minOS(at: 0))]
        }
        if u32(b, 0, big: true) == 0xCAFEBABE {
            let n = Int(u32(b, 4, big: true))
            guard n > 0, n < 16 else { return nil }
            var out: [Arch] = []
            for i in 0..<n {
                let o = 8 + i * 20
                guard o + 20 <= b.count else { break }
                out.append(Arch(name: cpu(u32(b, o, big: true), u32(b, o + 4, big: true)), minOS: minOS(at: UInt64(u32(b, o + 8, big: true)))))
            }
            return out.isEmpty ? nil : out
        }
        return nil
    }

    // MARK: Signature

    struct Signature {
        var status = "unsigned"                      // unsigned, adhoc, valid, invalid
        var identifier: String?
        var team: String?
        var authority: [String] = []
        var runtime = false
        var entitlements: [String: Any] = [:]
        var signedOn: Date?
        var notarized: Bool?
    }

    static func signature(_ url: URL) -> Signature {
        var s = Signature()
        var codeRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &codeRef) == errSecSuccess, let code = codeRef else { return s }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &infoRef) == errSecSuccess, let info = infoRef as? [String: Any] else { return s }
        if info[kSecCodeInfoIdentifier as String] == nil { return s }
        s.identifier = info[kSecCodeInfoIdentifier as String] as? String
        s.team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let f = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        s.runtime = f & 0x10000 != 0
        s.signedOn = info[kSecCodeInfoTime as String] as? Date
        s.entitlements = (info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]) ?? [:]
        if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate] {
            s.authority = certs.compactMap { SecCertificateCopySubjectSummary($0) as String? }
        }
        let adhoc = f & 0x2 != 0
        let quick = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSBasicValidateOnly)
        let ok = SecStaticCodeCheckValidity(code, quick, nil) == errSecSuccess
        s.status = adhoc ? "adhoc" : (ok ? "valid" : "invalid")
        if !adhoc, ok {
            var req: SecRequirement?
            if SecRequirementCreateWithString("notarized" as CFString, [], &req) == errSecSuccess, let req {
                s.notarized = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), req) == errSecSuccess
            }
        }
        return s
    }

    // MARK: Page

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func iconData(_ url: URL) -> String {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        let size = NSSize(width: 128, height: 128)
        let out = NSImage(size: size)
        out.lockFocus(); img.draw(in: NSRect(origin: .zero, size: size)); out.unlockFocus()
        guard let t = out.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private static func dirSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else { return 0 }
        var total: Int64 = 0, n = 0
        for case let u as URL in e {
            n += 1; if n > 60_000 { break }
            if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }

    private static func plistValue(_ v: Any) -> String {
        switch v {
        case let b as Bool: return b ? "true" : "false"
        case let a as [Any]: return a.map { plistValue($0) }.joined(separator: ", ")
        case let d as [String: Any]: return d.keys.sorted().map { "\($0) = \(plistValue(d[$0]!))" }.joined(separator: "; ")
        default: return "\(v)"
        }
    }

    private static func row(_ k: String, _ v: String, cls: String = "") -> String {
        v.isEmpty ? "" : "<tr><th>\(esc(k))</th><td class=\"\(cls)\">\(v)</td></tr>"
    }
    private static func badge(_ text: String, _ tone: String) -> String { "<span class=\"b \(tone)\">\(esc(text))</span>" }

    /// Bundles contenus (frameworks, modules, outils) : nom et version.
    private static func embedded(_ url: URL, dirs: [String]) -> [String] {
        var out: [String] = []
        for d in dirs {
            let dir = url.appendingPathComponent(d)
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for i in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) where !i.lastPathComponent.hasPrefix(".") {
                var name = i.lastPathComponent
                for p in [i.appendingPathComponent("Contents/Info.plist"), i.appendingPathComponent("Resources/Info.plist"), i.appendingPathComponent("Versions/Current/Resources/Info.plist"), i.appendingPathComponent("Info.plist")] {
                    if let d = NSDictionary(contentsOf: p), let v = d["CFBundleShortVersionString"] as? String { name += " — \(v)"; break }
                }
                out.append(name)
            }
        }
        return out
    }

    static func html(for url: URL, kind: Kind) -> String? {
        var info: [String: Any] = [:]
        var title = url.deletingPathExtension().lastPathComponent
        var rows = "", extra = ""
        let sig = signature(url)
        var archs: [Arch] = []
        var kindLabel = L.t("ap.kind.exe")
        var contentsHTML = ""

        if case .bundle(let b) = kind {
            let candidates = [b.appendingPathComponent("Contents/Info.plist"), b.appendingPathComponent("Resources/Info.plist"), b.appendingPathComponent("Versions/Current/Resources/Info.plist"), b.appendingPathComponent("Info.plist")]
            for c in candidates { if let d = NSDictionary(contentsOf: c) as? [String: Any] { info = d; break } }
            title = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? title
            let ext = b.pathExtension.lowercased()
            kindLabel = ext == "app" ? L.t("ap.kind.app") : (ext == "framework" ? L.t("ap.kind.framework") : L.t("ap.kind.bundle"))
            if let exeName = info["CFBundleExecutable"] as? String {
                for p in [b.appendingPathComponent("Contents/MacOS/\(exeName)"), b.appendingPathComponent("Versions/Current/\(exeName)"), b.appendingPathComponent(exeName)] {
                    if let a = machO(p) { archs = a; break }
                }
            }
            let fw = embedded(b, dirs: ["Contents/Frameworks", "Frameworks"])
            let pl = embedded(b, dirs: ["Contents/PlugIns", "PlugIns", "Contents/Extensions", "Contents/Library/SystemExtensions", "Contents/Library/QuickLook"])
            let hp = embedded(b, dirs: ["Contents/XPCServices", "XPCServices", "Contents/Library/LoginItems", "Contents/Library/LaunchServices", "Contents/Helpers", "Contents/Resources/Helpers"])
            for (label, list) in [(L.t("ap.frameworks"), fw), (L.t("ap.plugins"), pl), (L.t("ap.helpers"), hp)] where !list.isEmpty {
                contentsHTML += "<h2>\(esc(label)) <small>\(list.count)</small></h2><ul class=\"cols\">" + list.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
            }
        } else {
            archs = machO(url) ?? []
        }

        let version = [info["CFBundleShortVersionString"] as? String, (info["CFBundleVersion"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        rows += row(L.t("ap.identifier"), esc((info["CFBundleIdentifier"] as? String) ?? sig.identifier ?? ""), cls: "mono")
        rows += row(L.t("ap.version"), esc(version))
        rows += row(L.t("ap.size"), ByteCountFormatter.string(fromByteCount: { if case .bundle = kind { return dirSize(url) } else { return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) } }(), countStyle: .file))
        if !archs.isEmpty {
            rows += row(L.t("ap.arch"), archs.map { badge($0.name == "x86_64" ? "Intel · x86_64" : ($0.name.hasPrefix("arm64") ? "Apple silicon · \($0.name)" : $0.name), "n") }.joined(separator: " "))
            let mins = archs.compactMap { $0.minOS }
            rows += row(L.t("ap.minos"), esc((info["LSMinimumSystemVersion"] as? String) ?? mins.sorted().first ?? ""))
        } else if let m = info["LSMinimumSystemVersion"] as? String { rows += row(L.t("ap.minos"), esc(m)) }
        if let c = info["LSApplicationCategoryType"] as? String { rows += row(L.t("ap.category"), esc(c.replacingOccurrences(of: "public.app-category.", with: ""))) }
        if let c = info["NSHumanReadableCopyright"] as? String { rows += row(L.t("ap.copyright"), esc(c)) }

        // Signature
        var sigHTML = ""
        switch sig.status {
        case "valid": sigHTML += badge(L.t("ap.signed.valid"), "ok")
        case "invalid": sigHTML += badge(L.t("ap.signed.invalid"), "bad")
        case "adhoc": sigHTML += badge(L.t("ap.adhoc"), "warn")
        default: sigHTML += badge(L.t("ap.unsigned"), "warn")
        }
        if let n = sig.notarized { sigHTML += " " + (n ? badge(L.t("ap.notarized"), "ok") : badge(L.t("ap.notnotarized"), "warn")) }
        if sig.status != "unsigned" {
            sigHTML += " " + badge("Hardened Runtime: " + L.t(sig.runtime ? "ap.yes" : "ap.no"), sig.runtime ? "ok" : "n")
            let sandboxed = (sig.entitlements["com.apple.security.app-sandbox"] as? Bool) == true
            sigHTML += " " + badge("App Sandbox: " + L.t(sandboxed ? "ap.yes" : "ap.no"), sandboxed ? "ok" : "n")
        }
        rows += row(L.t("ap.signature"), sigHTML)
        if let first = sig.authority.first { rows += row(L.t("ap.developer"), esc(first)) }
        if let t = sig.team { rows += row(L.t("ap.team"), esc(t), cls: "mono") }
        if let d = sig.signedOn { rows += row(L.t("ap.signed.on"), esc(d.formatted(.dateTime.day().month().year().locale(L.locale)))) }

        if sig.authority.count > 1 {
            extra += "<h2>\(esc(L.t("ap.certs")))</h2><ol class=\"chain\">" + sig.authority.map { "<li>\(esc($0))</li>" }.joined() + "</ol>"
        }
        let privacy = info.keys.filter { $0.hasSuffix("UsageDescription") }.sorted()
        if !privacy.isEmpty {
            extra += "<h2>\(esc(L.t("ap.privacy")))</h2><table>" + privacy.map { "<tr><th class=\"mono\">\(esc($0))</th><td>\(esc(plistValue(info[$0]!)))</td></tr>" }.joined() + "</table>"
        }
        if let types = info["CFBundleURLTypes"] as? [[String: Any]] {
            let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
            if !schemes.isEmpty { extra += "<h2>\(esc(L.t("ap.schemes")))</h2><p class=\"mono\">" + schemes.map { esc($0 + "://") }.joined(separator: " &nbsp; ") + "</p>" }
        }
        if !sig.entitlements.isEmpty {
            extra += "<h2>\(esc(L.t("ap.entitlements"))) <small>\(sig.entitlements.count)</small></h2><table>" + sig.entitlements.keys.sorted().map { "<tr><th class=\"mono\">\(esc($0))</th><td class=\"mono\">\(esc(plistValue(sig.entitlements[$0]!)))</td></tr>" }.joined() + "</table>"
        }
        extra += contentsHTML

        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>
        :root{color-scheme:dark light;--bg:#1e1e1e;--sunk:#181818;--surf:#222;--t:#ddd;--ts:#fff;--tm:#aaa;--bd:#333;--ac:#38bdf8;--ok:#34d399;--warn:#fbbf24;--bad:#f87171}
        @media (prefers-color-scheme:light){:root{--bg:#f2f2f2;--sunk:#ebebeb;--surf:#fff;--t:#222;--ts:#111;--tm:#555;--bd:#d4d4d4;--ac:#0369a1;--ok:#047857;--warn:#b45309;--bad:#b91c1c}}
        html,body{margin:0;background:var(--bg);color:var(--t);font:13px/1.5 -apple-system,BlinkMacSystemFont,sans-serif}
        .wrap{max-width:820px;margin:0 auto;padding:24px 28px 40px}
        header{display:flex;gap:18px;align-items:center;margin-bottom:18px}header img{width:84px;height:84px}
        h1{margin:0;font-size:22px;color:var(--ts)}header p{margin:2px 0 0;color:var(--tm)}
        h2{font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--tm);margin:26px 0 8px;font-weight:700}h2 small{color:var(--tm);font-weight:400}
        table{width:100%;border-collapse:collapse;background:var(--surf);border:1px solid var(--bd);border-radius:6px;overflow:hidden}
        th,td{text-align:left;padding:7px 12px;border-bottom:1px solid var(--bd);vertical-align:top}tr:last-child th,tr:last-child td{border-bottom:0}
        th{width:34%;font-weight:600;color:var(--tm);white-space:nowrap}td{color:var(--t);word-break:break-word}
        .mono{font:12px ui-monospace,Menlo,monospace}.b{display:inline-block;padding:1px 9px;border-radius:10px;font-size:12px;font-weight:600;background:var(--sunk);border:1px solid var(--bd);color:var(--t)}
        .ok{color:var(--ok);border-color:var(--ok)}.warn{color:var(--warn);border-color:var(--warn)}.bad{color:var(--bad);border-color:var(--bad)}
        ul.cols{columns:2;column-gap:24px;margin:0;padding-left:18px}ol.chain{margin:0;padding-left:20px}li{margin:2px 0}
        </style></head><body><div class="wrap">
        <header><img src="\(iconData(url))" alt=""><div><h1>\(esc(title))</h1><p>\(esc(kindLabel))\(version.isEmpty ? "" : " · " + esc(version))</p></div></header>
        <table>\(rows)</table>\(extra)</div></body></html>
        """
    }
}
