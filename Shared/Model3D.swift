// qLOOKS — modèles 3D : STL, OBJ, PLY, USD, Alembic, Collada, SceneKit (via SceneKit) ; 3MF, 3DS, LWO, LWS (lecteurs maison) ;
// Cinema 4D (conversion par c4dpy si présent, sinon image d'aperçu enregistrée dans le fichier).
import AppKit
import Foundation
import SceneKit

/// Maillage simple : triangles dépliés avec une couleur par triangle.
struct Mesh {
    var positions: [SIMD3<Float>] = []                     // 3 par triangle
    var colors: [SIMD4<Float>] = []                        // 1 par sommet
    mutating func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, color: SIMD4<Float>) {
        positions.append(contentsOf: [a, b, c]); colors.append(contentsOf: [color, color, color])
    }
    var triangleCount: Int { positions.count / 3 }

    func geometry() -> SCNGeometry? {
        guard !positions.isEmpty else { return nil }
        var normals = [SIMD3<Float>](); normals.reserveCapacity(positions.count)
        var i = 0
        while i + 2 < positions.count {
            var n = simd_cross(positions[i + 1] - positions[i], positions[i + 2] - positions[i])
            let l = simd_length(n); n = l > 0 ? n / l : SIMD3<Float>(0, 1, 0)
            normals += [n, n, n]; i += 3
        }
        let pos = SCNGeometrySource(data: positions.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex, vectorCount: positions.count,
                                    usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let nor = SCNGeometrySource(data: normals.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .normal, vectorCount: normals.count,
                                    usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let col = SCNGeometrySource(data: colors.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .color, vectorCount: colors.count,
                                    usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let idx = (0..<Int32(positions.count)).map { $0 }
        let el = SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles, primitiveCount: positions.count / 3, bytesPerIndex: 4)
        let g = SCNGeometry(sources: [pos, nor, col], elements: [el])
        let m = SCNMaterial(); m.lightingModel = .blinn; m.isDoubleSided = true
        m.diffuse.contents = NSColor.white; m.specular.contents = NSColor(white: 0.25, alpha: 1)
        g.materials = [m]
        return g
    }
}

enum Model3D {
    static let sceneKitExtensions: Set<String> = ["stl", "obj", "ply", "usd", "usda", "usdc", "usdz", "abc", "dae", "scn"]
    static let customExtensions: Set<String> = ["3mf", "3ds", "lwo", "lws"]
    static let c4dExtensions: Set<String> = ["c4d"]
    static let previewOnlyExtensions: Set<String> = ["max"]

    static func handles(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return sceneKitExtensions.contains(e) || customExtensions.contains(e) || c4dExtensions.contains(e) || previewOnlyExtensions.contains(e)
    }

    struct Loaded {
        var root: SCNNode?
        var preview: NSImage?                    // image d'aperçu quand il n'y a pas de géométrie (c4d sans Cinema 4D)
        var triangles = 0
        var format = ""
        var note: String?
    }

    /// Z vers le haut pour la plupart des formats d'impression et de DAO : SceneKit est en Y vers le haut.
    private static let zUp: Set<String> = ["stl", "3mf", "ply", "3ds"]

    static func load(_ url: URL) async -> Loaded? {
        let e = url.pathExtension.lowercased()
        var out = Loaded(); out.format = e.uppercased()
        switch e {
        case "3mf":
            guard let m = ThreeMF.load(url) else { return nil }
            out.root = node(from: m); out.triangles = m.triangleCount
        case "stl":
            guard let m = STL.load(url) else { return nil }
            out.root = node(from: m); out.triangles = m.triangleCount
        case "max":
            guard let img = MaxFile.preview(url) else { return nil }
            out.preview = img; out.note = "preview"
        case "3ds":
            guard let m = ThreeDS.load(url) else { return nil }
            out.root = node(from: m); out.triangles = m.triangleCount
        case "lwo":
            guard let m = LWO.load(url) else { return nil }
            out.root = node(from: m); out.triangles = m.triangleCount
        case "lws":
            guard let (n, t) = LWS.load(url) else { return nil }
            out.root = n; out.triangles = t
        case "c4d":
            let r = await C4D.load(url)
            out.root = r.root; out.preview = r.preview; out.triangles = r.triangles; out.note = r.note
            if out.root == nil && out.preview == nil { return nil }
        default:
            guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false, .convertToYUp: true]) else { return nil }
            out.root = scene.rootNode
            out.triangles = countTriangles(scene.rootNode)
            applyDefaultMaterialIfNeeded(scene.rootNode)
        }
        if let r = out.root, zUp.contains(e) { r.eulerAngles.x = -.pi / 2 }
        return out
    }

    static func node(from m: Mesh) -> SCNNode? {
        guard let g = m.geometry() else { return nil }
        return SCNNode(geometry: g)
    }

    static func countTriangles(_ n: SCNNode) -> Int {
        var t = 0
        n.enumerateHierarchy { node, _ in
            for el in node.geometry?.elements ?? [] {
                switch el.primitiveType {
                case .triangles: t += el.primitiveCount
                case .triangleStrip: t += max(0, el.primitiveCount)
                default: break
                }
            }
        }
        return t
    }

    private static func applyDefaultMaterialIfNeeded(_ root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            guard let g = node.geometry else { return }
            for m in g.materials where m.diffuse.contents == nil { m.diffuse.contents = NSColor(white: 0.78, alpha: 1) }
            if g.materials.isEmpty { let m = SCNMaterial(); m.diffuse.contents = NSColor(white: 0.78, alpha: 1); g.materials = [m] }
        }
    }

    // MARK: Scène prête à afficher

    static func scene(for root: SCNNode) -> SCNScene {
        let scene = SCNScene()
        let holder = SCNNode(); holder.addChildNode(root)
        // Centrage et mise à l'échelle : le modèle tient dans une sphère de rayon 1.
        let (lo, hi) = bounds(of: root, in: holder)
        let c = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        let r = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z) / 2
        let k: CGFloat = r > 0 ? 1 / r : 1
        root.position = SCNVector3(-c.x, -c.y, -c.z)
        holder.scale = SCNVector3(k, k, k)
        scene.rootNode.addChildNode(holder)
        let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera?.zNear = 0.01; cam.camera?.zFar = 100; cam.camera?.fieldOfView = 40
        cam.position = SCNVector3(0, 0.5, 3.4); cam.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cam)
        let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient; amb.light?.intensity = 450
        scene.rootNode.addChildNode(amb)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional; key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.7, 0.6, 0); scene.rootNode.addChildNode(key)
        let fill = SCNNode(); fill.light = SCNLight(); fill.light?.type = .directional; fill.light?.intensity = 350
        fill.eulerAngles = SCNVector3(0.3, -2.4, 0); scene.rootNode.addChildNode(fill)
        scene.background.contents = NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)
        return scene
    }

    /// Boîte englobante de toute la hiérarchie, exprimée dans le repère de `space`.
    static func bounds(of root: SCNNode, in space: SCNNode) -> (SCNVector3, SCNVector3) {
        var lo = SCNVector3(CGFloat.greatestFiniteMagnitude, CGFloat.greatestFiniteMagnitude, CGFloat.greatestFiniteMagnitude)
        var hi = SCNVector3(-CGFloat.greatestFiniteMagnitude, -CGFloat.greatestFiniteMagnitude, -CGFloat.greatestFiniteMagnitude)
        var any = false
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                let p = node.convertPosition(SCNVector3(x, y, z), to: space)
                lo = SCNVector3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)); hi = SCNVector3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)); any = true
            } } }
        }
        return any ? (lo, hi) : (SCNVector3Zero, SCNVector3(1, 1, 1))
    }

    /// Dimensions de la boîte englobante (unités du fichier, sans la rotation de mise à l'endroit).
    static func dimensions(_ root: SCNNode) -> (Double, Double, Double) {
        let hold = SCNNode()
        let saved = root.eulerAngles
        root.eulerAngles = SCNVector3Zero
        hold.addChildNode(root)
        let (lo, hi) = bounds(of: root, in: root)
        root.eulerAngles = saved
        root.removeFromParentNode()
        return (Double(hi.x - lo.x), Double(hi.y - lo.y), Double(hi.z - lo.z))
    }

    /// Vignette : rendu hors écran.
    static func snapshot(_ root: SCNNode, size: CGSize) -> CGImage? {
        let scene = Self.scene(for: root)
        scene.background.contents = NSColor.clear
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let r = SCNRenderer(device: device, options: nil)
        r.scene = scene
        r.autoenablesDefaultLighting = false
        let img = r.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
