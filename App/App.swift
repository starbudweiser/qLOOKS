// aLPHALOOK — appli hôte des extensions QuickLook : réglages de l'aperçu (fond, boucle), état des extensions, essai d'un fichier.
import SwiftUI

enum Brand {
    static let ns = NSColor(srgbRed: 0x8b / 255, green: 0x5c / 255, blue: 0xf6 / 255, alpha: 1)   // violet du logo
    static let color = Color(nsColor: ns)
}

@main
struct AlphaLookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("aLPHALOOK", id: "main") {
            ContentView()
        }
        .defaultSize(width: 776, height: 980)
        .commands {
            CommandGroup(replacing: .appInfo) { Button(L.t("menu.about")) { About.show() } }
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Socle.brand("aLPHALOOK", color: Brand.color)
        Socle.apply()
        Extensions.shared.refresh()
        DispatchQueue.main.async {
            NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true || $0.title == "aLPHALOOK" }?.socleCenter()
        }
        Task { @MainActor in Updater.shared.tick(busy: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in Updater.shared.tick(busy: false) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { Extensions.shared.refresh() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Compare deux numéros de version « 1.2.3 » (un éventuel « v » initial est ignoré).
enum VersionCompare {
    static func parts(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

/// État des deux extensions dans PlugInKit, activation, et remise à zéro du cache des vignettes.
@MainActor
final class Extensions: ObservableObject {
    static let shared = Extensions()
    enum Status { case on, off, missing }
    nonisolated static let previewID = "fr.stephan.alphalook.preview"
    nonisolated static let thumbnailID = "fr.stephan.alphalook.thumbnail"

    @Published private(set) var preview: Status = .missing
    @Published private(set) var thumbnail: Status = .missing
    @Published var resetDone = false

    func refresh() {
        Task.detached {
            let p = Self.status(Self.previewID), t = Self.status(Self.thumbnailID)
            await MainActor.run { self.preview = p; self.thumbnail = t }
        }
    }

    func enable(_ id: String) {
        Task.detached {
            Self.run("/usr/bin/pluginkit", ["-e", "use", "-i", id])
            await MainActor.run { self.refresh() }
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") { NSWorkspace.shared.open(url) }
    }

    func resetThumbnails() {
        Task.detached {
            Self.run("/usr/bin/qlmanage", ["-r", "cache"])
            Self.run("/usr/bin/qlmanage", ["-r"])
            await MainActor.run { self.resetDone = true }
        }
    }

    /// « + » activée, « - » désactivée ; sans signe, l'extension suit le choix par défaut du système (activée).
    nonisolated static func status(_ id: String) -> Status {
        let out = run("/usr/bin/pluginkit", ["-m", "-A", "-i", id])
        guard let line = out.split(separator: "\n").first(where: { $0.contains(id) }) else { return .missing }
        return line.trimmingCharacters(in: .whitespaces).hasPrefix("-") ? .off : .on
    }

    @discardableResult
    nonisolated static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
