// qLOOKS — lecteurs 3D maison : 3MF, 3DS (Autodesk 3D Studio), LWO / LWS (LightWave).
import AppKit
import Foundation
import SceneKit

private let defaultColor = SIMD4<Float>(0.78, 0.78, 0.78, 1)

// MARK: 3MF

enum ThreeMF {
    private struct Obj { var verts: [SIMD3<Float>] = []; var tris: [(Int, Int, Int, Int?, Int?)] = []; var comps: [(Int, [Float])] = []; var pid: Int?; var pindex: Int? }
    private final class P: NSObject, XMLParserDelegate {
        var objs: [Int: Obj] = [:]
        var build: [(Int, [Float])] = []
        var groups: [Int: [SIMD4<Float>]] = [:]
        var cur: Int?
        var group: Int?
        var inBuild = false
        static func color(_ s: String) -> SIMD4<Float> {
            var h = s.hasPrefix("#") ? String(s.dropFirst()) : s
            if h.count == 6 { h += "FF" }
            guard h.count == 8, let v = UInt32(h, radix: 16) else { return defaultColor }
            return SIMD4(Float(v >> 24) / 255, Float((v >> 16) & 255) / 255, Float((v >> 8) & 255) / 255, Float(v & 255) / 255)
        }
        static func matrix(_ s: String?) -> [Float] { (s ?? "").split(separator: " ").compactMap { Float($0) } }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            let n = e.split(separator: ":").last.map(String.init) ?? e
            switch n {
            case "basematerials", "colorgroup": group = Int(a["id"] ?? ""); if let g = group { groups[g] = [] }
            case "base": if let g = group { groups[g]?.append(Self.color(a["displaycolor"] ?? "")) }
            case "color": if let g = group { groups[g]?.append(Self.color(a["color"] ?? "")) }
            case "object":
                cur = Int(a["id"] ?? ""); if let c = cur { var o = Obj(); o.pid = Int(a["pid"] ?? ""); o.pindex = Int(a["pindex"] ?? ""); objs[c] = o }
            case "vertex": if let c = cur, let x = Float(a["x"] ?? ""), let y = Float(a["y"] ?? ""), let z = Float(a["z"] ?? "") { objs[c]?.verts.append(SIMD3(x, y, z)) }
            case "triangle":
                if let c = cur, let v1 = Int(a["v1"] ?? ""), let v2 = Int(a["v2"] ?? ""), let v3 = Int(a["v3"] ?? "") {
                    objs[c]?.tris.append((v1, v2, v3, Int(a["pid"] ?? ""), Int(a["p1"] ?? "")))
                }
            case "component": if let c = cur, let id = Int(a["objectid"] ?? "") { objs[c]?.comps.append((id, Self.matrix(a["transform"]))) }
            case "build": inBuild = true
            case "item": if inBuild, let id = Int(a["objectid"] ?? "") { build.append((id, Self.matrix(a["transform"]))) }
            default: break
            }
        }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            let n = e.split(separator: ":").last.map(String.init) ?? e
            if n == "object" { cur = nil }
            if n == "basematerials" || n == "colorgroup" { group = nil }
            if n == "build" { inBuild = false }
        }
    }

    private static func apply(_ m: [Float], _ v: SIMD3<Float>) -> SIMD3<Float> {
        guard m.count == 12 else { return v }
        return SIMD3(v.x * m[0] + v.y * m[3] + v.z * m[6] + m[9], v.x * m[1] + v.y * m[4] + v.z * m[7] + m[10], v.x * m[2] + v.y * m[5] + v.z * m[8] + m[11])
    }

    static func load(_ url: URL) -> Mesh? {
        guard let zip = ZipFile(url: url) else { return nil }
        var path = "3D/3dmodel.model"
        if let rels = zip.data("_rels/.rels"), let s = String(data: rels, encoding: .utf8),
           let r = s.range(of: #"Target="([^"]+)"[^>]*3dmodel"#, options: .regularExpression) ?? s.range(of: #"Target="([^"]+3dmodel[^"]*)""#, options: .regularExpression) {
            let frag = String(s[r]); if let a = frag.range(of: "Target=\""), let b = frag[a.upperBound...].firstIndex(of: "\"") { path = String(frag[a.upperBound..<b]).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        }
        guard let data = zip.data(path) ?? zip.entries.keys.first(where: { $0.lowercased().hasSuffix(".model") }).flatMap({ zip.data($0) }) else { return nil }
        let p = P(); let x = XMLParser(data: data); x.delegate = p
        guard x.parse() || !p.objs.isEmpty else { return nil }
        var mesh = Mesh()
        func emit(_ id: Int, _ transforms: [[Float]], depth: Int) {
            guard depth < 8, mesh.triangleCount < 2_500_000, let o = p.objs[id] else { return }
            func tf(_ v: SIMD3<Float>) -> SIMD3<Float> { transforms.reduce(v) { apply($1, $0) } }
            for t in o.tris where t.0 < o.verts.count && t.1 < o.verts.count && t.2 < o.verts.count {
                var c = defaultColor
                let pid = t.3 ?? o.pid, pidx = t.4 ?? o.pindex
                if let pid, let g = p.groups[pid], let i = pidx, i < g.count { c = g[i] }
                mesh.add(tf(o.verts[t.0]), tf(o.verts[t.1]), tf(o.verts[t.2]), color: c)
            }
            for (cid, m) in o.comps { emit(cid, [m] + transforms, depth: depth + 1) }
        }
        let items = p.build.isEmpty ? p.objs.keys.sorted().map { ($0, [Float]()) } : p.build
        for (id, m) in items { emit(id, m.isEmpty ? [] : [m], depth: 0) }
        return mesh.triangleCount > 0 ? mesh : nil
    }
}

// MARK: 3DS

enum ThreeDS {
    static func load(_ url: URL) -> Mesh? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 6 else { return nil }
        let b = [UInt8](d)
        func u16(_ i: Int) -> Int { i + 2 <= b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { i + 4 <= b.count ? Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 : 0 }
        func f32(_ i: Int) -> Float { Float(bitPattern: UInt32(truncatingIfNeeded: u32(i))) }
        guard u16(0) == 0x4D4D else { return nil }
        func cstr(_ i: Int) -> (String, Int) {
            var j = i; while j < b.count, b[j] != 0 { j += 1 }
            return (String(decoding: b[i..<min(j, b.count)], as: UTF8.self), j + 1)
        }
        var materials: [String: SIMD4<Float>] = [:]
        var mesh = Mesh()
        func chunks(_ start: Int, _ end: Int, _ visit: (Int, Int, Int) -> Void) {   // (id, bodyStart, chunkEnd)
            var p = start
            while p + 6 <= end {
                let id = u16(p), len = u32(p + 2)
                guard len >= 6, p + len <= end else { break }
                visit(id, p + 6, p + len); p += len
            }
        }
        func color(_ s: Int, _ e: Int) -> SIMD4<Float>? {
            var out: SIMD4<Float>?
            chunks(s, e) { id, bs, ce in
                if (id == 0x0011 || id == 0x0012), bs + 3 <= b.count { out = SIMD4(Float(b[bs]) / 255, Float(b[bs + 1]) / 255, Float(b[bs + 2]) / 255, 1) }
                if (id == 0x0010 || id == 0x0013), bs + 12 <= b.count { out = SIMD4(f32(bs), f32(bs + 4), f32(bs + 8), 1) }
            }
            return out
        }
        func parseObject(_ s: Int, _ e: Int) {
            chunks(s, e) { id, bs, ce in
                guard id == 0x4100 else { return }
                var verts: [SIMD3<Float>] = []
                var faces: [(Int, Int, Int)] = []
                var faceColor: [Int: SIMD4<Float>] = [:]
                chunks(bs, ce) { id2, b2, e2 in
                    if id2 == 0x4110 {
                        let n = u16(b2)
                        for i in 0..<n where b2 + 2 + i * 12 + 12 <= b.count { verts.append(SIMD3(f32(b2 + 2 + i * 12), f32(b2 + 6 + i * 12), f32(b2 + 10 + i * 12))) }
                    } else if id2 == 0x4120 {
                        let n = u16(b2)
                        for i in 0..<n where b2 + 2 + i * 8 + 6 <= b.count { faces.append((u16(b2 + 2 + i * 8), u16(b2 + 4 + i * 8), u16(b2 + 6 + i * 8))) }
                        chunks(b2 + 2 + n * 8, e2) { id3, b3, e3 in
                            if id3 == 0x4130 {
                                let (name, p) = cstr(b3)
                                let cnt = u16(p)
                                for k in 0..<cnt where p + 2 + k * 2 + 2 <= b.count { faceColor[u16(p + 2 + k * 2)] = materials[name] ?? defaultColor }
                            }
                        }
                    }
                }
                for (i, f) in faces.enumerated() where f.0 < verts.count && f.1 < verts.count && f.2 < verts.count {
                    mesh.add(verts[f.0], verts[f.1], verts[f.2], color: faceColor[i] ?? defaultColor)
                }
            }
        }
        var editor: (Int, Int)?
        chunks(6, min(b.count, u32(2)), { id, bs, ce in if id == 0x3D3D { editor = (bs, ce) } })
        guard let (es, ee) = editor else { return nil }
        chunks(es, ee) { id, bs, ce in                                            // d'abord les matériaux
            if id == 0xAFFF {
                var name = ""; var col: SIMD4<Float>?
                chunks(bs, ce) { id2, b2, e2 in
                    if id2 == 0xA000 { name = cstr(b2).0 }
                    if id2 == 0xA020 { col = color(b2, e2) }
                }
                materials[name] = col ?? defaultColor
            }
        }
        chunks(es, ee) { id, bs, ce in if id == 0x4000 { let (_, p) = cstr(bs); parseObject(p, ce) } }
        return mesh.triangleCount > 0 ? mesh : nil
    }
}

// MARK: LWO

enum LWO {
    static func load(_ url: URL) -> Mesh? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 12 else { return nil }
        return parse([UInt8](d))
    }

    static func parse(_ b: [UInt8]) -> Mesh? {
        func tag(_ i: Int) -> String { i + 4 <= b.count ? String(decoding: b[i..<(i + 4)], as: UTF8.self) : "" }
        func u16(_ i: Int) -> Int { i + 2 <= b.count ? Int(b[i]) << 8 | Int(b[i + 1]) : 0 }
        func u32(_ i: Int) -> Int { i + 4 <= b.count ? Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) : 0 }
        func f32(_ i: Int) -> Float { Float(bitPattern: UInt32(truncatingIfNeeded: u32(i))) }
        guard tag(0) == "FORM" else { return nil }
        let form = tag(8)
        guard form == "LWO2" || form == "LWOB" || form == "LWO3" else { return nil }
        let v2 = form != "LWOB"
        var points: [SIMD3<Float>] = []
        var polys: [(verts: [Int], surf: Int)] = []
        var tags: [String] = []
        var colors: [String: SIMD4<Float>] = [:]
        func cstrPad(_ i: Int) -> (String, Int) {
            var j = i; while j < b.count, b[j] != 0 { j += 1 }
            let s = String(decoding: b[i..<min(j, b.count)], as: UTF8.self)
            var n = j + 1; if (n - i) % 2 == 1 { n += 1 }
            return (s, n)
        }
        func vx(_ i: Int) -> (Int, Int) { b.count > i && b[i] >= 0xFF ? (u32(i) & 0xFFFFFF, i + 4) : (u16(i), i + 2) }
        var p = 12
        while p + 8 <= b.count {
            let t = tag(p), len = u32(p + 4), body = p + 8
            guard body + len <= b.count + 1 else { break }
            switch t {
            case "PNTS": for i in 0..<(len / 12) { points.append(SIMD3(f32(body + i * 12), f32(body + i * 12 + 4), f32(body + i * 12 + 8))) }
            case "TAGS", "SRFS":
                var q = body; while q < body + len { let (s, n) = cstrPad(q); tags.append(s); q = n }
            case "POLS":
                var q = body
                if v2 {
                    let type = tag(q); q += 4
                    while q < body + len {
                        let nv = u16(q) & 0x3FF; q += 2
                        var vs: [Int] = []
                        for _ in 0..<nv { let (v, n) = vx(q); vs.append(v); q = n }
                        if type == "FACE" { polys.append((vs, -1)) }
                    }
                } else {
                    while q + 2 < body + len {
                        let nv = u16(q); q += 2
                        var vs: [Int] = []
                        for _ in 0..<nv { vs.append(u16(q)); q += 2 }
                        var surf = Int(Int16(truncatingIfNeeded: u16(q))); q += 2
                        if surf < 0 {                                              // polygones de détail : on les saute
                            surf = -surf
                            let nd = u16(q); q += 2
                            for _ in 0..<nd { let n2 = u16(q); q += 2 + 2 * n2 + 2 }
                        }
                        polys.append((vs, surf - 1))
                    }
                }
            case "PTAG":
                if tag(body) == "SURF" {
                    var q = body + 4
                    while q < body + len { let (poly, n) = vx(q); let ti = u16(n); q = n + 2; if poly < polys.count { polys[poly].surf = ti } }
                }
            case "SURF":
                if v2 {
                    let (name, n) = cstrPad(body); let (_, n2) = cstrPad(n)
                    var q = n2
                    while q + 6 <= body + len {
                        let st = tag(q), sl = u16(q + 4)
                        if st == "COLR", q + 6 + 12 <= b.count { colors[name] = SIMD4(f32(q + 6), f32(q + 10), f32(q + 14), 1) }
                        q += 6 + sl + (sl % 2)
                    }
                } else {
                    let (name, n) = cstrPad(body)
                    var q = n
                    while q + 4 <= body + len {
                        let st = tag(q), sl = u16(q + 4)
                        if st == "COLR", q + 6 + 3 <= b.count { colors[name] = SIMD4(Float(b[q + 6]) / 255, Float(b[q + 7]) / 255, Float(b[q + 8]) / 255, 1) }
                        q += 6 + sl + (sl % 2)
                    }
                }
            default: break
            }
            p = body + len + (len % 2)
        }
        var mesh = Mesh()
        for poly in polys where poly.verts.count >= 3 {
            var c = defaultColor
            let si = poly.surf
            if si >= 0, si < tags.count, let col = colors[tags[si]] { c = col }
            let v = poly.verts
            guard v.allSatisfy({ $0 < points.count }) else { continue }
            for k in 1..<(v.count - 1) { mesh.add(points[v[0]], points[v[k + 1]], points[v[k]], color: c) }
        }
        return mesh.triangleCount > 0 ? mesh : nil
    }
}

// MARK: LWS

enum LWS {
    /// Scène LightWave : les objets référencés (LWO) qui se trouvent à côté du fichier, avec leur position, rotation et échelle.
    static func load(_ url: URL) -> (SCNNode, Int)? {
        guard let text = try? String(contentsOf: url, encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        let root = SCNNode()
        var tri = 0
        var i = 0
        let dir = url.deletingLastPathComponent()
        func find(_ rel: String) -> URL? {
            let name = (rel.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            let direct = dir.appendingPathComponent(rel.replacingOccurrences(of: "\\", with: "/"))
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
            let flat = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
            if let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                var n = 0
                for case let u as URL in en { n += 1; if n > 3000 { break }; if u.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame { return u } }
            }
            return nil
        }
        while i < lines.count {
            let l = lines[i].trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("LoadObjectLayer") || l.hasPrefix("LoadObject ") {
                let parts = l.split(separator: " ", maxSplits: l.hasPrefix("LoadObjectLayer") ? 2 : 1).map(String.init)
                let rel = parts.last ?? ""
                var chans: [Int: Float] = [:]
                var j = i + 1
                while j < lines.count, !lines[j].hasPrefix("AddNullObject"), !lines[j].hasPrefix("LoadObject"), !lines[j].hasPrefix("AddLight"), !lines[j].hasPrefix("AddCamera") {
                    if lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("Channel "), let ch = Int(lines[j].split(separator: " ").last ?? "") {
                        var k = j + 1
                        while k < min(lines.count, j + 12) {
                            let t = lines[k].trimmingCharacters(in: .whitespaces)
                            if t.hasPrefix("Key ") { let a = t.split(separator: " "); if a.count > 1, let v = Float(a[1]) { chans[ch] = v }; break }
                            k += 1
                        }
                    }
                    j += 1
                }
                if let u = find(rel), let m = LWO.load(u), let n = Model3D.node(from: m) {
                    n.position = SCNVector3(chans[0] ?? 0, chans[1] ?? 0, -(chans[2] ?? 0))
                    n.eulerAngles = SCNVector3((chans[4] ?? 0) * .pi / 180, -(chans[3] ?? 0) * .pi / 180, (chans[5] ?? 0) * .pi / 180)
                    n.scale = SCNVector3(chans[6] ?? 1, chans[7] ?? 1, chans[8] ?? 1)
                    root.addChildNode(n); tri += m.triangleCount
                }
                i = j; continue
            }
            i += 1
        }
        return root.childNodes.isEmpty ? nil : (root, tri)
    }
}

// MARK: STL (binaire et ASCII)

enum STL {
    static func load(_ url: URL) -> Mesh? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 84 else { return nil }
        let b = [UInt8](d)
        let count = Int(b[80]) | Int(b[81]) << 8 | Int(b[82]) << 16 | Int(b[83]) << 24
        var mesh = Mesh()
        if 84 + count * 50 == b.count {
            func f(_ i: Int) -> Float { Float(bitPattern: UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24) }
            mesh.positions.reserveCapacity(count * 3); mesh.colors.reserveCapacity(count * 3)
            for i in 0..<min(count, 3_000_000) {
                let o = 84 + i * 50 + 12
                var c = defaultColor
                let attr = Int(b[o + 36]) | Int(b[o + 37]) << 8
                if attr & 0x8000 != 0 { c = SIMD4(Float(attr & 31) / 31, Float((attr >> 5) & 31) / 31, Float((attr >> 10) & 31) / 31, 1) }   // couleur VisCAM/SolidView
                mesh.add(SIMD3(f(o), f(o + 4), f(o + 8)), SIMD3(f(o + 12), f(o + 16), f(o + 20)), SIMD3(f(o + 24), f(o + 28), f(o + 32)), color: c)
            }
        } else if let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) {
            var v: [SIMD3<Float>] = []
            for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("vertex") else { continue }
                let n = t.split(separator: " ").dropFirst().compactMap { Float($0) }
                if n.count == 3 { v.append(SIMD3(n[0], n[1], n[2])) }
                if v.count == 3 { mesh.add(v[0], v[1], v[2], color: defaultColor); v = [] }
            }
        }
        return mesh.triangleCount > 0 ? mesh : nil
    }
}

// MARK: 3ds Max (.max) : image d'aperçu enregistrée dans le fichier (conteneur OLE, propriété « miniature »)

enum MaxFile {
    static func preview(_ url: URL) -> NSImage? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 1024 else { return nil }
        let b = [UInt8](d)
        func u16(_ i: Int) -> Int { i + 2 <= b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { i + 4 <= b.count ? Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 : 0 }
        guard b.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) else { return nil }
        let ss = 1 << u16(30), mss = 1 << u16(32)
        let miniCutoff = u32(56)
        func sector(_ n: Int) -> ArraySlice<UInt8> { let o = (n + 1) * ss; return o + ss <= b.count ? b[o..<(o + ss)] : [] }
        var fat: [Int] = []
        var difat: [Int] = (0..<109).map { u32(76 + $0 * 4) }
        var nd = u32(68), guardN = 0
        while nd < 0xFFFFFFF0, guardN < 64 { let s = Array(sector(nd)); for i in 0..<(ss / 4 - 1) where i * 4 + 4 <= s.count { difat.append(Int(s[i * 4]) | Int(s[i * 4 + 1]) << 8 | Int(s[i * 4 + 2]) << 16 | Int(s[i * 4 + 3]) << 24) }; nd = s.count == ss ? (Int(s[ss - 4]) | Int(s[ss - 3]) << 8 | Int(s[ss - 2]) << 16 | Int(s[ss - 1]) << 24) : 0xFFFFFFFF; guardN += 1 }
        for s in difat where s < 0xFFFFFFF0 { let a = Array(sector(s)); for i in stride(from: 0, to: a.count - 3, by: 4) { fat.append(Int(a[i]) | Int(a[i + 1]) << 8 | Int(a[i + 2]) << 16 | Int(a[i + 3]) << 24) } }
        func chain(_ start: Int, _ table: [Int]) -> [Int] {
            var out: [Int] = []; var s = start; var n = 0
            while s >= 0, s < 0xFFFFFFF0, s < table.count, n < 1_000_000 { out.append(s); s = table[s]; n += 1 }
            return out
        }
        func readStream(_ start: Int, size: Int, mini: Bool, miniFAT: [Int], miniStream: [UInt8]) -> [UInt8] {
            var out: [UInt8] = []
            if mini {
                for s in chain(start, miniFAT) { let o = s * mss; if o + mss <= miniStream.count { out += miniStream[o..<(o + mss)] } }
            } else {
                for s in chain(start, fat) { out += sector(s) }
            }
            return Array(out.prefix(size))
        }
        var dirBytes: [UInt8] = []
        for s in chain(u32(48), fat) { dirBytes += sector(s) }
        var miniFAT: [Int] = []
        for s in chain(u32(60), fat) { let a = Array(sector(s)); for i in stride(from: 0, to: a.count - 3, by: 4) { miniFAT.append(Int(a[i]) | Int(a[i + 1]) << 8 | Int(a[i + 2]) << 16 | Int(a[i + 3]) << 24) } }
        guard dirBytes.count >= 128 else { return nil }
        let rootStart = Int(dirBytes[116]) | Int(dirBytes[117]) << 8 | Int(dirBytes[118]) << 16 | Int(dirBytes[119]) << 24
        let rootSize = Int(dirBytes[120]) | Int(dirBytes[121]) << 8 | Int(dirBytes[122]) << 16 | Int(dirBytes[123]) << 24
        let miniStream = readStream(rootStart, size: rootSize, mini: false, miniFAT: [], miniStream: [])
        for e in 0..<(dirBytes.count / 128) {
            let o = e * 128
            let nl = Int(dirBytes[o + 64]) | Int(dirBytes[o + 65]) << 8
            guard nl >= 2, nl <= 64 else { continue }
            let units = stride(from: 0, to: nl - 2, by: 2).map { UInt16(dirBytes[o + $0]) | UInt16(dirBytes[o + $0 + 1]) << 8 }
            let name = String(decoding: units, as: UTF16.self)
            guard name.hasSuffix("SummaryInformation"), !name.contains("Document") else { continue }
            let st = Int(dirBytes[o + 116]) | Int(dirBytes[o + 117]) << 8 | Int(dirBytes[o + 118]) << 16 | Int(dirBytes[o + 119]) << 24
            let sz = Int(dirBytes[o + 120]) | Int(dirBytes[o + 121]) << 8 | Int(dirBytes[o + 122]) << 16 | Int(dirBytes[o + 123]) << 24
            let data = readStream(st, size: sz, mini: sz < miniCutoff, miniFAT: miniFAT, miniStream: miniStream)
            if let img = thumbnail(in: data) { return img }
        }
        return nil
    }

    /// Jeu de propriétés OLE : propriété 17 (miniature), type VT_CF.
    private static func thumbnail(in d: [UInt8]) -> NSImage? {
        func u32(_ i: Int) -> Int { i + 4 <= d.count ? Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24 : 0 }
        guard d.count > 48 else { return nil }
        let secOff = u32(44)
        guard secOff + 8 <= d.count else { return nil }
        let n = u32(secOff + 4)
        for i in 0..<min(n, 64) {
            let pid = u32(secOff + 8 + i * 8), off = secOff + u32(secOff + 12 + i * 8)
            guard pid == 17, u32(off) == 0x47 else { continue }
            let cb = u32(off + 4), tag = u32(off + 8)
            var start = off + 12
            if tag == 0xFFFFFFFF { start += 4 }                           // -1 : identifiant de format du presse-papiers
            guard cb > 8, start < d.count else { return nil }
            let body = Array(d[start..<min(d.count, off + 8 + cb)])
            if body.starts(with: [0xFF, 0xD8]) || body.starts(with: [0x89, 0x50]) { return NSImage(data: Data(body)) }
            // Métafichier Windows (format du presse-papiers 3) : l'image est un DIB dans l'enregistrement StretchDIBits (0x0F43).
            if let w = (0..<max(0, body.count - 6)).first(where: { body[$0] == 1 && body[$0 + 1] == 0 && body[$0 + 2] == 9 && body[$0 + 3] == 0 && body[$0 + 4] == 0 && body[$0 + 5] == 3 }) {
                var p = w + 18
                while p + 6 <= body.count {
                    let words = Int(body[p]) | Int(body[p + 1]) << 8 | Int(body[p + 2]) << 16 | Int(body[p + 3]) << 24
                    let fn = Int(body[p + 4]) | Int(body[p + 5]) << 8
                    guard words >= 3, p + words * 2 <= body.count else { break }
                    if fn == 0x0F43, words * 2 > 28 + 40 { return dib(Array(body[(p + 28)..<(p + words * 2)])) }
                    if fn == 0 { break }
                    p += words * 2
                }
            }
            if body.count > 40, u32(start) == 40, let img = dib(body) { return img }
        }
        return nil
    }

    private static func dib(_ body: [UInt8]) -> NSImage? {
        guard body.count > 40 else { return nil }
        let hdr = Int(body[0]) | Int(body[1]) << 8
        let bits = Int(body[14]) | Int(body[15]) << 8
        var used = Int(body[32]) | Int(body[33]) << 8 | Int(body[34]) << 16 | Int(body[35]) << 24
        if used == 0, bits <= 8 { used = 1 << bits }
        var bmp: [UInt8] = [0x42, 0x4D]
        let total = 14 + body.count
        bmp += [UInt8(total & 255), UInt8((total >> 8) & 255), UInt8((total >> 16) & 255), UInt8((total >> 24) & 255), 0, 0, 0, 0]
        let off = 14 + hdr + used * 4
        bmp += [UInt8(off & 255), UInt8((off >> 8) & 255), UInt8((off >> 16) & 255), UInt8((off >> 24) & 255)]
        return NSImage(data: Data(bmp + body))
    }
}
