// qLOOKS — éditeur d'extensions : décrire une extension macOS et confier sa création à un agent IA.
import SwiftUI
import Security

enum ExtKind: String, CaseIterable, Identifiable {
    case quicklook, thumbnail, action, share, finderSync, camera, endpoint, safari, widget, media
    var id: String { rawValue }
    var labelKey: String { "ee.k." + rawValue }
    /// Nom technique donné à l'agent (point d'extension Apple).
    var technical: String {
        switch self {
        case .quicklook: return "Quick Look Preview Extension (QLPreviewingController, com.apple.quicklook.preview)"
        case .thumbnail: return "Quick Look Thumbnail Extension (QLThumbnailProvider, com.apple.quicklook.thumbnail)"
        case .action: return "Finder Quick Action / Action extension (Automator-free, App Extension com.apple.services or com.apple.ui-services)"
        case .share: return "Share Extension (com.apple.share-services)"
        case .finderSync: return "Finder Sync Extension (FIFinderSync, com.apple.FinderSync)"
        case .camera: return "Camera Extension (CoreMediaIO system extension, CMIOExtension)"
        case .endpoint: return "Endpoint Security system extension (EndpointSecurity.framework, com.apple.system_extension.endpoint_security)"
        case .safari: return "Safari Web Extension (com.apple.Safari.web-extension)"
        case .widget: return "WidgetKit extension (com.apple.widgetkit-extension)"
        case .media: return "MediaExtension (decoder / format reader, VideoToolbox / MediaToolbox)"
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

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("qLOOKS Extensions")
    }

    static func prompt(kind: ExtKind, name: String, brief: String, dir: URL) -> String {
        """
        Create a complete macOS extension project in the current folder (\(dir.path)).

        Extension type: \(kind.technical)
        Name: \(name)
        Team ID: 35KLMK53PN (Developer ID signing; bundle IDs in the form fr.stephan.<name>).

        What it must do (written by the user, possibly in French):
        \(brief)

        Requirements:
        - Native Swift, no third-party dependency, a host app that registers/enables the extension, Info.plist and entitlements for the extension point, minimum macOS 14.
        - A build script (build.sh) that compiles with swiftc/xcodebuild, signs with the Developer ID certificate and installs to ~/Applications/Applications Personnelles.
        - Interface texts in 4 languages (French first, English, Spanish, Italian), same keys in every table.
        - Short README explaining how to enable the extension in System Settings.
        - Build it and fix compile errors before finishing; report what works and what needs a manual step.
        """
    }

    static func slug(_ s: String) -> String {
        let t = s.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let r = t.split(separator: "-").joined(separator: "-")
        return r.isEmpty ? "extension" : r
    }

    func start(kind: ExtKind, name: String, brief: String, agent: AgentKind) {
        guard !running else { return }
        let dir = Self.root.appendingPathComponent(Self.slug(name))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prompt = Self.prompt(kind: kind, name: name, brief: brief, dir: dir)
        try? prompt.write(to: dir.appendingPathComponent("PROMPT.md"), atomically: true, encoding: .utf8)
        folder = dir; log = ""; running = true
        switch agent {
        case .copy:
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(prompt, forType: .string)
            log = L.t("ee.copied"); running = false
        case .claudeCode: runCLI(prompt, in: dir)
        case .api: runAPI(prompt, in: dir)
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

    private func runAPI(_ prompt: String, in dir: URL) {
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
                try? text.write(to: dir.appendingPathComponent("RESPONSE.md"), atomically: true, encoding: .utf8)
                log = text; running = false
            } catch { if !Task.isCancelled { log = error.localizedDescription }; running = false }
        }
    }
}

struct ExtEditorPage: View {
    @StateObject private var builder = ExtBuilder()
    @AppStorage("ee.kind") private var kindRaw = ExtKind.quicklook.rawValue
    @AppStorage("ee.agent") private var agentRaw = AgentKind.claudeCode.rawValue
    @State private var name = ""
    @State private var brief = ""
    @State private var key = KeyStore.get()

    private var kind: ExtKind { ExtKind(rawValue: kindRaw) ?? .quicklook }
    private var agent: AgentKind { AgentKind(rawValue: agentRaw) ?? .claudeCode }
    private var ready: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            Card(title: L.t("ee.title"), subtitle: L.t("ee.sub")) {
                Text(L.t("ee.type")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: Socle.M.space2)], alignment: .leading, spacing: Socle.M.space2) {
                    ForEach(ExtKind.allCases) { k in
                        Button { kindRaw = k.rawValue } label: {
                            Text(L.t(k.labelKey)).socle(Socle.T.body).lineLimit(1)
                                .foregroundStyle(kind == k ? Socle.C.accentText : Socle.C.text)
                                .frame(maxWidth: .infinity).frame(height: Socle.M.sizeControl)
                                .background(RoundedRectangle(cornerRadius: Socle.M.radiusMd).fill(kind == k ? Socle.C.surfaceSelected : Socle.C.control))
                        }.buttonStyle(.plain)
                    }
                }
                Text(L.t("ee.name")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                TextField(L.t("ee.name.ph"), text: $name).textFieldStyle(.roundedBorder)
                Text(L.t("ee.brief")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                TextEditor(text: $brief)
                    .font(.system(size: 13)).scrollContentBackground(.hidden).padding(6)
                    .frame(minHeight: 130)
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
                HStack(spacing: Socle.M.space2) {
                    Button(L.t(agent == .copy ? "ee.copybtn" : "ee.create")) {
                        builder.start(kind: kind, name: name, brief: brief, agent: agent)
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
