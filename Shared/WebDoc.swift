// qLOOKS — documents texte mis en forme : Markdown (marked) et code source coloré (highlight.js), rendus dans une page web locale.
import Foundation

enum WebDoc {
    enum Kind { case markdown, code(String?) }

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "qmd", "rmd"]

    /// Langage highlight.js quand le nom de l'extension n'est pas déjà celui du langage.
    private static let languages: [String: String] = [
        "py": "python", "pyw": "python", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript", "rb": "ruby", "sh": "bash", "zsh": "bash", "bash": "bash", "command": "bash",
        "h": "cpp", "hpp": "cpp", "cc": "cpp", "cxx": "cpp", "hh": "cpp", "c": "c", "m": "objectivec", "mm": "objectivec",
        "cs": "csharp", "rs": "rust", "kt": "kotlin", "kts": "kotlin", "yml": "yaml", "htm": "xml", "html": "xml", "plist": "xml",
        "svg": "xml", "xib": "xml", "storyboard": "xml", "pl": "perl", "pm": "perl", "vb": "vbnet", "gradle": "groovy",
        "mk": "makefile", "toml": "ini", "cfg": "ini", "conf": "ini", "scss": "scss", "less": "less", "sql": "sql", "swift": "swift",
        "lua": "lua", "go": "go", "java": "java", "php": "php", "json": "json", "xml": "xml", "css": "css", "r": "r", "diff": "diff", "patch": "diff",
    ]

    static func kind(of url: URL) -> Kind? {
        let e = url.pathExtension.lowercased()
        if markdownExtensions.contains(e) { return .markdown }
        if let l = languages[e] { return .code(l) }
        if ["log", "txt", "text", "rtf"].contains(e) { return nil }
        return nil
    }

    /// Dossier des ressources web, quand elles ne sont pas dans le paquet (essais en ligne de commande).
    nonisolated(unsafe) static var resourceDirectory: URL?

    private static func resource(_ name: String) -> String {
        let u = resourceDirectory?.appendingPathComponent(name) ?? Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "web")
        guard let u, let s = try? String(contentsOf: u, encoding: .utf8) else { return "" }
        return s
    }

    static func html(for url: URL, kind: Kind) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let limit = 2 << 20
        guard let data = try? h.read(upToCount: limit + 1) else { return nil }
        let truncated = data.count > limit
        let text = String(decoding: data.prefix(limit), as: UTF8.self)
        let b64 = Data(text.utf8).base64EncodedString()
        let mode: String, lang: String
        switch kind {
        case .markdown: mode = "md"; lang = ""
        case .code(let l): mode = "code"; lang = l ?? ""
        }
        let note = truncated ? L.t("web.truncated") : ""
        let marked = mode == "md" ? resource("marked.min.js") : ""
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
        <style>
        :root{color-scheme:dark light;--bg:#1e1e1e;--sunk:#181818;--t:#ddd;--ts:#fff;--tm:#aaa;--bd:#333;--ac:#38bdf8}
        @media (prefers-color-scheme:light){:root{--bg:#fff;--sunk:#f2f2f2;--t:#222;--ts:#111;--tm:#555;--bd:#d4d4d4;--ac:#0369a1}}
        html,body{margin:0;background:var(--bg);color:var(--t);font:14px/1.6 -apple-system,BlinkMacSystemFont,sans-serif}
        .doc{max-width:860px;margin:0 auto;padding:24px 28px 48px}
        .code{max-width:none;padding:0}
        h1,h2,h3,h4{color:var(--ts);line-height:1.25;margin:1.4em 0 .5em}h1{font-size:1.8em;border-bottom:1px solid var(--bd);padding-bottom:.25em}h2{font-size:1.4em;border-bottom:1px solid var(--bd);padding-bottom:.2em}
        a{color:var(--ac)}code,pre{font:12.5px/1.5 ui-monospace,Menlo,monospace}
        :not(pre)>code{background:var(--sunk);padding:.15em .4em;border-radius:4px}
        pre{background:var(--sunk);border:1px solid var(--bd);border-radius:6px;padding:12px 14px;overflow:auto;margin:1em 0}
        .code pre{margin:0;border:0;border-radius:0;min-height:100vh;box-sizing:border-box}pre code{background:none;padding:0;white-space:pre}
        blockquote{margin:1em 0;padding:0 1em;border-left:3px solid var(--bd);color:var(--tm)}
        table{border-collapse:collapse;margin:1em 0}th,td{border:1px solid var(--bd);padding:6px 12px}th{background:var(--sunk);color:var(--ts)}
        .hljs{background:transparent!important;padding:0!important}img{max-width:100%}hr{border:0;border-top:1px solid var(--bd)}li input{margin-right:.4em}
        .note{color:var(--tm);font-size:12px;padding:8px 14px;border-top:1px solid var(--bd)}
        \(resource(mode == "md" || true ? "hl-dark.css" : ""))
        </style>
        <style media="(prefers-color-scheme:light)">\(resource("hl-light.css"))</style>
        <script>\(marked)</script>
        <script>\(resource("highlight.min.js"))</script>
        </head><body><div id="out" class="doc \(mode == "code" ? "code" : "")"></div>
        <script>
        const raw=new TextDecoder().decode(Uint8Array.from(atob("\(b64)"),c=>c.charCodeAt(0)));
        const out=document.getElementById('out');
        if("\(mode)"==="md"){
          out.innerHTML=marked.parse(raw,{gfm:true,breaks:false});
          out.querySelectorAll('pre code').forEach(e=>{try{hljs.highlightElement(e)}catch(_){}});
        }else{
          const pre=document.createElement('pre'),code=document.createElement('code');code.textContent=raw;
          const l="\(lang)";if(l&&hljs.getLanguage(l))code.className='language-'+l;
          pre.appendChild(code);out.appendChild(pre);
          try{l&&hljs.getLanguage(l)?hljs.highlightElement(code):(code.className='',hljs.highlightElement(code))}catch(_){}
        }
        \(note.isEmpty ? "" : "{const n=document.createElement('div');n.className='note';n.textContent=\(jsString(note));document.body.appendChild(n);}")
        </script></body></html>
        """
    }

    private static func jsString(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s])
        let j = String(decoding: d ?? Data(), as: UTF8.self)
        return String(j.dropFirst().dropLast())
    }
}
