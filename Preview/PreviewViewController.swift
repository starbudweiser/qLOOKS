// qLOOKS — extension d'aperçu QuickLook (barre d'espace) pour les .MOV.
// Vidéo à couche alpha ou codec que macOS ne lit pas (PNG, Animation) : notre lecteur sur damier.
// Autre vidéo : le lecteur du système (AVKit), avec le son.
import AppKit
import AVKit
import QuickLookUI

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var alphaPlayer: AlphaPlayerView?
    private var avPlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        v.wantsLayer = true
        v.layer?.backgroundColor = Backdrops.surround
        view = v
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        if Sources.needsAlphaView(url) {
            Task { @MainActor in
                do {
                    let src = try await Sources.open(url)
                    let player = AlphaPlayerView(source: src)
                    self.embed(player)
                    self.alphaPlayer = player
                    self.preferredContentSize = Self.fitted(src.pixelSize, extra: AlphaPlayerView.barHeight)
                    handler(nil)
                } catch {
                    handler(error)
                }
            }
        } else {
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            if Prefs.loop { looper = AVPlayerLooper(player: player, templateItem: item) } else { player.insert(item, after: nil) }
            let pv = AVPlayerView()
            pv.controlsStyle = .floating
            pv.player = player
            embed(pv)
            avPlayer = player
            if Prefs.autoplay { player.play() }
            handler(nil)
        }
    }

    private func embed(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: view.topAnchor),
            v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// Taille d'aperçu proposée : la vidéo, réduite pour tenir dans 1280 × 800.
    static func fitted(_ size: CGSize, extra: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 800, height: 500) }
        let k = min(1, 1280 / size.width, 800 / size.height)
        return CGSize(width: max(480, (size.width * k).rounded()), height: (size.height * k).rounded() + extra)
    }

    // QuickLook peut masquer puis réafficher la vue pendant le chargement : on met en pause, sans jamais abandonner la lecture.
    override func viewDidAppear() {
        super.viewDidAppear()
        if Prefs.autoplay { alphaPlayer?.play(); avPlayer?.play() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        alphaPlayer?.pause()
        avPlayer?.pause()
    }

    deinit {
        MainActor.assumeIsolated {
            alphaPlayer?.stop()
            avPlayer?.pause()
        }
    }
}
