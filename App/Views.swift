// aLPHALOOK — fenêtre principale : une colonne de cartes Socle centrée.
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var backdrop = Prefs.backdrop
    @State private var loop = Prefs.loop
    @State private var autoplay = Prefs.autoplay
    @State private var tryURL: URL?
    @State private var dropHover = false
    @ObservedObject private var ext = Extensions.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Socle.M.space4) {
                VStack(alignment: .leading, spacing: Socle.M.space1) {
                    Text(branded: "aLPHALOOK").socle(Socle.T.display).foregroundStyle(Socle.C.textStrong)
                    Text(L.t("app.tagline")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
                }
                previewCard
                extensionsCard
                tryCard
                Card(title: L.t("upd.title")) { UpdateSection() }
            }
            .frame(maxWidth: 720)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .background(Socle.C.bg)
        .frame(minWidth: 620, minHeight: 560)
    }

    private var previewCard: some View {
        Card(title: L.t("sec.preview"), subtitle: L.t("sec.preview.sub")) {
            HStack(spacing: Socle.M.space3) {
                Text(L.t("f.background")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                Spacer(minLength: Socle.M.space2)
                SocleSegmented(options: Backdrop.allCases, selection: backdrop, label: { L.t($0.labelKey) }) { b in
                    backdrop = b; Prefs.backdrop = b
                }
            }
            Check(title: L.t("f.loop"), isOn: Binding(get: { loop }, set: { loop = $0; Prefs.loop = $0 }))
            Check(title: L.t("f.autoplay"), isOn: Binding(get: { autoplay }, set: { autoplay = $0; Prefs.autoplay = $0 }))
            Hint(L.t("f.hint"))
        }
    }

    private var extensionsCard: some View {
        Card(title: L.t("sec.ext"), subtitle: L.t("sec.ext.sub")) {
            VStack(spacing: 0) {
                ExtensionRow(title: L.t("ext.preview"), status: ext.preview) { ext.enable(Extensions.previewID) }
                Rectangle().fill(Socle.C.border).frame(height: 1)
                ExtensionRow(title: L.t("ext.thumb"), status: ext.thumbnail) { ext.enable(Extensions.thumbnailID) }
            }
            HStack(spacing: Socle.M.space2) {
                Button(L.t("btn.settings")) { ext.openSettings() }.buttonStyle(SocleButtonStyle(.secondary)).lineLimit(1)
                Button(L.t("btn.reset")) { ext.resetThumbnails() }.buttonStyle(SocleButtonStyle(.secondary)).lineLimit(1)
            }
            Hint(ext.resetDone ? L.t("ext.reset.done") : L.t("ext.help"))
        }
    }

    private var tryCard: some View {
        Card(title: L.t("sec.try"), subtitle: L.t("sec.try.sub")) {
            ZStack {
                RoundedRectangle(cornerRadius: Socle.M.radiusLg)
                    .fill(dropHover ? Socle.C.surfaceHover : Socle.C.bgSunken)
                RoundedRectangle(cornerRadius: Socle.M.radiusLg)
                    .stroke(dropHover ? Socle.C.accent : Color.clear, lineWidth: 1)
                if let tryURL {
                    TrialPlayer(url: tryURL)
                        .clipShape(RoundedRectangle(cornerRadius: Socle.M.radiusLg))
                } else {
                    VStack(spacing: Socle.M.space1) {
                        Text(L.t("try.drop")).socle(Socle.T.title).foregroundStyle(Socle.C.text)
                        Text(L.t("try.formats")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                    }
                }
            }
            .frame(height: tryURL == nil ? 140 : 380)
            .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { tryURL = url } }
                }
                return true
            }
            HStack {
                Spacer()
                Button(L.t("btn.open")) { choose() }.buttonStyle(SocleButtonStyle(.primary)).frame(width: 220)
                Spacer()
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.quickTimeMovie, .movie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { tryURL = url }
    }
}

struct ExtensionRow: View {
    let title: String
    let status: Extensions.Status
    let enable: () -> Void

    var body: some View {
        HStack(spacing: Socle.M.space3) {
            Text(title).socle(Socle.T.body).foregroundStyle(Socle.C.text)
            Spacer(minLength: Socle.M.space2)
            switch status {
            case .on: Text("✓ " + L.t("ext.on")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.success)
            case .off, .missing:
                Text("⚠ " + L.t(status == .off ? "ext.off" : "ext.missing")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.warning)
                Button(L.t("btn.enable"), action: enable).buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
            }
        }
        .frame(minHeight: Socle.M.sizeControlLg)
        .padding(.vertical, Socle.M.space1)
    }
}

/// Lecteur d'essai : le même que dans l'aperçu QuickLook.
struct TrialPlayer: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var url: URL?
        var player: AlphaPlayerView?
        var label: NSTextField?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ host: NSView, context: Context) {
        let c = context.coordinator
        guard c.url != url else { return }
        c.url = url
        c.player?.stop(); c.player?.removeFromSuperview(); c.player = nil
        c.label?.removeFromSuperview(); c.label = nil
        let target = url
        Task { @MainActor in
            do {
                let src = try await Sources.open(target)
                guard c.url == target else { return }
                let p = AlphaPlayerView(source: src)
                Self.pin(p, in: host)
                c.player = p
            } catch {
                guard c.url == target else { return }
                let l = NSTextField(wrappingLabelWithString: L.t("err.open", error.localizedDescription))
                l.textColor = NSColor(Socle.C.danger)
                l.alignment = .center
                Self.pin(l, in: host, inset: 24)
                c.label = l
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.player?.stop() }

    private static func pin(_ v: NSView, in host: NSView, inset: CGFloat = 0) {
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset),
            v.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -inset),
            inset == 0 ? v.topAnchor.constraint(equalTo: host.topAnchor) : v.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            inset == 0 ? v.bottomAnchor.constraint(equalTo: host.bottomAnchor) : v.heightAnchor.constraint(lessThanOrEqualTo: host.heightAnchor),
        ])
    }
}

// MARK: Composants communs (repris de mBACKUP)

struct Card<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
                if let subtitle { Text(branded: subtitle).socle(Socle.T.body).foregroundStyle(Socle.C.accentText) }
            }
            content
        }
        .padding(Socle.M.space6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radiusLg))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radiusLg).stroke(Socle.C.border, lineWidth: 1))
    }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(branded: text).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true) }
}

struct Check: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) { Text(title).socle(Socle.T.body).foregroundStyle(Socle.C.text).fixedSize(horizontal: false, vertical: true) }
            .toggleStyle(.checkbox).tint(Socle.C.accent)
    }
}

struct UpdateSection: View {
    @ObservedObject var updater = Updater.shared
    @AppStorage("autoUpdate") private var auto = true

    private var status: String {
        switch updater.state {
        case .idle: return L.t("upd.version", updater.currentVersion)
        case .checking: return L.t("upd.checking")
        case .upToDate: return L.t("upd.uptodate", updater.currentVersion)
        case .available(let v): return L.t("upd.available", v)
        case .downloading: return L.t("upd.downloading")
        case .failed(let e): return L.t("upd.failed", e)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            Check(title: L.t("upd.auto"), isOn: $auto)
            HStack(spacing: Socle.M.space2) {
                Button(L.t("upd.check")) { Task { await updater.check() } }
                    .buttonStyle(SocleButtonStyle(.secondary)).lineLimit(1).frame(width: 240)
                    .disabled(updater.state == .checking || updater.state == .downloading)
                if case .available(let v) = updater.state {
                    Button(L.t("upd.install", v)) { Task { await updater.install() } }
                        .buttonStyle(SocleButtonStyle(.primary)).lineLimit(1).frame(width: 240)
                }
            }
            Hint(status)
        }
    }
}
