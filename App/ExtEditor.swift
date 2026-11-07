// qLOOKS — éditeur d'extensions : décrire une extension macOS et confier sa création à un agent IA.
import SwiftUI
import Security

enum FormatScope: String, CaseIterable, Identifiable {
    case both, preview, thumb
    var id: String { rawValue }
    var labelKey: String { "ee.s." + rawValue }
    var technical: String {
        switch self {
        case .both: return "both the Quick Look preview (spacebar) and the Finder thumbnail"
        case .preview: return "the Quick Look preview (spacebar) only"
        case .thumb: return "the Finder thumbnail only"
        }
    }
}

enum AgentKind: String, CaseIterable, Identifiable {
    case claudeCode, api, copy
    var id: String { rawValue }
    var labelKey: String { "ee.a." + rawValue }
}

enum KeyStore {
    private static let service = "fr.stephan.alphalook.agentkey"
    static func get() -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }
    static func set(_ v: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard !v.isEmpty else { return }
        var add = base; add[kSecValueData as String] = Data(v.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

@MainActor
final class ExtBuilder: ObservableObject {
    @Published var running = false
    @Published var log = ""
    @Published var folder: URL?
    private var process: Process?
    private var task: Task<Void, Never>?

    static var outDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("qLOOKS Formats")
    }
    static let defaultSource = "/Volumes/OWC 6To/TAF/DEV/qLOOKS"

    static func prompt(scope: FormatScope, format: String, exts: String, sample: String, brief: String, src: String) -> String {
        """
        You are working on qLOOKS (macOS app, source in \(src)): one QuickLook app whose Preview extension, Thumbnail extension and MediaExtension add file formats macOS cannot display. Read CLAUDE.md / README and the existing format handlers in Shared/ first, and follow the same patterns.

        Task: add support for the file format "\(format)" (extensions: \(exts)) for \(scope.technical).
        \(sample.isEmpty ? "No sample file was given: find or write test files yourself." : "Sample file: \(sample)")

        What the preview must show (written by the user, possibly in French):
        \(brief)

        Steps:
        1. Declare the file extensions / UTIs in Resources/Preview-Info.plist and/or Resources/Thumbnail-Info.plist (QLSupportedContentTypes), exporting a UTI in Resources/Info.plist if the system has none.
        2. Write the parser/renderer in Shared/ (native Swift, no dependency, sandbox-safe), then dispatch to it from Preview/PreviewViewController.swift and/or Thumbnail/ThumbnailProvider.swift.
        3. Register it in App/Formats.swift (FormatEntry with the next version; bump the version in Resources/Info.plist) and add every new text to Shared/L10n.swift in the 4 languages (fr, en, es, it).
        4. Test with a headless harness, run ./build_app.sh (builds, signs, installs, registers the extensions), and fix errors.
        5. Commit in French and push to main. Report what works and any limit.
        """
    }

    static func slug(_ s: String) -> String {
        let t = s.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let r = t.split(separator: "-").joined(separator: "-")
        return r.isEmpty ? "format" : r
    }

    func start(prompt: String, name: String, src: String, agent: AgentKind) {
        guard !running else { return }
        folder = nil; log = ""; running = true
        switch agent {
        case .copy:
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(prompt, forType: .string)
            log = L.t("ee.copied"); running = false
        case .claudeCode:
            guard FileManager.default.fileExists(atPath: src + "/build_app.sh") else { log = L.t("ee.nosrc"); running = false; return }
            folder = URL(fileURLWithPath: src); runCLI(prompt, in: folder!)
        case .api:
            try? FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
            folder = Self.outDir; runAPI(prompt, to: Self.outDir.appendingPathComponent(Self.slug(name) + ".md"))
        }
    }

    func stop() { process?.terminate(); task?.cancel(); running = false; log += "\n" + L.t("ee.stopped") }

    private func runCLI(_ prompt: String, in dir: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            log = L.t("ee.nocli"); running = false; return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-p", prompt, "--permission-mode", "acceptEdits", "--allowedTools", "Bash,Read,Write,Edit,Glob,Grep"]
        p.currentDirectoryURL = dir
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.log += s }
        }
        p.terminationHandler = { [weak self] pr in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self?.running = false
                self?.log += "\n" + L.t(pr.terminationStatus == 0 ? "ee.done" : "ee.failed", Int(pr.terminationStatus))
            }
        }
        do { try p.run(); process = p } catch { log = error.localizedDescription; running = false }
    }

    private func runAPI(_ prompt: String, to file: URL) {
        let key = KeyStore.get()
        guard !key.isEmpty else { log = L.t("ee.nokey"); running = false; return }
        task = Task {
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.timeoutInterval = 600
            let body: [String: Any] = ["model": "claude-sonnet-5-5", "max_tokens": 16000,
                                       "messages": [["role": "user", "content": prompt]]]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let text = ((json?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n"))
                    ?? ((json?["error"] as? [String: Any])?["message"] as? String) ?? "?"
                try? text.write(to: file, atomically: true, encoding: .utf8)
                log = text; running = false
            } catch { if !Task.isCancelled { log = error.localizedDescription }; running = false }
        }
    }
}

struct ExtEditorPage: View {
    @StateObject private var builder = ExtBuilder()
    @AppStorage("ee.scope") private var scopeRaw = FormatScope.both.rawValue
    @AppStorage("ee.agent") private var agentRaw = AgentKind.claudeCode.rawValue
    @AppStorage("ee.src") private var src = ExtBuilder.defaultSource
    @State private var format = ""
    @State private var exts = ""
    @State private var sample = ""
    @State private var brief = ""
    @State private var key = KeyStore.get()

    private var scope: FormatScope { FormatScope(rawValue: scopeRaw) ?? .both }
    private var agent: AgentKind { AgentKind(rawValue: agentRaw) ?? .claudeCode }
    private var ready: Bool {
        !format.trimmingCharacters(in: .whitespaces).isEmpty && !exts.trimmingCharacters(in: .whitespaces).isEmpty
            && !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func label(_ k: String) -> some View { Text(L.t(k)).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted) }

    private func pick(files: Bool, set: @escaping (String) -> Void) {
        let p = NSOpenPanel(); p.canChooseFiles = files; p.canChooseDirectories = !files; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { set(u.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            Card(title: L.t("ee.title"), subtitle: L.t("ee.sub")) {
                label("ee.scope")
                SocleSegmented(options: FormatScope.allCases, selection: scope, label: { L.t($0.labelKey) }) { scopeRaw = $0.rawValue }
                label("ee.fmt")
                TextField(L.t("ee.fmt.ph"), text: $format).textFieldStyle(.roundedBorder)
                label("ee.exts")
                TextField(L.t("ee.exts.ph"), text: $exts).textFieldStyle(.roundedBorder)
                label("ee.sample")
                HStack(spacing: Socle.M.space2) {
                    Text(sample.isEmpty ? L.t("ee.none") : (sample as NSString).lastPathComponent)
                        .socle(Socle.T.body).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button(L.t("ee.pick")) { pick(files: true) { sample = $0 } }.buttonStyle(SocleButtonStyle(.secondary)).lineLimit(1)
                }
                label("ee.brief")
                TextEditor(text: $brief)
                    .font(.system(size: 13)).scrollContentBackground(.hidden).padding(6)
                    .frame(minHeight: 110)
                    .background(Socle.C.bgSunken, in: RoundedRectangle(cornerRadius: Socle.M.radiusMd))
                    .overlay(RoundedRectangle(cornerRadius: Socle.M.radiusMd).stroke(Socle.C.borderControl, lineWidth: 1))
            }
            Card(title: L.t("ee.agent")) {
                SocleSegmented(options: AgentKind.allCases, selection: agent, label: { L.t($0.labelKey) }) { agentRaw = $0.rawValue }
                if agent == .api {
                    SecureField("sk-ant-…", text: $key).textFieldStyle(.roundedBorder)
                        .onChange(of: key) { _, v in KeyStore.set(v) }
                    Hint(L.t("ee.keyhint"))
                } else {
                    Hint(L.t(agent == .claudeCode ? "ee.cli.hint" : "ee.copy.hint"))
                }
                if agent == .claudeCode {
                    label("ee.src")
                    HStack(spacing: Socle.M.space2) {
                        Text(src).socle(Socle.T.body).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button(L.t("ee.pick")) { pick(files: false) { src = $0 } }.buttonStyle(SocleButtonStyle(.secondary)).lineLimit(1)
                    }
                }
                HStack(spacing: Socle.M.space2) {
                    Button(L.t(agent == .copy ? "ee.copybtn" : "ee.create")) {
                        let p = ExtBuilder.prompt(scope: scope, format: format, exts: exts, sample: sample, brief: brief, src: src)
                        builder.start(prompt: p, name: format, src: src, agent: agent)
                    }
                    .buttonStyle(SocleButtonStyle(.primary, height: Socle.M.sizeControl)).lineLimit(1)
                    .disabled(!ready || builder.running)
                    if builder.running {
                        Button(L.t("ee.stop")) { builder.stop() }.buttonStyle(SocleButtonStyle(.secondary)).lineLimit(1)
                        ProgressView().controlSize(.small)
                    }
                    if let f = builder.folder {
                        Button(L.t("ee.open")) { NSWorkspace.shared.open(f) }.buttonStyle(SocleButtonStyle(.secondary)).lineLimit(1)
                    }
                }
                if !builder.log.isEmpty {
                    ScrollView {
                        Text(builder.log).font(.system(size: 11, design: .monospaced)).foregroundStyle(Socle.C.text)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .frame(height: 200)
                    .background(Socle.C.bgSunken, in: RoundedRectangle(cornerRadius: Socle.M.radiusMd))
                }
            }
        }
    }
}
