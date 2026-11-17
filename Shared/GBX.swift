// qLOOKS — Nadeo GameBox (.Gbx, TrackMania) : lecteur maison, sans dépendance.
// • GBX « texte » (en-tête « GBX » version 6, format T) : solides CPlugSolid → arbres CPlugTree → visuels
//   CPlugVisualIndexedTriangles. Chaque visuel donne ses sommets (position, normale, couleur), ses coordonnées de
//   texture et ses index ; la position de son arbre (CPlugTree 0x0904F01A) le place dans le modèle. Les textures DDS
//   rangées à côté du fichier (Diffuse.dds, Details.dds, convention des voitures TrackMania) sont appliquées si
//   elles sont lisibles (la sandbox des extensions QuickLook ne donne accès qu'au fichier lui-même : gris sinon).
// • GBX binaire (circuits .Challenge/.Map.Gbx…) : la miniature JPEG enregistrée dans l'en-tête, s'il y en a une.
import AppKit
import Foundation
import ImageIO
import SceneKit

enum GBX {
    private static let crlf: [UInt8] = [13, 10]

    struct Part {
        var name: String
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        var transform = SCNMatrix4Identity
    }

    // MARK: Lecture des octets

    private struct Cursor {
        let b: [UInt8]
        var p: Int
        /// Jeton texte jusqu'au prochain CR LF.
        mutating func token(max: Int = 256) -> String? {
            var e = p
            let lim = min(b.count - 1, p + max)
            while e < lim, !(b[e] == 13 && b[e + 1] == 10) { e += 1 }
            guard e < lim else { return nil }
            let s = String(decoding: b[p..<e], as: UTF8.self)
            p = e + 2
            return s
        }
        mutating func int() -> Int? { token().flatMap { Int($0) } }
        mutating func float() -> Float? { token().flatMap { Float($0) } }
        func f32(_ o: Int) -> Float { Float(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24) }
        func u16(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 }
    }

    /// Positions de toutes les occurrences de « \r\n<marqueur>\r\n » (renvoie l'indice juste après).
    private static func find(_ marker: String, in b: [UInt8], from: Int = 0, to: Int? = nil) -> [Int] {
        let m = crlf + Array(marker.utf8) + crlf
        let end = min(to ?? b.count, b.count) - m.count
        guard end >= from else { return [] }
        var out: [Int] = []
        var i = from
        let first = m[0]
        while i <= end {
            if b[i] == first {
                var ok = true
                for k in 1..<m.count where b[i + k] != m[k] { ok = false; break }
                if ok { out.append(i + m.count); i += m.count; continue }
            }
            i += 1
        }
        return out
    }

    private static func findFirst(_ marker: String, in b: [UInt8], from: Int, to: Int) -> Int? {
        let m = crlf + Array(marker.utf8) + crlf
        var i = from
        while i + m.count <= min(to, b.count) {
            if b[i] == 13 {
                var ok = true
                for k in 1..<m.count where b[i + k] != m[k] { ok = false; break }
                if ok { return i + m.count }
            }
            i += 1
        }
        return nil
    }

    private static func findLast(_ marker: String, in b: [UInt8], before: Int, after: Int) -> Int? {
        let m = crlf + Array(marker.utf8) + crlf
        var i = before - m.count
        while i >= after {
            if b[i] == 13 {
                var ok = true
                for k in 1..<m.count where b[i + k] != m[k] { ok = false; break }
                if ok { return i + m.count }
            }
            i -= 1
        }
        return nil
    }

    // MARK: Solides (GBX texte)

    static func isText(_ b: [UInt8]) -> Bool { b.count > 9 && b[0] == 0x47 && b[1] == 0x42 && b[2] == 0x58 && b[5] == 0x54 }  // « GBX » … « T »

    static func parts(_ b: [UInt8]) -> [Part] {
        let visuals = find("900600c", in: b)
        var out: [Part] = []
        for (vi, start) in visuals.enumerated() {
            let limit = vi + 1 < visuals.count ? visuals[vi + 1] : b.count
            var c = Cursor(b: b, p: start)
            // 0x0900600C : statique, statique, jeux de coordonnées de texture, drapeaux, nombre de sommets, réserve.
            guard c.token() != nil, c.token() != nil, let texSets = c.int(), c.token() != nil, let n = c.int(), c.token() != nil,
                  n > 0, n < 5_000_000, (0...8).contains(texSets) else { continue }
            var part = Part(name: "")
            var bad = false
            for k in 0..<texSets {
                guard c.token() != nil, c.p + n * 8 <= b.count else { bad = true; break }
                if k == 0 {
                    part.uvs.reserveCapacity(n)
                    for i in 0..<n { part.uvs.append(SIMD2(c.f32(c.p + i * 8), c.f32(c.p + i * 8 + 4))) }
                }
                c.p += n * 8
            }
            if bad { continue }
            // Boîte englobante (booléen + centre + demi-taille), puis 0x0902C002 et 0x0902C003 (sommets).
            for _ in 0..<7 { _ = c.token() }
            guard c.token() == "902c002", c.token() != nil, c.token() == "902c003" else { continue }
            let vStart = c.p
            // Pas d'un sommet : déduit de la distance au bloc suivant (0x0906A001), 40 octets en général.
            guard let next = findFirst("906a001", in: b, from: vStart, to: limit) else { continue }
            let vBytes = next - "\r\n906a001\r\n".utf8.count - 4 - vStart    // « 0\r\n0 » avant 0x0906A001
            let stride = vBytes / n
            guard stride >= 12, vStart + n * stride <= b.count else { continue }
            part.positions.reserveCapacity(n); part.normals.reserveCapacity(n)
            for i in 0..<n {
                let o = vStart + i * stride
                part.positions.append(SIMD3(c.f32(o), c.f32(o + 4), c.f32(o + 8)))
                if stride >= 24 { part.normals.append(SIMD3(c.f32(o + 12), c.f32(o + 16), c.f32(o + 20))) }
                if stride >= 40 { part.colors.append(SIMD4(c.f32(o + 24), c.f32(o + 28), c.f32(o + 32), c.f32(o + 36))) }
            }
            if part.positions.contains(where: { !$0.x.isFinite || !$0.y.isFinite || !$0.z.isFinite }) { continue }
            // Index (CPlugIndexBuffer 0x09057000) : 4 octets, nombre en texte, puis index 16 bits.
            guard let ib = findFirst("9057000", in: b, from: next, to: limit) else { continue }
            var ic = Cursor(b: b, p: ib + 4)
            guard let count = ic.int(), count >= 3, ic.p + count * 2 <= b.count else { continue }
            part.indices.reserveCapacity(count - count % 3)
            for i in 0..<(count - count % 3) {
                let v = ic.u16(ic.p + i * 2)
                guard v < n else { bad = true; break }
                part.indices.append(v)
            }
            if bad { continue }
            // Nom de l'arbre (0x0904F00D) qui précède le visuel, position de l'arbre (0x0904F01A) qui le suit.
            let prev = vi > 0 ? visuals[vi - 1] : 0
            if let nm = findLast("904f00d", in: b, before: start, after: prev) {
                var nc = Cursor(b: b, p: nm)
                // Index de nœud et drapeaux éventuels (nombres), puis le nom.
                for _ in 0..<3 {
                    guard let t = nc.token() else { break }
                    if !t.isEmpty, !t.allSatisfy({ $0.isHexDigit }) { part.name = t; break }
                }
            }
            if let loc = findFirst("904f01a", in: b, from: ic.p, to: limit) {
                var lc = Cursor(b: b, p: loc + 4)
                var m: [Float] = []
                for _ in 0..<12 { if let f = lc.float() { m.append(f) } }
                if m.count == 12 {
                    var t = SCNMatrix4Identity
                    t.m11 = CGFloat(m[0]); t.m12 = CGFloat(m[1]); t.m13 = CGFloat(m[2])
                    t.m21 = CGFloat(m[3]); t.m22 = CGFloat(m[4]); t.m23 = CGFloat(m[5])
                    t.m31 = CGFloat(m[6]); t.m32 = CGFloat(m[7]); t.m33 = CGFloat(m[8])
                    t.m41 = CGFloat(m[9]); t.m42 = CGFloat(m[10]); t.m43 = CGFloat(m[11])
                    part.transform = t
                }
            }
            out.append(part)
        }
        return out
    }

    // MARK: Scène

    static func load(_ url: URL) -> (SCNNode, Int)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), isText([UInt8](data.prefix(16))) else { return nil }
        let list = parts([UInt8](data)).filter { !$0.name.lowercased().hasPrefix("light") && !$0.indices.isEmpty }
        guard !list.isEmpty else { return nil }
        let dir = url.deletingLastPathComponent()
        var cache: [String: CGImage?] = [:]
        func texture(_ name: String, opaque: Bool) -> CGImage? {
            let key = name + (opaque ? "#o" : "")
            if let c = cache[key] { return c }
            var img: CGImage?
            if let u = sibling(dir, name), let src = CGImageSourceCreateWithURL(u as CFURL, nil),
               let raw = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                img = opaque ? dropAlpha(raw) : raw
            }
            cache[key] = img
            return img
        }
        let root = SCNNode()
        var tri = 0
        for p in list {
            guard let g = geometry(p) else { continue }
            let m = SCNMaterial(); m.lightingModel = .blinn; m.isDoubleSided = true
            m.specular.contents = NSColor(white: 0.3, alpha: 1); m.shininess = 0.4
            let lower = p.name.lowercased()
            if !p.uvs.isEmpty, lower.contains("detail"), let t = texture("Details.dds", opaque: false) {
                m.diffuse.contents = t; m.blendMode = .alpha; m.transparencyMode = .aOne; m.writesToDepthBuffer = false
            } else if !p.uvs.isEmpty, lower.hasPrefix("wheel"), let t = texture("Details.dds", opaque: true) {
                m.diffuse.contents = t                                   // jantes et pneus : dans Details.dds
            } else if !p.uvs.isEmpty, let t = texture("Diffuse.dds", opaque: true) {
                m.diffuse.contents = t
            } else {
                m.diffuse.contents = NSColor(white: 0.78, alpha: 1)
            }
            m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
            g.materials = [m]
            let node = SCNNode(geometry: g)
            node.name = p.name
            node.transform = p.transform
            if lower.contains("detail") { node.renderingOrder = 10 }
            root.addChildNode(node)
            tri += p.indices.count / 3
        }
        root.eulerAngles.y = 0.6                                         // voiture vue de trois quarts avant
        return root.childNodes.isEmpty ? nil : (root, tri)
    }

    private static func geometry(_ p: Part) -> SCNGeometry? {
        guard !p.positions.isEmpty, !p.indices.isEmpty else { return nil }
        var sources = [SCNGeometrySource(vertices: p.positions.map { SCNVector3($0.x, $0.y, $0.z) })]
        if p.normals.count == p.positions.count { sources.append(SCNGeometrySource(normals: p.normals.map { SCNVector3($0.x, $0.y, $0.z) })) }
        // v compté depuis le bas dans le fichier (convention OpenGL), depuis le haut dans SceneKit.
        if p.uvs.count == p.positions.count { sources.append(SCNGeometrySource(textureCoordinates: p.uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat(1 - $0.y)) })) }
        let el = SCNGeometryElement(indices: p.indices, primitiveType: .triangles)
        return SCNGeometry(sources: sources, elements: [el])
    }

    private static func sibling(_ dir: URL, _ name: String) -> URL? {
        let direct = dir.appendingPathComponent(name)
        if FileManager.default.isReadableFile(atPath: direct.path) { return direct }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if let f = items.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return dir.appendingPathComponent(f) }
        return nil
    }

    /// La couche alpha des textures de carrosserie sert aux reflets, pas à la transparence.
    private static func dropAlpha(_ img: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    // MARK: Miniature intégrée (GBX binaire)

    /// Miniature JPEG de l'en-tête (« <Thumbnail.jpg> »), enregistrée tête en bas par le jeu.
    static func embeddedThumbnail(_ url: URL) -> NSImage? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 2 * 1024 * 1024), head.prefix(3) == Data("GBX".utf8) else { return nil }
        let b = [UInt8](head)
        guard let tag = head.range(of: Data("<Thumbnail.jpg>".utf8)) else { return nil }
        var s = tag.upperBound
        while s + 1 < b.count, !(b[s] == 0xFF && b[s + 1] == 0xD8) { s += 1; if s > tag.upperBound + 16 { return nil } }
        let endTag = head.range(of: Data("</Thumbnail.jpg>".utf8), in: s..<head.count)?.lowerBound ?? head.count
        guard endTag > s + 4, let src = CGImageSourceCreateWithData(head.subdata(in: s..<endTag) as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(img.height)); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard let flipped = ctx.makeImage() else { return nil }
        return NSImage(cgImage: flipped, size: NSSize(width: img.width, height: img.height))
    }
}
