// qLOOKS — mise à jour depuis les releases GitHub : recherche, téléchargement, vérification de la signature, remplacement.
import Foundation
import SwiftUI

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading
        case failed(String)
    }

    static let repo = "starbudweiser/qLOOKS"
    static let teamID = "35KLMK53PN"                   // seule signature acceptée pour une mise à jour
    private let interval: TimeInterval = 24 * 3600

    @Published private(set) var state: State = .idle
    private var assetURL: URL?
    private var checking = false

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var autoUpdate: Bool { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }

    /// Au lancement puis toutes les heures : une recherche par jour ; installation automatique quand aucune lecture d'essai ne tourne.
    func tick(busy: Bool) {
        let last = UserDefaults.standard.object(forKey: "updateLastCheck") as? Date ?? .distantPast
        if state == .idle || state == .upToDate, Date().timeIntervalSince(last) > interval, autoUpdate {
            Task { await check() }
        }
        if autoUpdate, !busy, case .available = state { Task { await install() } }
    }

    func check() async {
        guard !checking, state != .downloading else { return }
        checking = true; state = .checking
        defer { checking = false }
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { throw UpdateError.noRelease }
            UserDefaults.standard.set(Date(), forKey: "updateLastCheck")
            let assets = json["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            guard VersionCompare.isNewer(tag, than: currentVersion) else { state = .upToDate; return }
            guard let s = zip?["browser_download_url"] as? String, let url = URL(string: s) else { throw UpdateError.noRelease }
            assetURL = url
            state = .available(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Télécharge la nouvelle version, vérifie sa signature, puis remplace l'appli et la relance.
    func install() async {
        guard case .available = state, let url = assetURL else { return }
        state = .downloading
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("qLOOKS-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
            let zip = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: tmp, to: zip)
            let out = work.appendingPathComponent("out")
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
            let app = out.appendingPathComponent("qLOOKS.app")
            try await Self.verify(app)
            try Self.swapAndRelaunch(new: app, work: work)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }


    enum UpdateError: LocalizedError {
        case noRelease, download, badSignature, badVersion
        var errorDescription: String? {
            switch self {
            case .noRelease: return L.t("upd.err.none")
            case .download: return L.t("upd.err.download")
            case .badSignature: return L.t("upd.err.signature")
            case .badVersion: return L.t("upd.err.version")
            }
        }
    }

    /// La nouvelle appli doit être valide, signée par la même équipe et plus récente.
    private static func verify(_ app: URL) async throws {
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let info = try await run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
        guard info.contains("TeamIdentifier=\(teamID)") else { throw UpdateError.badSignature }
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              plist["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let v = plist["CFBundleShortVersionString"] as? String,
              VersionCompare.isNewer(v, than: Updater.shared.currentVersion) else { throw UpdateError.badVersion }
    }

    /// Un petit script détaché attend la fin de l'appli, remplace le paquet puis relance la nouvelle version.
    private static func swapAndRelaunch(new: URL, work: URL) throws {
        let target = Bundle.main.bundlePath
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(target)" && /usr/bin/ditto "\(new.path)" "\(target)" && /usr/bin/open -g "\(target)"
        rm -rf "\(work.path)"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }     // terminate() peut rester sans effet derrière une fenêtre modale
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
                p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                if p.terminationStatus == 0 { cont.resume(returning: text) }
                else { cont.resume(throwing: exe.hasSuffix("codesign") ? UpdateError.badSignature : UpdateError.download) }
            }
        }
    }
}
