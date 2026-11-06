// qLOOKS — vue d'aperçu d'un modèle 3D : rotation à la souris, rotation lente au départ, informations en pied.
import AppKit
import SceneKit

@MainActor
final class ModelView: NSView {
    private let scn = SCNView()
    private let info = NSTextField(labelWithString: "")
    private let holderKey = "turn"

    init(loaded: Model3D.Loaded) {
        super.init(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = CGColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)
        scn.translatesAutoresizingMaskIntoConstraints = false
        info.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scn); addSubview(info)
        info.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        info.textColor = NSColor(srgbRed: 0.667, green: 0.667, blue: 0.667, alpha: 1)
        NSLayoutConstraint.activate([
            scn.topAnchor.constraint(equalTo: topAnchor), scn.leadingAnchor.constraint(equalTo: leadingAnchor), scn.trailingAnchor.constraint(equalTo: trailingAnchor),
            scn.bottomAnchor.constraint(equalTo: info.topAnchor, constant: -6),
            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), info.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            info.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        if let root = loaded.root {
            let (x, y, z) = Model3D.dimensions(root)
            let f = NumberFormatter(); f.maximumFractionDigits = 2; f.locale = L.locale
            let dims = [x, y, z].map { f.string(from: NSNumber(value: $0)) ?? "" }.joined(separator: " × ")
            let tri = NumberFormatter(); tri.numberStyle = .decimal; tri.locale = L.locale
            info.stringValue = [loaded.format, L.t("m3d.tris", tri.string(from: NSNumber(value: loaded.triangles)) ?? ""), dims].joined(separator: "  ·  ")
            let scene = Model3D.scene(for: root)
            scn.scene = scene
            scn.allowsCameraControl = true
            scn.preferredFramesPerSecond = 60
            scn.antialiasingMode = .multisampling4X
            scn.backgroundColor = NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)
            if let holder = scene.rootNode.childNodes.first {
                holder.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 28)), forKey: holderKey)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        scn.scene?.rootNode.childNodes.first?.removeAction(forKey: holderKey)    // l'utilisateur prend la main : fin de la rotation lente
        super.mouseDown(with: event)
    }
}
