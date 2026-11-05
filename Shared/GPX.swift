// qLOOKS — traces GPX : carte (MapKit) avec le parcours, statistiques et profil d'altitude, en page HTML locale.
import AppKit
import CoreLocation
import Foundation
import MapKit

enum GPX {
    struct Point { var lat: Double, lon: Double, ele: Double?, time: Date? }
    struct Waypoint { var lat: Double, lon: Double, name: String }
    struct Data {
        var segments: [[Point]] = []
        var waypoints: [Waypoint] = []
        var name: String?
        var tracks = 0, routes = 0
    }

    // MARK: Lecture

    private final class Parser: NSObject, XMLParserDelegate {
        var d = Data()
        private var stack: [String] = []
        private var text = ""
        private var cur: Point?
        private var seg: [Point] = []
        private var wpt: Waypoint?
        private var depthName: String?
        private let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
        private let iso2 = ISO8601DateFormatter()

        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            let name = e.lowercased()
            stack.append(name); text = ""
            switch name {
            case "trk": d.tracks += 1
            case "rte": d.routes += 1; seg = []
            case "trkseg": seg = []
            case "trkpt", "rtept":
                if let la = Double(a["lat"] ?? ""), let lo = Double(a["lon"] ?? "") { cur = Point(lat: la, lon: lo, ele: nil, time: nil) }
            case "wpt":
                if let la = Double(a["lat"] ?? ""), let lo = Double(a["lon"] ?? "") { wpt = Waypoint(lat: la, lon: lo, name: "") }
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            let name = e.lowercased()
            defer { _ = stack.popLast() }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "ele": if cur != nil { cur?.ele = Double(t) }
            case "time": if cur != nil { cur?.time = iso.date(from: t) ?? iso2.date(from: t) }
            case "name":
                let parent = stack.dropLast().last ?? ""
                if parent == "wpt" { wpt?.name = t }
                else if parent == "trk" || parent == "rte" || parent == "metadata", d.name == nil, !t.isEmpty { d.name = t }
            case "trkpt", "rtept": if let c = cur { seg.append(c) }; cur = nil
            case "trkseg", "rte": if seg.count > 1 { d.segments.append(seg) }; seg = []
            case "wpt": if let w = wpt { d.waypoints.append(w) }; wpt = nil
            default: break
            }
        }
    }

    static func parse(_ url: URL) -> Data? {
        guard let x = XMLParser(contentsOf: url) else { return nil }
        let p = Parser(); x.delegate = p
        guard x.parse() || !p.d.segments.isEmpty || !p.d.waypoints.isEmpty else { return nil }
        return p.d
    }

    // MARK: Statistiques

    struct Stats {
        var distance = 0.0, ascent = 0.0, descent = 0.0
        var minEle: Double?, maxEle: Double?
        var start: Date?, end: Date?
        var points = 0
        var profile: [(d: Double, e: Double)] = []
        var movingTime = 0.0
    }

    static func stats(_ d: Data) -> Stats {
        var s = Stats()
        var cum = 0.0
        for seg in d.segments {
            var lastEle: Double?
            for (i, p) in seg.enumerated() {
                s.points += 1
                if i > 0 {
                    let a = CLLocation(latitude: seg[i - 1].lat, longitude: seg[i - 1].lon), b = CLLocation(latitude: p.lat, longitude: p.lon)
                    let dist = b.distance(from: a)
                    cum += dist; s.distance += dist
                    if let t0 = seg[i - 1].time, let t1 = p.time, dist / max(t1.timeIntervalSince(t0), 0.001) > 0.3, t1 > t0 { s.movingTime += t1.timeIntervalSince(t0) }
                }
                if let e = p.ele {
                    s.minEle = min(s.minEle ?? e, e); s.maxEle = max(s.maxEle ?? e, e)
                    if let l = lastEle, abs(e - l) >= 3 { if e > l { s.ascent += e - l } else { s.descent += l - e }; lastEle = e }
                    else if lastEle == nil { lastEle = e }
                    s.profile.append((cum, e))
                }
                if let t = p.time { s.start = min(s.start ?? t, t); s.end = max(s.end ?? t, t) }
            }
        }
        return s
    }

    // MARK: Carte

    private static func mapImage(_ d: Data) async -> NSImage? {
        let pts = d.segments.flatMap { $0 }.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } + d.waypoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        guard let first = pts.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for p in pts { minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude); minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude) }
        let size = CGSize(width: 1400, height: 760)
        let latSpan = max((maxLat - minLat) * 1.3, 0.004), lonSpan = max((maxLon - minLon) * 1.3, 0.004)
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                                        span: MKCoordinateSpan(latitudeDelta: min(latSpan, 170), longitudeDelta: min(lonSpan, 350)))
        let opt = MKMapSnapshotter.Options()
        opt.region = region; opt.size = size
        opt.preferredConfiguration = MKStandardMapConfiguration()
        let snap: MKMapSnapshotter.Snapshot? = await withTaskGroup(of: MKMapSnapshotter.Snapshot?.self) { g in
            g.addTask { try? await MKMapSnapshotter(options: opt).start() }
            g.addTask { try? await Task.sleep(nanoseconds: 9_000_000_000); return nil }
            let r = await g.next() ?? nil
            g.cancelAll()
            return r
        }
        func draw(into ctx: CGContext, point: (CLLocationCoordinate2D) -> CGPoint) {
            ctx.setLineJoin(.round); ctx.setLineCap(.round)
            for seg in d.segments {
                ctx.beginPath()
                for (i, p) in seg.enumerated() {
                    let q = point(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
                    i == 0 ? ctx.move(to: q) : ctx.addLine(to: q)
                }
                ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9)); ctx.setLineWidth(10); ctx.strokePath()
                ctx.beginPath()
                for (i, p) in seg.enumerated() {
                    let q = point(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
                    i == 0 ? ctx.move(to: q) : ctx.addLine(to: q)
                }
                ctx.setStrokeColor(CGColor(red: 0.94, green: 0.35, blue: 0.1, alpha: 1)); ctx.setLineWidth(6); ctx.strokePath()
            }
            func dot(_ c: CLLocationCoordinate2D, _ col: CGColor, _ r: CGFloat) {
                let q = point(c)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: q.x - r - 3, y: q.y - r - 3, width: 2 * r + 6, height: 2 * r + 6))
                ctx.setFillColor(col); ctx.fillEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r))
            }
            for w in d.waypoints { dot(CLLocationCoordinate2D(latitude: w.lat, longitude: w.lon), CGColor(red: 0.1, green: 0.45, blue: 0.95, alpha: 1), 6) }
            if let f = d.segments.first?.first { dot(CLLocationCoordinate2D(latitude: f.lat, longitude: f.lon), CGColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1), 8) }
            if let l = d.segments.last?.last { dot(CLLocationCoordinate2D(latitude: l.lat, longitude: l.lon), CGColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1), 8) }
        }
        let px = size
        guard let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let snap {
            ctx.draw(snap.image.cgImage(forProposedRect: nil, context: nil, hints: nil)!, in: CGRect(origin: .zero, size: px))
            draw(into: ctx) { c in
                let p = snap.point(for: c)
                return CGPoint(x: p.x, y: size.height - p.y)
            }
        } else {
            // Hors ligne : fond uni et parcours à l'échelle.
            ctx.setFillColor(CGColor(gray: 0.16, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: px))
            let cosLat = cos(region.center.latitude * .pi / 180)
            let w = (maxLon - minLon) * cosLat, h = maxLat - minLat
            let k = min(px.width * 0.84 / max(w, 1e-9), px.height * 0.84 / max(h, 1e-9))
            draw(into: ctx) { c in
                CGPoint(x: px.width / 2 + (c.longitude - region.center.longitude) * cosLat * k, y: px.height / 2 + (c.latitude - region.center.latitude) * k)
            }
        }
        guard let img = ctx.makeImage() else { return nil }
        return NSImage(cgImage: img, size: NSSize(width: size.width / 2, height: size.height / 2))
    }

    // MARK: Page

    private static func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }

    private static func duration(_ s: Double) -> String {
        let t = Int(s.rounded()); let h = t / 3600, m = (t % 3600) / 60
        return h > 0 ? "\(h) h \(String(format: "%02d", m))" : "\(m) min"
    }

    private static func profileSVG(_ pr: [(d: Double, e: Double)], total: Double) -> String {
        guard pr.count > 1, total > 0 else { return "" }
        let w = 780.0, h = 140.0
        let lo = pr.map { $0.e }.min()!, hi = pr.map { $0.e }.max()!
        let span = max(hi - lo, 10)
        let step = max(1, pr.count / 400)
        let pts = stride(from: 0, to: pr.count, by: step).map { i -> String in
            String(format: "%.1f,%.1f", pr[i].d / total * w, h - (pr[i].e - lo) / span * (h - 16) - 8)
        }
        let line = pts.joined(separator: " ")
        return "<svg viewBox=\"0 0 \(Int(w)) \(Int(h))\" preserveAspectRatio=\"none\" class=\"prof\"><polygon points=\"0,\(Int(h)) \(line) \(Int(w)),\(Int(h))\" class=\"fill\"/><polyline points=\"\(line)\" class=\"ln\"/></svg>"
    }

    static func html(for url: URL) async -> String? {
        guard let d = parse(url), !d.segments.isEmpty || !d.waypoints.isEmpty else { return nil }
        let s = stats(d)
        var mapURI = ""
        if let img = await mapImage(d), let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
           let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) { mapURI = "data:image/jpeg;base64," + jpg.base64EncodedString() }
        func cell(_ k: String, _ v: String) -> String { "<div class=\"c\"><span>\(esc(k))</span><b>\(esc(v))</b></div>" }
        let km = NumberFormatter(); km.maximumFractionDigits = 1; km.minimumFractionDigits = 1; km.locale = L.locale
        let meters = NumberFormatter(); meters.maximumFractionDigits = 0; meters.locale = L.locale
        var cells = ""
        if s.distance > 0 { cells += cell(L.t("gpx.distance"), (km.string(from: NSNumber(value: s.distance / 1000)) ?? "") + " km") }
        if let a = s.start, let b = s.end, b > a { cells += cell(L.t("gpx.duration"), duration(b.timeIntervalSince(a))) }
        if s.movingTime > 60 { cells += cell(L.t("gpx.moving"), duration(s.movingTime)); cells += cell(L.t("gpx.speed"), (km.string(from: NSNumber(value: s.distance / s.movingTime * 3.6)) ?? "") + " km/h") }
        if s.maxEle != nil { cells += cell(L.t("gpx.ascent"), "+" + (meters.string(from: NSNumber(value: s.ascent)) ?? "") + " m"); cells += cell(L.t("gpx.descent"), "−" + (meters.string(from: NSNumber(value: s.descent)) ?? "") + " m") }
        if let lo = s.minEle, let hi = s.maxEle { cells += cell(L.t("gpx.altitude"), (meters.string(from: NSNumber(value: lo)) ?? "") + " – " + (meters.string(from: NSNumber(value: hi)) ?? "") + " m") }
        if s.points > 0 { cells += cell(L.t("gpx.points"), meters.string(from: NSNumber(value: s.points)) ?? "") }
        if !d.waypoints.isEmpty { cells += cell(L.t("gpx.waypoints"), "\(d.waypoints.count)") }
        if let a = s.start { cells += cell(L.t("gpx.date"), a.formatted(.dateTime.day().month().year().hour().minute().locale(L.locale))) }
        let title = d.name ?? url.deletingPathExtension().lastPathComponent
        let wp = d.waypoints.prefix(40).filter { !$0.name.isEmpty }.map { "<li>\(esc($0.name))</li>" }.joined()
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>
        :root{color-scheme:dark light;--bg:#1e1e1e;--surf:#222;--t:#ddd;--ts:#fff;--tm:#aaa;--bd:#333;--ac:#f0591a}
        @media (prefers-color-scheme:light){:root{--bg:#f2f2f2;--surf:#fff;--t:#222;--ts:#111;--tm:#555;--bd:#d4d4d4}}
        html,body{margin:0;background:var(--bg);color:var(--t);font:13px/1.5 -apple-system,BlinkMacSystemFont,sans-serif}
        .wrap{max-width:840px;margin:0 auto;padding:20px 24px 32px}h1{font-size:20px;margin:0 0 12px;color:var(--ts)}
        .map{width:100%;border-radius:8px;border:1px solid var(--bd);display:block}
        .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:8px;margin:14px 0}
        .c{background:var(--surf);border:1px solid var(--bd);border-radius:6px;padding:8px 12px}.c span{display:block;color:var(--tm);font-size:11px;text-transform:uppercase;letter-spacing:.05em}.c b{font-size:16px;color:var(--ts);font-weight:600}
        h2{font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--tm);margin:18px 0 6px}
        .prof{width:100%;height:140px;background:var(--surf);border:1px solid var(--bd);border-radius:6px}.prof .fill{fill:var(--ac);opacity:.25}.prof .ln{fill:none;stroke:var(--ac);stroke-width:2;vector-effect:non-scaling-stroke}
        ul{columns:2;margin:0;padding-left:18px}
        </style></head><body><div class="wrap"><h1>\(esc(title))</h1>
        \(mapURI.isEmpty ? "" : "<img class=\"map\" src=\"\(mapURI)\" alt=\"\">")
        <div class="grid">\(cells)</div>
        \(profileSVG(s.profile, total: s.distance).isEmpty ? "" : "<h2>\(esc(L.t("gpx.profile")))</h2>" + profileSVG(s.profile, total: s.distance))
        \(wp.isEmpty ? "" : "<h2>\(esc(L.t("gpx.waypoints")))</h2><ul>\(wp)</ul>")
        </div></body></html>
        """
    }
}
