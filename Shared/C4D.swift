// qLOOKS — Cinema 4D (.c4d). Si Cinema 4D est installé, la scène est convertie en OBJ par c4dpy (sans interface) puis affichée en 3D ;
// sinon on montre l'image d'aperçu (JPEG) enregistrée dans le fichier.
// Une extension QuickLook est confinée : elle lance le script « c4d_convert.sh » installé par l'appli dans
// ~/Library/Application Scripts/<identifiant de l'extension>/, seul moyen autorisé par macOS d'exécuter un programme hors du bac à sable.
import AppKit
import Foundation
import SceneKit

enum C4D {
    static let previewBundleID = "fr.stephan.alphalook.preview"

    /// Dossier des scripts de l'extension d'aperçu (côté appli : on le crée ; côté extension : le système le fournit).
    static var scriptsDirectory: URL {
        if let u = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
           u.path.hasSuffix(previewBundleID) { return u }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Scripts/\(previewBundleID)")
    }

    static let scriptName = "c4d_convert.sh"

    static let script = #"""
    #!/bin/bash
    # qLOOKS — convertit une scène Cinema 4D en OBJ avec c4dpy (sans interface). Arguments : fichier.c4d dossier_sortie
    IN="$1"; OUT="$2"
    [ -f "$IN" ] || exit 2
    mkdir -p "$OUT"
    # Recherche de Cinema 4D : la version la plus récente trouvée dans les dossiers d'applications.
    BIN=""
    for d in /Applications /Applications/Maxon "$HOME/Applications" "$HOME/Applications/Maxon"; do
      for a in "$d"/Maxon\ Cinema\ 4D*/c4dpy.app "$d"/Cinema\ 4D*/c4dpy.app; do
        [ -x "$a/Contents/MacOS/c4dpy" ] && BIN="$a/Contents/MacOS/c4dpy"
      done
    done
    [ -n "$BIN" ] || exit 3
    PY="$OUT/convert.py"
    cat > "$PY" <<'PYEOF'
    import c4d, sys
    from c4d import documents
    doc = documents.LoadDocument(sys.argv[1], c4d.SCENEFILTER_OBJECTS | c4d.SCENEFILTER_MATERIALS)
    if doc is None: sys.exit(2)
    documents.SaveDocument(doc, sys.argv[2], c4d.SAVEDOCUMENTFLAGS_DONTADDTORECENTLIST, c4d.FORMAT_OBJ2EXPORT)
    PYEOF
    "$BIN" "$PY" "$IN" "$OUT/model.obj" >/dev/null 2>&1 &
    PID=$!
    for i in $(seq 1 60); do kill -0 $PID 2>/dev/null || break; sleep 1; done
    kill $PID 2>/dev/null
    [ -s "$OUT/model.obj" ] && exit 0 || exit 4
    """#

    /// Appli : installe (ou met à jour) le script et dit si Cinema 4D est présent.
    @discardableResult
    static func installScript() -> Bool {
        let dir = scriptsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(scriptName)
        let clean = script.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }.joined(separator: "\n")
        if (try? String(contentsOf: url, encoding: .utf8)) != clean {
            guard (try? clean.write(to: url, atomically: true, encoding: .utf8)) != nil else { return false }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return true
    }

    /// Cinema 4D installé ? (utilisé par l'appli ; l'extension, confinée, n'a pas besoin de le savoir : le script le cherche.)
    static func installedC4DPy() -> URL? {
        let fm = FileManager.default
        var best: URL?
        for base in ["/Applications", "/Applications/Maxon", NSHomeDirectory() + "/Applications", NSHomeDirectory() + "/Applications/Maxon"] {
            guard let items = try? fm.contentsOfDirectory(atPath: base) else { continue }
            for i in items.sorted() where i.hasPrefix("Maxon Cinema 4D") || i.hasPrefix("Cinema 4D") {
                let bin = URL(fileURLWithPath: base).appendingPathComponent(i).appendingPathComponent("c4dpy.app/Contents/MacOS/c4dpy")
                if fm.isExecutableFile(atPath: bin.path) { best = bin }
            }
        }
        return best
    }

    struct Result { var root: SCNNode?; var preview: NSImage?; var triangles = 0; var note: String? }

    static func load(_ url: URL) async -> Result {
        var r = Result()
        if let (node, tri) = await convert(url) { r.root = node; r.triangles = tri; return r }
        r.preview = embeddedPreview(url)
        r.note = "preview"
        return r
    }

    /// Conversion par le script (hors bac à sable).
    private static func convert(_ url: URL) async -> (SCNNode, Int)? {
        let script = scriptsDirectory.appendingPathComponent(scriptName)
        guard FileManager.default.fileExists(atPath: script.path), let task = try? NSUserUnixTask(url: script) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("c4d-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let ok: Bool = await withCheckedContinuation { cont in
            task.execute(withArguments: [url.path, out.path]) { err in cont.resume(returning: err == nil) }
        }
        let obj = out.appendingPathComponent("model.obj")
        guard ok, FileManager.default.fileExists(atPath: obj.path), let scene = try? SCNScene(url: obj, options: [.checkConsistency: false]) else { return nil }
        var n = 0
        scene.rootNode.enumerateHierarchy { node, _ in
            for el in node.geometry?.elements ?? [] { n += el.primitiveCount }
            for m in node.geometry?.materials ?? [] where m.diffuse.contents == nil { m.diffuse.contents = NSColor(white: 0.78, alpha: 1) }
        }
        return n > 0 ? (scene.rootNode, n) : nil
    }

    /// Image d'aperçu enregistrée dans le fichier (JPEG près du début).
    static func embeddedPreview(_ url: URL) -> NSImage? {
        guard let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: 2 << 20) else { return nil }
        try? h.close()
        let b = [UInt8](d)
        guard let s = (0..<max(0, b.count - 3)).first(where: { b[$0] == 0xFF && b[$0 + 1] == 0xD8 && b[$0 + 2] == 0xFF }) else { return nil }
        var e = s + 3
        while e + 1 < b.count { if b[e] == 0xFF && b[e + 1] == 0xD9 { break }; e += 1 }
        guard e + 1 < b.count else { return nil }
        return NSImage(data: Data(b[s...(e + 1)]))
    }
}
