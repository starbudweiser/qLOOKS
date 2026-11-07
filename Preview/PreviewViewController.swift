// qLOOKS — extension d'aperçu QuickLook (barre d'espace) pour les .MOV.
// Vidéo à couche alpha ou codec que macOS ne lit pas (PNG, Animation) : notre lecteur sur damier.
// Autre vidéo : le lecteur du système (AVKit), avec le son.
import AppKit
import AVKit
import QuickLookUI
import WebKit

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var alphaPlayer: AlphaPlayerView?
    private var avPlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var webNav: WebNav?

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        v.wantsLayer = true
        v.layer?.backgroundColor = Backdrops.surround
        view = v
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        if Model3D.handles(url) {
            Task { @MainActor in
                guard let loaded = await Model3D.load(url) else { handler(FrameError.unreadable); return }
                if loaded.root != nil {
                    self.embed(ModelView(loaded: loaded))
                    self.preferredContentSize = CGSize(width: 760, height: 580)
                } else if let img = loaded.preview {
                    let v = NSImageView(image: img); v.imageScaling = .scaleProportionallyUpOrDown
                    self.embed(v)
                    self.preferredContentSize = Self.fitted(img.size, extra: 0)
                } else { handler(FrameError.unreadable); return }
                handler(nil)
            }
            return
        }
        if url.pathExtension.lowercased() == "gpx" {
            Task {
                guard let page = await GPX.html(for: url) else { handler(FrameError.unreadable); return }
                let web = WKWebView(frame: self.view.bounds, configuration: WKWebViewConfiguration())
                let nav = WebNav(done: { handler(nil) })
                web.navigationDelegate = nav
                self.webNav = nav
                self.embed(web)
                self.preferredContentSize = CGSize(width: 840, height: 760)
                web.loadHTMLString(page, baseURL: nil)
            }
            return
        }
        if let ak = AppInfo.kind(of: url) {
            Task.detached {
                let page = AppInfo.html(for: url, kind: ak)
                await MainActor.run {
                    guard let page else { handler(FrameError.unreadable); return }
                    let web = WKWebView(frame: self.view.bounds, configuration: WKWebViewConfiguration())
                    let nav = WebNav(done: { handler(nil) })
                    web.navigationDelegate = nav
                    self.webNav = nav
                    self.embed(web)
                    self.preferredContentSize = CGSize(width: 820, height: 700)
                    web.loadHTMLString(page, baseURL: nil)
                }
            }
            return
        }
        if let kind = WebDoc.kind(of: url) {
            guard let page = WebDoc.html(for: url, kind: kind) else { handler(FrameError.unreadable); return }
            let web = WKWebView(frame: view.bounds, configuration: WKWebViewConfiguration())
            let nav = WebNav(done: { handler(nil) })
            web.navigationDelegate = nav
            self.webNav = nav
            embed(web)
            preferredContentSize = CGSize(width: 860, height: 700)
            web.loadHTMLString(page, baseURL: nil)
            return
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if (exists && isDir.boolValue) || Archives.kind(of: url) != nil {
            Task.detached {
                let listing = try? Archives.listing(for: url)
                await MainActor.run {
                    guard let listing else { handler(FrameError.unreadable); return }
                    self.embed(TreeView(listing: listing, title: url.lastPathComponent))
                    self.preferredContentSize = CGSize(width: 640, height: 520)
                    handler(nil)
                }
            }
        } else if VectorImage.handles(url) {
            Task { @MainActor in
                guard let image = VectorImage.render(url, maxPixel: 2400) else { handler(FrameError.unreadable); return }
                let canvas = CanvasView()
                canvas.videoSize = CGSize(width: image.width, height: image.height)
                canvas.backdrop = Prefs.backdrop
                canvas.image = image
                self.embed(canvas)
                self.preferredContentSize = Self.fitted(canvas.videoSize, extra: 0)
                handler(nil)
            }
        } else if Sources.needsAlphaView(url) {
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


/// Page web locale : fin du chargement signalée à QuickLook ; les liens s'ouvrent dans le navigateur, jamais dans l'aperçu.
final class WebNav: NSObject, WKNavigationDelegate {
    private var done: (() -> Void)?
    init(done: @escaping () -> Void) { self.done = done }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done?(); done = nil }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { done?(); done = nil }
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if a.navigationType == .linkActivated, let u = a.request.url {
            if ["http", "https", "mailto"].contains(u.scheme ?? "") { NSWorkspace.shared.open(u) }
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
}
