// qLOOKS — lecteur d'images à couche alpha : fond choisi (damier, sombre, clair), lecture en boucle, barre de commandes.
import AppKit

@MainActor
final class AlphaPlayerView: NSView {
    private let source: FrameSource
    private let canvas = CanvasView()
    private let bar = NSView()
    private let playButton = NSButton()
    private let loopButton = NSButton()
    private let slider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    private let backdropControl = NSSegmentedControl()

    private let decodeQueue = OperationQueue()
    private var cache: [Int: CGImage] = [:]
    private var inFlight = Set<Int>()
    private var current = -1          // image affichée
    private var target = 0            // image voulue
    private var timer: Timer?
    private(set) var playing = false
    private var generation = 0
    private let ahead: Int

    static let barHeight: CGFloat = 40

    init(source: FrameSource) {
        self.source = source
        ahead = source.randomAccess ? 6 : 3
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        decodeQueue.maxConcurrentOperationCount = source.randomAccess ? max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)) : 1
        decodeQueue.qualityOfService = .userInteractive
        appearance = NSAppearance(named: .darkAqua)
        build()
        canvas.backdrop = Prefs.backdrop
        canvas.videoSize = source.pixelSize
        request(0)
        if Prefs.autoplay, source.frameCount > 1 { play() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Interface

    private func build() {
        wantsLayer = true
        canvas.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = CGColor(srgbRed: 0.149, green: 0.149, blue: 0.149, alpha: 1)
        let rule = NSView(); rule.wantsLayer = true
        rule.layer?.backgroundColor = CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas); addSubview(bar); bar.addSubview(rule)

        canvas.onClick = { [weak self] in self?.toggle() }

        configure(playButton, symbol: "pause.fill", tip: L.t("pv.play"), action: #selector(toggle))
        configure(loopButton, symbol: "repeat", tip: L.t("pv.loop"), action: #selector(toggleLoop))
        loopButton.setButtonType(.toggle)
        loopButton.state = Prefs.loop ? .on : .off
        updateLoopTint()

        slider.minValue = 0
        slider.maxValue = Double(max(0, source.frameCount - 1))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self; slider.action = #selector(scrub)
        slider.isEnabled = source.frameCount > 1

        for l in [timeLabel, infoLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            l.textColor = NSColor(srgbRed: 0.667, green: 0.667, blue: 0.667, alpha: 1)
            l.lineBreakMode = .byTruncatingTail
        }
        infoLabel.stringValue = info()
        infoLabel.setContentCompressionResistancePriority(.defaultLow - 10, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        backdropControl.segmentCount = Backdrop.allCases.count
        backdropControl.trackingMode = .selectOne
        backdropControl.segmentStyle = .rounded
        backdropControl.controlSize = .small
        for (i, b) in Backdrop.allCases.enumerated() {
            backdropControl.setImage(NSImage(systemSymbolName: b.symbol, accessibilityDescription: L.t(b.labelKey)), forSegment: i)
            backdropControl.setToolTip(L.t(b.labelKey), forSegment: i)
            backdropControl.setWidth(30, forSegment: i)
        }
        backdropControl.selectedSegment = Backdrop.allCases.firstIndex(of: Prefs.backdrop) ?? 0
        backdropControl.target = self; backdropControl.action = #selector(changeBackdrop)
        backdropControl.toolTip = L.t("pv.background")

        let stack = NSStackView(views: [playButton, slider, timeLabel, infoLabel, backdropControl, loopButton])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            rule.topAnchor.constraint(equalTo: bar.topAnchor),
            rule.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        updateTime()
    }

    private func configure(_ b: NSButton, symbol: String, tip: String, action: Selector) {
        b.isBordered = false
        b.bezelStyle = .accessoryBarAction
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        b.imagePosition = .imageOnly
        b.toolTip = tip
        b.contentTintColor = .white
        b.target = self; b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func info() -> String {
        let s = source.pixelSize
        let fps = (1 / source.frameDuration).formatted(.number.precision(.fractionLength(0...3)).locale(L.locale))
        var parts = [source.codecName, "\(Int(s.width)) × \(Int(s.height))", L.t("pv.fps", fps)]
        parts.append(source.hasAlpha ? L.t("pv.alpha") : L.t("pv.noalpha"))
        return parts.joined(separator: " · ")
    }

    private func updateTime() {
        let f = Double(max(target, 0)) * source.frameDuration
        let total = Double(source.frameCount) * source.frameDuration
        let fmt = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2)).locale(L.locale)
        timeLabel.stringValue = "\(f.formatted(fmt)) / \(total.formatted(fmt)) s"
        slider.doubleValue = Double(max(target, 0))
    }

    private func updateLoopTint() {
        loopButton.contentTintColor = loopButton.state == .on
            ? NSColor(srgbRed: 0.2196, green: 0.7412, blue: 0.9725, alpha: 1)      // accent-text de Socle
            : NSColor(srgbRed: 0.5608, green: 0.5608, blue: 0.5608, alpha: 1)
    }

    private func updatePlayIcon() {
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: L.t("pv.play"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
    }

    // MARK: Lecture

    func play() {
        guard !playing, source.frameCount > 1 else { return }
        if target >= source.frameCount - 1, !Prefs.loop { target = 0; request(0) }
        playing = true
        let t = Timer(timeInterval: source.frameDuration, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        updatePlayIcon()
    }

    func pause() {
        playing = false
        timer?.invalidate(); timer = nil
        updatePlayIcon()
    }

    /// Arrêt définitif (aperçu fermé) : plus aucun décodage.
    func stop() {
        pause()
        generation += 1
        decodeQueue.cancelAllOperations()
        cache.removeAll()
    }

    @objc private func toggle() { playing ? pause() : play() }

    @objc private func toggleLoop() {
        Prefs.loop = loopButton.state == .on
        updateLoopTint()
    }

    @objc private func changeBackdrop() {
        let b = Backdrop.allCases[max(0, backdropControl.selectedSegment)]
        Prefs.backdrop = b
        canvas.backdrop = b
    }

    @objc private func scrub() {
        let i = Int(slider.doubleValue.rounded())
        if playing { pause() }
        target = i
        updateTime()
        request(i)
    }

    private func tick() {
        guard playing else { return }
        if current == target {                          // l'image voulue est à l'écran : on passe à la suivante
            var n = target + 1
            if n >= source.frameCount {
                guard Prefs.loop else { pause(); return }
                n = 0
            }
            target = n
        }
        request(target)
        updateTime()
    }

    private func wrap(_ i: Int) -> Int {
        let n = source.frameCount
        return Prefs.loop ? ((i % n) + n) % n : i
    }

    /// Affiche l'image si elle est prête et prépare les suivantes.
    private func request(_ i: Int) {
        if let img = cache[i] { show(i, img) }
        var wanted: [Int] = []
        for k in 0...ahead {
            let j = wrap(i + k)
            guard j >= 0, j < source.frameCount else { break }
            wanted.append(j)
        }
        let keep = Set(wanted + [current])
        for k in cache.keys where !keep.contains(k) { cache[k] = nil }
        for j in wanted where cache[j] == nil && !inFlight.contains(j) {
            if !source.randomAccess, inFlight.count >= 1 { break }       // lecture à la suite : une image à la fois, dans l'ordre
            inFlight.insert(j)
            let gen = generation, src = source
            decodeQueue.addOperation { [weak self] in
                let img = try? src.frame(j)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, gen == self.generation else { return }
                        self.inFlight.remove(j)
                        if let img { self.cache[j] = img }
                        if j == self.target, let img { self.show(j, img) }
                        if !src.randomAccess { self.request(self.target) }    // enchaîne l'image suivante
                    }
                }
            }
        }
    }

    private func show(_ i: Int, _ img: CGImage) {
        current = i
        canvas.image = img
    }
}

/// Zone de la vidéo : fond choisi dans le rectangle de l'image, image par-dessus (calque, pas de redessin à chaque image).
@MainActor
final class CanvasView: NSView {
    private let imageLayer = CALayer()
    var onClick: (() -> Void)?
    var videoSize: CGSize = .zero { didSet { needsLayout = true; needsDisplay = true } }
    var backdrop: Backdrop = .checker { didSet { needsDisplay = true } }
    var image: CGImage? {
        didSet {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            imageLayer.contents = image
            CATransaction.commit()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    private var videoRect: CGRect { Backdrops.fit(videoSize, in: bounds) }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = videoRect
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Backdrops.surround)
        ctx.fill(bounds)
        Backdrops.draw(backdrop, in: ctx, rect: videoRect, square: 10)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
