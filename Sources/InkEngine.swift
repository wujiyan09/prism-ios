import SwiftUI
import UIKit
import PencilKit   // read-only: only to import old PencilKit drawings

// MARK: - Prism Ink: our own stroke model + Core Animation renderer (no PencilKit canvas).
//
// Rendering: every committed stroke is one CAShapeLayer holding a vector outline (filled), so it stays sharp at
// any zoom, erasing = removing a layer, lasso-moving = a layer transform. The in-progress stroke is one more
// shape layer rebuilt per touch frame from coalesced + predicted touches.

enum InkKind: String, Codable, CaseIterable {
    case pen, pencil, marker, monoline, eraser, pixelEraser, lasso, laser
    var isInk: Bool { self == .pen || self == .pencil || self == .marker || self == .monoline }
    var title: String {
        switch self {
        case .pen: return "钢笔"; case .pencil: return "铅笔"; case .marker: return "荧光笔"; case .monoline: return "单线笔"
        case .eraser: return "橡皮擦"; case .pixelEraser: return "像素橡皮擦"; case .lasso: return "套索"; case .laser: return "激光笔"
        }
    }
    var icon: String {
        switch self {
        case .pen: return "pencil.tip"; case .pencil: return "pencil"; case .marker: return "highlighter"; case .monoline: return "line.diagonal"
        case .eraser: return "eraser"; case .pixelEraser: return "eraser.line.dashed"; case .lasso: return "lasso"; case .laser: return "rays"
        }
    }
}

/// The active tool. presetID ties it to a saved pen preset (several presets may share a kind).
struct InkTool: Equatable {
    var kind: InkKind
    var color: UIColor
    var width: CGFloat
    var presetID: UUID? = nil
    static let defaultPen = InkTool(kind: .pen, color: .black, width: 2.5)
}

struct InkPoint {
    var location: CGPoint
    /// 0…1
    var force: CGFloat = 0.5
    var azimuth: CGFloat = 0
    /// 0 flat … π/2 upright
    var altitude: CGFloat = .pi / 2
    var time: TimeInterval = 0
    /// Explicit diameter (imported PencilKit points); 0 = computed from the tool.
    var size: CGFloat = 0
}

struct InkStroke {
    var id = UUID()
    var kind: InkKind
    var color: UIColor
    var width: CGFloat
    var points: [InkPoint]
    var transform: CGAffineTransform = .identity
    /// Opacity override (imported strokes); nil = from the kind.
    var alpha: CGFloat? = nil

    var renderBounds: CGRect {
        guard !points.isEmpty else { return .null }
        var r = CGRect.null
        for p in points { r = r.union(CGRect(origin: p.location, size: .zero)) }
        let m = width * 2 + (points.map(\.size).max() ?? 0)
        return r.insetBy(dx: -m, dy: -m).applying(transform)
    }
    /// Points with the transform applied.
    var placed: [CGPoint] { transform.isIdentity ? points.map(\.location) : points.map { $0.location.applying(transform) } }
    var opacity: CGFloat {
        if let alpha { return alpha }
        switch kind {
        case .pencil:
            let t = points.isEmpty ? 0 : points.map { max(0, 1 - $0.altitude / (.pi / 2)) }.reduce(0, +) / CGFloat(points.count)
            return 0.85 * (1 - 0.4 * t)
        case .marker: return 0.35
        case .laser: return 1
        default: return 1
        }
    }
}

struct InkDrawing {
    var strokes: [InkStroke] = []
    init() {}
    init(strokes: [InkStroke]) { self.strokes = strokes }

    var bounds: CGRect { strokes.reduce(CGRect.null) { $0.union($1.renderBounds) } }

    func transformed(using t: CGAffineTransform) -> InkDrawing {
        var d = self
        for i in d.strokes.indices { d.strokes[i].transform = d.strokes[i].transform.concatenating(t) }
        return d
    }

    // MARK: Storage (own format; PencilKit data is converted read-only)
    private struct F: Codable { var v = 1; var s: [S] }
    private struct S: Codable { var i: String; var k: String; var c: [Float]; var w: Float; var t: [Float]; var a: Float?; var p: [Float] }

    func dataRepresentation() -> Data {
        let ss = strokes.map { s -> S in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            s.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            var p: [Float] = []; p.reserveCapacity(s.points.count * 7)
            for q in s.points { p += [Float(q.location.x), Float(q.location.y), Float(q.force), Float(q.azimuth), Float(q.altitude), Float(q.time), Float(q.size)] }
            let t = s.transform
            return S(i: s.id.uuidString, k: s.kind.rawValue, c: [Float(r), Float(g), Float(b), Float(a)], w: Float(s.width),
                     t: [Float(t.a), Float(t.b), Float(t.c), Float(t.d), Float(t.tx), Float(t.ty)], a: s.alpha.map { Float($0) }, p: p)
        }
        return (try? JSONEncoder().encode(F(s: ss))) ?? Data()
    }

    init(data: Data) throws {
        if data.first == UInt8(ascii: "{") {
            let f = try JSONDecoder().decode(F.self, from: data)
            strokes = f.s.map { s in
                var pts: [InkPoint] = []
                var i = 0
                while i + 6 < s.p.count {
                    pts.append(InkPoint(location: CGPoint(x: CGFloat(s.p[i]), y: CGFloat(s.p[i + 1])), force: CGFloat(s.p[i + 2]),
                                        azimuth: CGFloat(s.p[i + 3]), altitude: CGFloat(s.p[i + 4]), time: TimeInterval(s.p[i + 5]), size: CGFloat(s.p[i + 6])))
                    i += 7
                }
                let c = s.c.count == 4 ? UIColor(red: CGFloat(s.c[0]), green: CGFloat(s.c[1]), blue: CGFloat(s.c[2]), alpha: CGFloat(s.c[3])) : .black
                let t = s.t.count == 6 ? CGAffineTransform(a: CGFloat(s.t[0]), b: CGFloat(s.t[1]), c: CGFloat(s.t[2]), d: CGFloat(s.t[3]), tx: CGFloat(s.t[4]), ty: CGFloat(s.t[5])) : .identity
                return InkStroke(id: UUID(uuidString: s.i) ?? UUID(), kind: InkKind(rawValue: s.k) ?? .pen, color: c, width: CGFloat(s.w),
                                 points: pts, transform: t, alpha: s.a.map { CGFloat($0) })
            }
        } else {
            self = InkDrawing(pk: try PKDrawing(data: data))
        }
    }

    /// Read-only conversion of a PencilKit drawing: exact point sizes/opacity, transform baked in.
    init(pk: PKDrawing) {
        strokes = pk.strokes.map { st in
            let r = st.ink.inkType.rawValue.lowercased()
            let kind: InkKind = r.contains("pencil") ? .pencil : r.contains("marker") ? .marker : r.contains("monoline") ? .monoline : .pen
            let t = st.transform
            let k = sqrt(abs(t.a * t.d - t.b * t.c))
            var pts: [InkPoint] = []
            var op: CGFloat = 0
            for p in st.path.interpolatedPoints(by: .distance(1.5)) {
                pts.append(InkPoint(location: p.location.applying(t), force: min(1, p.force / 4.17), azimuth: p.azimuth, altitude: p.altitude,
                                    time: p.timeOffset, size: max(0.3, p.size.width * k)))
                op += p.opacity
            }
            let w = pts.isEmpty ? 2 : pts.map(\.size).sorted()[pts.count / 2]
            let a = pts.isEmpty ? 1 : op / CGFloat(pts.count)
            return InkStroke(kind: kind, color: st.ink.color, width: w, points: pts,
                             alpha: kind == .marker ? min(0.5, a) : (kind == .pencil ? min(1, max(0.4, a)) : nil))
        }
    }

    /// Flatten to an image (true colours).
    func image(from rect: CGRect, scale: CGFloat) -> UIImage {
        let f = UIGraphicsImageRendererFormat(); f.scale = scale; f.opaque = false
        return UIGraphicsImageRenderer(size: rect.size, format: f).image { ctx in
            let g = ctx.cgContext
            g.translateBy(x: -rect.minX, y: -rect.minY)
            for s in strokes where s.renderBounds.intersects(rect) {
                g.setFillColor(s.color.withAlphaComponent(s.color.cgColor.alpha * s.opacity).cgColor)
                g.addPath(InkGeometry.outline(s)); g.fillPath()
            }
        }
    }
}

// MARK: - Geometry

enum InkGeometry {
    /// Diameter at point i.
    static func size(_ s: InkStroke, _ pts: [CGPoint], _ i: Int, scale k: CGFloat) -> CGFloat {
        let p = s.points[i]
        if p.size > 0 { return p.size * (s.transform.isIdentity ? 1 : k) }
        let w = s.width * k
        let f = min(1, max(0, p.force))
        let tilt = max(0, 1 - p.altitude / (.pi / 2))
        switch s.kind {
        case .pen: return w * (0.45 + 0.9 * f)
        case .pencil: return w * (0.6 + 0.6 * f) * (1 + 1.5 * tilt)
        case .marker:
            guard pts.count > 1 else { return w }
            let a = pts[max(0, i - 1)], b = pts[min(pts.count - 1, i + 1)]
            let dir = atan2(b.y - a.y, b.x - a.x)
            return w * (0.3 + 0.7 * abs(sin(dir - p.azimuth)))
        case .laser: return w
        default: return w
        }
    }

    /// Filled outline: one circle per point + one quad per segment, all wound the same way (nonzero fill = union).
    static func outline(_ s: InkStroke) -> CGPath {
        let path = CGMutablePath()
        let pts = s.placed
        guard !pts.isEmpty else { return path }
        let t = s.transform
        let k = sqrt(abs(t.a * t.d - t.b * t.c))
        var r = [CGFloat](repeating: 0, count: pts.count)
        for i in pts.indices { r[i] = max(0.25, size(s, pts, i, scale: k) / 2) }
        if s.kind == .marker {
            // Highlighter: one continuous stroked outline (no joins/gaps, one even transparency).
            let line = CGMutablePath()
            line.move(to: pts[0])
            if pts.count == 1 { line.addLine(to: CGPoint(x: pts[0].x + 0.1, y: pts[0].y)) } else { line.addLines(between: pts) }
            let w = max(0.5, r.reduce(0, +) / CGFloat(r.count) * 2)
            return line.copy(strokingWithWidth: w, lineCap: .square, lineJoin: .round, miterLimit: 1)
        }
        let caps = s.kind != .marker
        if pts.count == 1 || caps {
            for i in pts.indices where caps || i == 0 { circle(path, pts[i], r[i]) }
        }
        guard pts.count > 1 else { return path }
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            guard len > 0.01 else { continue }
            let nx = -dy / len, ny = dx / len
            var q = [CGPoint(x: a.x + nx * r[i - 1], y: a.y + ny * r[i - 1]), CGPoint(x: b.x + nx * r[i], y: b.y + ny * r[i]),
                     CGPoint(x: b.x - nx * r[i], y: b.y - ny * r[i]), CGPoint(x: a.x - nx * r[i - 1], y: a.y - ny * r[i - 1])]
            if area(q) < 0 { q.reverse() }
            path.addLines(between: q); path.closeSubpath()
        }
        return path
    }
    private static func area(_ q: [CGPoint]) -> CGFloat {
        var s: CGFloat = 0
        for i in q.indices { let a = q[i], b = q[(i + 1) % q.count]; s += a.x * b.y - b.x * a.y }
        return s
    }
    private static func circle(_ p: CGMutablePath, _ c: CGPoint, _ r: CGFloat) {
        // Positive (shoelace) winding, same as the quads.
        p.move(to: CGPoint(x: c.x + r, y: c.y))
        p.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        p.closeSubpath()
    }

    /// Catmull-Rom smoothing of raw touch samples (adds points between samples far apart).
    static func smooth(_ raw: [InkPoint]) -> [InkPoint] {
        guard raw.count > 2 else { return raw }
        var out: [InkPoint] = [raw[0]]
        for i in 0..<(raw.count - 1) {
            let p0 = raw[max(0, i - 1)].location, p1 = raw[i].location, p2 = raw[i + 1].location, p3 = raw[min(raw.count - 1, i + 2)].location
            let n = min(6, Int(hypot(p2.x - p1.x, p2.y - p1.y) / 3))
            if n > 1 {
                for j in 1..<n {
                    let u = CGFloat(j) / CGFloat(n), u2 = u * u, u3 = u2 * u
                    func cr(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                        0.5 * (2 * b + (-a + c) * u + (2 * a - 5 * b + 4 * c - d) * u2 + (-a + 3 * b - 3 * c + d) * u3)
                    }
                    var q = raw[i]
                    q.location = CGPoint(x: cr(p0.x, p1.x, p2.x, p3.x), y: cr(p0.y, p1.y, p2.y, p3.y))
                    q.force = raw[i].force + (raw[i + 1].force - raw[i].force) * u
                    q.altitude = raw[i].altitude + (raw[i + 1].altitude - raw[i].altitude) * u
                    q.size = raw[i].size + (raw[i + 1].size - raw[i].size) * u
                    out.append(q)
                }
            }
            out.append(raw[i + 1])
        }
        return out
    }

    static func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        guard l2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func inside(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        guard poly.count > 2 else { return false }
        var c = false; var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }

    /// Light ink → shown on dark paper: neutral colours flip brightness (black ↔ white), others stay.
    static func display(_ c: UIColor, dark: Bool) -> UIColor {
        guard dark else { return c }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return c }
        if s < 0.25 { return UIColor(hue: h, saturation: s, brightness: 1 - b * 0.9, alpha: a) }
        return UIColor(hue: h, saturation: s, brightness: min(1, b + 0.15), alpha: a)
    }
}

// MARK: - Presets (several presets may share a kind: e.g. monoline red / black / blue)

struct InkPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: InkKind
    var rgba: [Double]
    var width: Double
    var color: UIColor {
        get { rgba.count == 4 ? UIColor(red: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]) : .black }
        set { var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; newValue.getRed(&r, green: &g, blue: &b, alpha: &a); rgba = [r, g, b, a].map { Double($0) } }
    }
    init(kind: InkKind, color: UIColor, width: Double) { self.kind = kind; self.rgba = []; self.width = width; self.color = color }
    var tool: InkTool { InkTool(kind: kind, color: color, width: CGFloat(width), presetID: id) }
}

@Observable
final class InkPresets {
    static let shared = InkPresets()
    var presets: [InkPreset] { didSet { save() } }
    var eraserWidth: Double { didSet { UserDefaults.standard.set(eraserWidth, forKey: "ink.eraserWidth") } }
    private init() {
        if let d = UserDefaults.standard.data(forKey: "ink.presets"), let p = try? JSONDecoder().decode([InkPreset].self, from: d),
           !p.filter({ $0.kind != .pencil }).isEmpty { presets = p.filter { $0.kind != .pencil } }   // pencil removed (Sam, 2026-11-27)
        else {
            presets = [InkPreset(kind: .pen, color: .black, width: 2.5), InkPreset(kind: .pen, color: .systemBlue, width: 2.5),
                       InkPreset(kind: .pen, color: .systemRed, width: 2.5),
                       InkPreset(kind: .marker, color: .systemYellow, width: 16), InkPreset(kind: .monoline, color: .black, width: 2)]
        }
        eraserWidth = UserDefaults.standard.object(forKey: "ink.eraserWidth") as? Double ?? 16
    }
    private func save() { if let d = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(d, forKey: "ink.presets") } }
    func preset(_ id: UUID?) -> InkPreset? { presets.first { $0.id == id } }
}

// MARK: - Tool picker (our own palette; same role as PKToolPicker)

@objc protocol InkToolPickerObserver: AnyObject {
    @objc optional func toolPickerSelectedToolDidChange(_ p: InkToolPicker)
    @objc optional func toolPickerVisibilityDidChange(_ p: InkToolPicker)
}

final class InkToolPicker: NSObject {
    static let all = NSHashTable<InkToolPicker>.weakObjects()
    var selectedTool: InkTool = InkPresets.shared.presets.first?.tool ?? .defaultPen {
        didSet { if selectedTool != oldValue { observers.allObjects.forEach { $0.toolPickerSelectedToolDidChange?(self) }; InkPaletteHost.refresh() } }
    }
    var colorUserInterfaceStyle: UIUserInterfaceStyle = .unspecified
    var overrideUserInterfaceStyle: UIUserInterfaceStyle = .unspecified
    private let observers = NSHashTable<InkToolPickerObserver>.weakObjects()
    let visibleFor = NSHashTable<UIResponder>.weakObjects()
    override init() { super.init(); InkToolPicker.all.add(self) }
    func addObserver(_ o: InkToolPickerObserver) { observers.add(o) }
    func removeObserver(_ o: InkToolPickerObserver) { observers.remove(o) }
    func setVisible(_ v: Bool, forFirstResponder r: UIResponder) {
        if v { visibleFor.add(r) } else { visibleFor.remove(r) }
        InkPaletteHost.refresh()
    }
    var isVisible: Bool { visibleFor.allObjects.contains { $0.isFirstResponder } }
    /// The canvas the palette is acting on.
    var activeCanvas: InkCanvas? { visibleFor.allObjects.first { $0.isFirstResponder } as? InkCanvas }
    func select(_ p: InkPreset) { selectedTool = p.tool }
    func select(kind: InkKind) {
        switch kind {
        case .eraser, .pixelEraser: selectedTool = InkTool(kind: kind, color: .gray, width: CGFloat(InkPresets.shared.eraserWidth))
        case .lasso: selectedTool = InkTool(kind: .lasso, color: .systemBlue, width: 2)
        case .laser: selectedTool = InkTool(kind: .laser, color: .systemRed, width: 6)
        default: if let p = InkPresets.shared.presets.first(where: { $0.kind == kind }) { select(p) }
        }
    }
}

/// One floating palette per window, shown while a canvas with a visible picker is first responder.
/// Drag it anywhere; it snaps to the nearest top/bottom edge and remembers where it was (x as a fraction of the width).
enum InkPaletteHost {
    private static var hosts: [ObjectIdentifier: UIHostingController<InkPalette>] = [:]
    private static var drags: [ObjectIdentifier: PaletteDrag] = [:]
    private static var pending = false
    /// Squeeze / double-tap: show the palette at this window point once.
    static var at: CGPoint?
    static func refresh() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { pending = false; update() }
    }
    static func showAt(_ p: CGPoint, in w: UIWindow) { at = p; update(); if let h = hosts[ObjectIdentifier(w)] { place(h.view, in: w) } }
    static func place(_ v: UIView, in w: UIWindow) {
        let size = v.sizeThatFits(CGSize(width: w.bounds.width - 20, height: 200))
        v.bounds = CGRect(origin: .zero, size: CGSize(width: min(size.width, w.bounds.width - 20), height: size.height))
        let sa = w.safeAreaInsets
        let half = v.bounds.width / 2, hh = v.bounds.height / 2
        if let p = at {
            v.center = CGPoint(x: min(w.bounds.width - half - 10, max(half + 10, p.x)), y: min(w.bounds.height - sa.bottom - hh - 10, max(sa.top + hh + 10, p.y - hh - 30)))
            return
        }
        let fx = UserDefaults.standard.object(forKey: "ink.palette.x") as? Double ?? 0.5
        let bottom = UserDefaults.standard.bool(forKey: "ink.palette.bottom")
        let x = min(w.bounds.width - half - 10, max(half + 10, CGFloat(fx) * w.bounds.width))
        v.center = CGPoint(x: x, y: bottom ? w.bounds.height - sa.bottom - hh - 76 : sa.top + hh + 52)
    }
    static func snap(_ v: UIView, in w: UIWindow) {
        at = nil
        UserDefaults.standard.set(Double(v.center.x / max(1, w.bounds.width)), forKey: "ink.palette.x")
        UserDefaults.standard.set(v.center.y > w.bounds.height / 2, forKey: "ink.palette.bottom")
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) { place(v, in: w) }
    }
    private static func update() {
        var shown = Set<ObjectIdentifier>()
        for p in InkToolPicker.all.allObjects {
            guard let c = p.activeCanvas, let w = c.window else { continue }
            let id = ObjectIdentifier(w)
            guard !shown.contains(id) else { continue }
            shown.insert(id)
            let model = InkPalette(picker: p, canvas: c)
            let h: UIHostingController<InkPalette>
            if let x = hosts[id] { h = x; h.rootView = model } else {
                h = UIHostingController(rootView: model)
                h.view.backgroundColor = .clear
                let d = PaletteDrag(window: w)
                let pan = UIPanGestureRecognizer(target: d, action: #selector(PaletteDrag.pan(_:)))
                h.view.addGestureRecognizer(pan)
                drags[id] = d
                hosts[id] = h
            }
            if h.view.superview !== w { w.addSubview(h.view) }
            w.bringSubviewToFront(h.view)
            if p.overrideUserInterfaceStyle != .unspecified { h.overrideUserInterfaceStyle = p.overrideUserInterfaceStyle }
            if !(drags[id]?.dragging ?? false) { place(h.view, in: w) }
        }
        for (id, h) in hosts where !shown.contains(id) { h.view.removeFromSuperview(); hosts[id] = nil; drags[id] = nil }
    }
}

final class PaletteDrag: NSObject {
    weak var window: UIWindow?
    var dragging = false
    private var start: CGPoint = .zero
    init(window: UIWindow) { self.window = window }
    @objc func pan(_ g: UIPanGestureRecognizer) {
        guard let v = g.view, let w = window else { return }
        switch g.state {
        case .began: dragging = true; start = v.center
        case .changed: let t = g.translation(in: w); v.center = CGPoint(x: start.x + t.x, y: start.y + t.y)
        default: dragging = false; InkPaletteHost.snap(v, in: w)
        }
    }
}

struct InkPalette: View {
    let picker: InkToolPicker
    weak var canvas: InkCanvas?
    @State private var presets = InkPresets.shared
    @State private var editing = false
    @State private var tick = 0

    var body: some View {
        let t = picker.selectedTool
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
            Button { canvas?.undo() } label: { Image(systemName: "arrow.uturn.backward") }.keyboardShortcut("z", modifiers: .command)
            Button { canvas?.redo() } label: { Image(systemName: "arrow.uturn.forward") }.keyboardShortcut("z", modifiers: [.command, .shift])
            Divider().frame(height: 32)
            ForEach(presets.presets) { p in
                Button { picker.select(p) } label: {
                    ZStack {
                        Circle().fill(Color(p.color)).frame(width: 34, height: 34)
                        Image(systemName: p.kind.icon).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).shadow(radius: 1)
                    }
                    .padding(3)
                    .overlay(Circle().stroke(t.presetID == p.id ? Color.accentColor : .clear, lineWidth: 2))
                }
                .contextMenu { Button("编辑笔", systemImage: "slider.horizontal.3") { editing = true } }
                .accessibilityLabel("\(p.kind.title)")
            }
            Divider().frame(height: 32)
            tool(.eraser); tool(.pixelEraser); tool(.lasso); tool(.laser)
            Button { editing = true } label: { Image(systemName: "slider.horizontal.3") }
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).frame(minHeight: 60)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .sheet(isPresented: $editing) { InkPresetEditor(picker: picker) }
    }
    private func tool(_ k: InkKind) -> some View {
        Button { picker.select(kind: k) } label: {
            Image(systemName: k.icon).font(.title3).frame(width: 40, height: 40)
                .background(picker.selectedTool.kind == k ? Color.accentColor.opacity(0.25) : .clear, in: Circle())
        }.accessibilityLabel(k.title)
    }
}

/// Add / remove / reorder / edit saved pens. Persisted.
struct InkPresetEditor: View {
    let picker: InkToolPicker
    @State private var presets = InkPresets.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("笔（可以有多支同类笔，不同颜色/粗细）") {
                    ForEach($presets.presets) { $p in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Picker("类型", selection: $p.kind) {
                                    ForEach([InkKind.pen, .marker, .monoline], id: \.self) { k in Label(k.title, systemImage: k.icon).tag(k) }
                                }
                                ColorPicker("", selection: Binding(get: { Color(p.color) }, set: { p.color = UIColor($0) })).labelsHidden()
                            }
                            HStack {
                                Text("粗细 \(String(format: "%.1f", p.width))").font(.caption.monospacedDigit()).frame(width: 70, alignment: .leading)
                                Slider(value: $p.width, in: p.kind == .marker ? 4...40 : 0.5...20)
                            }
                        }
                        .onChange(of: p) { _, n in if picker.selectedTool.presetID == n.id { picker.select(n) } }
                    }
                    .onDelete { presets.presets.remove(atOffsets: $0) }
                    .onMove { presets.presets.move(fromOffsets: $0, toOffset: $1) }
                    Button("添加一支笔", systemImage: "plus") {
                        let base = presets.presets.last ?? InkPreset(kind: .pen, color: .black, width: 2.5)
                        presets.presets.append(InkPreset(kind: base.kind, color: base.color, width: base.width))
                    }
                }
                Section("橡皮擦") {
                    HStack { Text("大小 \(Int(presets.eraserWidth))").font(.caption.monospacedDigit()); Slider(value: $presets.eraserWidth, in: 4...80) }
                }
            }
            .navigationTitle("笔").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { EditButton() }; ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - Canvas

enum InkDrawingPolicy { case `default`, pencilOnly, anyInput }

@objc protocol InkCanvasDelegate: UIScrollViewDelegate {
    @objc optional func canvasViewDrawingDidChange(_ c: InkCanvas)
    @objc optional func canvasViewDidBeginUsingTool(_ c: InkCanvas)
    @objc optional func canvasViewDidEndUsingTool(_ c: InkCanvas)
}

/// Forwards scroll-view callbacks to the outside delegate; supplies the zoom view unless the outside one does.
private final class InkProxy: NSObject, UIScrollViewDelegate {
    weak var outer: UIScrollViewDelegate?
    weak var canvas: InkCanvas?
    override func responds(to s: Selector!) -> Bool { super.responds(to: s) || (outer?.responds(to: s) ?? false) }
    override func forwardingTarget(for s: Selector!) -> Any? { outer?.responds(to: s) == true ? outer : nil }
    func viewForZooming(in s: UIScrollView) -> UIView? {
        if let o = outer, o.responds(to: #selector(UIScrollViewDelegate.viewForZooming(in:))) { return o.viewForZooming?(in: s) }
        return canvas?.inkView
    }
    func scrollViewDidZoom(_ s: UIScrollView) { canvas?.didZoom(); outer?.scrollViewDidZoom?(s) }
}

final class InkDrawGesture: UIGestureRecognizer {
    weak var canvas: InkCanvas?
    private(set) var touch: UITouch?
    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent) {
        guard touch == nil, let x = t.first, let c = canvas, c.accepts(x) else { t.forEach { ignore($0, for: e) }; if touch == nil { state = .failed }; return }
        touch = x
        c.inputBegan(x, e)
        state = .began
    }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent) {
        guard let x = touch, t.contains(x) else { return }
        canvas?.inputMoved(x, e); state = .changed
    }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent) {
        guard let x = touch, t.contains(x) else { return }
        canvas?.inputEnded(x, e, cancelled: false); touch = nil; state = .ended
    }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent) {
        guard let x = touch, t.contains(x) else { return }
        canvas?.inputEnded(x, e, cancelled: true); touch = nil; state = .cancelled
    }
    override func reset() { touch = nil }
}

class InkCanvas: UIScrollView, InkToolPickerObserver, UIEditMenuInteractionDelegate, UIPencilInteractionDelegate {
    // MARK: Hover preview (this screen): a dot the size of the stroke at touchdown, grows with height.
    private let hoverLayer = CAShapeLayer()
    private var liftedAt: CFTimeInterval = 0
    private var lastHover: CGPoint?
    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        switch g.state {
        case .began, .changed:
            let p = g.location(in: inkView)
            lastHover = g.location(in: self)
            guard drawingGestureRecognizer.touch == nil, CACurrentMediaTime() - liftedAt > 0.28, tool.kind != .lasso else { hoverLayer.path = nil; return }
            let z = g.zOffset
            let eraser = tool.kind == .eraser || tool.kind == .pixelEraser
            let base: CGFloat
            switch tool.kind {
            case .pen: base = tool.width * 0.9
            case .marker: base = tool.width * 0.65
            default: base = tool.width
            }
            let d = max(eraser ? 6 : 2, eraser ? tool.width : base * (1 + 1.5 * z))
            hoverLayer.path = UIBezierPath(ovalIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)).cgPath
            if eraser {
                hoverLayer.fillColor = UIColor.white.withAlphaComponent(0.25).cgColor
                hoverLayer.strokeColor = UIColor.systemGray.cgColor; hoverLayer.lineWidth = 1.5 / max(zoomScale, 0.01)
            } else {
                hoverLayer.fillColor = InkGeometry.display(tool.color, dark: dark).withAlphaComponent(tool.kind == .marker ? 0.35 : 0.55).cgColor
                hoverLayer.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor; hoverLayer.lineWidth = 1 / max(zoomScale, 0.01)
            }
        default: hoverLayer.path = nil
        }
    }

    // MARK: Apple Pencil double-tap / squeeze (system preference decides what they do)
    private var previousTool: InkTool?
    private func perform(_ a: UIPencilPreferredAction, at p: CGPoint?) {
        switch a {
        case .ignore: return
        case .switchEraser:
            if tool.kind == .eraser || tool.kind == .pixelEraser { setTool(previousTool ?? .defaultPen) }
            else { let t = InkToolPicker(); t.select(kind: .eraser); setTool(t.selectedTool) }
        case .switchPrevious: if let pt = previousTool { setTool(pt) }
        case .showColorPalette: showPaletteAt(p)
        default:
            if #available(iOS 17.5, *), a == .runSystemShortcut { return }
            showPaletteAt(p)
        }
    }
    private func setTool(_ t: InkTool) {
        if let p = InkToolPicker.all.allObjects.first(where: { $0.visibleFor.contains(self) }) { p.selectedTool = t } else { tool = t }
    }
    private func showPaletteAt(_ p: CGPoint?) {
        guard let w = window else { return }
        if let pk = InkToolPicker.all.allObjects.first(where: { $0.visibleFor.contains(self) }), !pk.isVisible {
            pk.setVisible(true, forFirstResponder: self); _ = becomeFirstResponder()
        }
        let q = p ?? lastHover ?? CGPoint(x: bounds.midX, y: bounds.midY)
        InkPaletteHost.showAt(convert(q, to: w), in: w)
    }
    func pencilInteractionDidTap(_ i: UIPencilInteraction) { perform(UIPencilInteraction.preferredTapAction, at: nil) }
    @available(iOS 17.5, *)
    func pencilInteraction(_ i: UIPencilInteraction, didReceiveTap t: UIPencilInteraction.Tap) {
        perform(UIPencilInteraction.preferredTapAction, at: t.hoverPose?.location)
    }
    @available(iOS 17.5, *)
    func pencilInteraction(_ i: UIPencilInteraction, didReceiveSqueeze s: UIPencilInteraction.Squeeze) {
        guard s.phase == .ended else { return }
        perform(UIPencilInteraction.preferredSqueezeAction, at: s.hoverPose?.location)
    }

    let inkView = UIView()
    private let strokeHost = CALayer()
    private let activeLayer = CAShapeLayer()
    private let remoteLayer = CAShapeLayer()
    private let lassoLayer = CAShapeLayer()
    private let laserLayer = CAShapeLayer()
    private let remoteLaserLayer = CAShapeLayer()
    private var layers: [UUID: (layer: CAShapeLayer, t: CGAffineTransform)] = [:]
    private let proxy = InkProxy()
    private var applyingDrawing = false

    let drawingGestureRecognizer = InkDrawGesture()
    var drawingPolicy: InkDrawingPolicy = .default { didSet { updatePolicy() } }
    var tool: InkTool = .defaultPen { didSet { if tool.kind != .lasso { clearSelection() }; if oldValue != tool { previousTool = oldValue } } }
    /// Live hooks for the two-window mirror: the in-progress stroke every frame, and drawing edits mid-gesture.
    var onActive: ((InkStroke?) -> Void)?
    var onLiveDrawing: ((InkDrawing) -> Void)?
    /// Another window's in-progress stroke, drawn exactly like ours.
    var remoteActive: InkStroke? { didSet { renderRemote() } }

    var drawing = InkDrawing() { didSet { if !applyingDrawing { sync() } } }

    override var delegate: UIScrollViewDelegate? {
        get { proxy.outer }
        set { proxy.outer = newValue; super.delegate = nil; super.delegate = proxy }
    }
    private var inkDelegate: InkCanvasDelegate? { proxy.outer as? InkCanvasDelegate }

    override init(frame: CGRect) { super.init(frame: frame); setUp() }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { super.init(coder: coder); setUp() }

    private func setUp() {
        proxy.canvas = self
        super.delegate = proxy
        inkView.layer.anchorPoint = .zero
        inkView.layer.position = .zero
        inkView.isUserInteractionEnabled = false
        inkView.backgroundColor = .clear
        addSubview(inkView)
        inkView.layer.addSublayer(strokeHost)
        for l in [activeLayer, remoteLayer, laserLayer, remoteLaserLayer] { l.fillRule = .nonZero; inkView.layer.addSublayer(l) }
        lassoLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        lassoLayer.strokeColor = UIColor.systemBlue.cgColor
        lassoLayer.lineDashPattern = [6, 5]
        inkView.layer.addSublayer(lassoLayer)
        for l in [laserLayer, remoteLaserLayer] {
            l.shadowColor = UIColor.systemRed.cgColor; l.shadowRadius = 6; l.shadowOpacity = 0.9; l.shadowOffset = .zero
        }
        drawingGestureRecognizer.canvas = self
        drawingGestureRecognizer.cancelsTouchesInView = false
        drawingGestureRecognizer.delaysTouchesBegan = false
        addGestureRecognizer(drawingGestureRecognizer)
        addInteraction(menu)
        let pi = UIPencilInteraction(); pi.delegate = self; addInteraction(pi)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        hoverLayer.zPosition = 50
        inkView.layer.addSublayer(hoverLayer)
        minimumZoomScale = 1; maximumZoomScale = 1
        updatePolicy()
    }

    private func updatePolicy() {
        let pencilOnly: Bool
        switch drawingPolicy {
        case .pencilOnly: pencilOnly = true
        case .anyInput: pencilOnly = false
        case .default: pencilOnly = UIPencilInteraction.prefersPencilOnlyDrawing
        }
        drawingGestureRecognizer.allowedTouchTypes = pencilOnly ? [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            : [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
        panGestureRecognizer.minimumNumberOfTouches = pencilOnly ? 1 : 2
        panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
    }
    func accepts(_ t: UITouch) -> Bool { isUserInteractionEnabled }

    override func traitCollectionDidChange(_ p: UITraitCollection?) {
        super.traitCollectionDidChange(p)
        if p?.userInterfaceStyle != traitCollection.userInterfaceStyle { layers.values.forEach { $0.layer.removeFromSuperlayer() }; layers = [:]; sync() }
    }
    private var dark: Bool { traitCollection.userInterfaceStyle == .dark }

    // MARK: Layout / zoom
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isZooming, !isZoomBouncing else { return }
        applyScale()
        let z = max(zoomScale, 0.0001)
        if proxy.outer?.responds(to: #selector(UIScrollViewDelegate.viewForZooming(in:))) == true { return }
        let w = max(1, contentSize.width / z), h = max(1, contentSize.height / z)
        if abs(inkView.bounds.width - w) > 0.5 || abs(inkView.bounds.height - h) > 0.5 {
            let cs = contentSize
            inkView.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            inkView.layer.position = .zero
            if contentSize != cs { contentSize = cs }
        }
    }
    func didZoom() { inkView.layer.position = .zero }
    /// Extra magnification from outside (page scaled inside another zooming view).
    var extraScale: CGFloat = 1 { didSet { if abs(extraScale - oldValue) > 0.01 { applyScale() } } }
    private var renderScale: CGFloat { min(12, (window?.screen.scale ?? UIScreen.main.scale) * max(1, zoomScale) * max(1, extraScale)) }
    private var appliedScale: CGFloat = 0
    private func applyScale() {
        let s = renderScale
        guard abs(s - appliedScale) > 0.01 else { return }
        appliedScale = s
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in (strokeHost.sublayers ?? []) + [activeLayer, remoteLayer, lassoLayer, laserLayer, remoteLaserLayer] { l.contentsScale = s }
        CATransaction.commit()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); applyScale() }

    // MARK: Rendering
    private var syncGen = 0
    private func sync() {
        syncGen += 1
        // A page coming on screen with lots of ink: build the stroke outlines off the main thread (CGPath is
        // immutable once built), then attach the layers in one go. Keeps page turns from stalling on outline maths.
        let fresh = drawing.strokes.filter { layers[$0.id] == nil }
        if fresh.count > 40 {
            let gen = syncGen, d = drawing
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var paths: [UUID: CGPath] = [:]
                for s in fresh { paths[s.id] = InkGeometry.outline(s) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.syncGen == gen else { return }
                    self.sync(d, pre: paths)
                }
            }
            return
        }
        sync(drawing, pre: [:])
    }
    private func sync(_ drawing: InkDrawing, pre: [UUID: CGPath]) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var seen = Set<UUID>()
        for s in drawing.strokes {
            seen.insert(s.id)
            if let e = layers[s.id] {
                if e.t != s.transform { e.layer.path = InkGeometry.outline(s); layers[s.id] = (e.layer, s.transform) }
                continue
            }
            let l = CAShapeLayer()
            l.fillRule = .nonZero
            style(l, s)
            l.path = pre[s.id] ?? InkGeometry.outline(s)
            l.contentsScale = renderScale
            strokeHost.addSublayer(l)
            layers[s.id] = (l, s.transform)
        }
        for (id, e) in layers where !seen.contains(id) { e.layer.removeFromSuperlayer(); layers[id] = nil }
        // Keep z-order = stroke order.
        let order = drawing.strokes.compactMap { layers[$0.id]?.layer }
        if strokeHost.sublayers?.count != order.count || zip(strokeHost.sublayers ?? [], order).contains(where: { $0 !== $1 }) {
            strokeHost.sublayers = order
        }
        CATransaction.commit()
    }
    private func style(_ l: CAShapeLayer, _ s: InkStroke) {
        l.fillColor = InkGeometry.display(s.color, dark: dark).cgColor
        l.opacity = Float(s.opacity)
    }
    private func draw(_ s: InkStroke?, in l: CAShapeLayer) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard var s, !s.points.isEmpty else { l.path = nil; return }
        if s.kind == .laser {
            let now = CACurrentMediaTime()
            s.points = s.points.filter { now - $0.time < InkCanvas.laserLife }
            l.fillColor = UIColor.systemRed.cgColor; l.opacity = 0.9
            l.path = s.points.isEmpty ? nil : InkGeometry.outline(s)
            return
        }
        guard s.kind.isInk else { l.path = nil; return }
        style(l, s)
        l.path = InkGeometry.outline(s)
    }
    private func renderRemote() {
        if remoteActive?.kind == .laser { draw(remoteActive, in: remoteLaserLayer); remoteLayer.path = nil; startLaserClock() }
        else { draw(remoteActive, in: remoteLayer); if remoteActive != nil { remoteLaserLayer.path = nil } }
    }

    // MARK: Laser (never saved; trail fades)
    static let laserLife: TimeInterval = 0.7
    private var laser: InkStroke?
    private var clock: CADisplayLink?
    private func startLaserClock() {
        guard clock == nil else { return }
        let d = CADisplayLink(target: self, selector: #selector(laserTick))
        d.add(to: .main, forMode: .common); clock = d
    }
    @objc private func laserTick() {
        draw(laser, in: laserLayer)
        if remoteActive?.kind == .laser { draw(remoteActive, in: remoteLaserLayer) }
        let now = CACurrentMediaTime()
        let alive = (laser?.points.last.map { now - $0.time < InkCanvas.laserLife } ?? false)
            || (remoteActive?.kind == .laser && (remoteActive?.points.last.map { now - $0.time < InkCanvas.laserLife } ?? false))
        if !alive { clock?.invalidate(); clock = nil; laserLayer.path = nil; remoteLaserLayer.path = nil; if laserDone { laser = nil } }
    }
    private var laserDone = false

    // MARK: Input
    private var raw: [InkPoint] = []
    private var before: InkDrawing?
    private var lassoPoly: [CGPoint] = []
    private var selection: Set<UUID> = []
    private var selPoly: [CGPoint] = []
    private var dragFrom: CGPoint?
    private var dragBase: InkDrawing?
    private var downAt: CGPoint = .zero

    private func point(_ t: UITouch) -> InkPoint {
        let isPencil = t.type == .pencil
        let f: CGFloat = isPencil && t.maximumPossibleForce > 0 ? t.force / t.maximumPossibleForce : 0.5
        return InkPoint(location: t.preciseLocation(in: inkView), force: f, azimuth: isPencil ? t.azimuthAngle(in: inkView) : 0,
                        altitude: isPencil ? t.altitudeAngle : .pi / 2, time: t.timestamp)
    }
    private func samples(_ t: UITouch, _ e: UIEvent) -> [InkPoint] { (e.coalescedTouches(for: t) ?? [t]).map(point) }
    private func predicted(_ t: UITouch, _ e: UIEvent) -> [InkPoint] { (e.predictedTouches(for: t) ?? []).map(point) }
    /// Laser points use the media clock so both windows fade them the same way.
    private func laserPoints(_ ps: [InkPoint]) -> [InkPoint] { let now = CACurrentMediaTime(); return ps.map { var q = $0; q.time = now; return q } }

    func inputBegan(_ t: UITouch, _ e: UIEvent) {
        CATransaction.begin(); CATransaction.setDisableActions(true); hoverLayer.path = nil; CATransaction.commit()
        raw = samples(t, e)
        downAt = raw.first?.location ?? .zero
        before = drawing
        inkDelegate?.canvasViewDidBeginUsingTool?(self)
        switch tool.kind {
        case .lasso:
            if !selection.isEmpty, InkGeometry.inside(downAt, selPoly) { dragFrom = downAt; dragBase = drawing }
            else { clearSelection(); lassoPoly = raw.map(\.location); drawLasso(lassoPoly) }
        case .eraser, .pixelEraser: erase(raw.map(\.location))
        case .laser:
            laserDone = false
            laser = InkStroke(kind: .laser, color: .systemRed, width: tool.width, points: laserPoints(raw))
            startLaserClock(); onActive?(laser)
        default: renderActive(t, e)
        }
    }
    func inputMoved(_ t: UITouch, _ e: UIEvent) {
        let new = samples(t, e)
        raw += new
        switch tool.kind {
        case .lasso:
            if let from = dragFrom, let base = dragBase, let p = raw.last?.location { moveSelection(base, dx: p.x - from.x, dy: p.y - from.y, live: true) }
            else { lassoPoly += new.map(\.location); drawLasso(lassoPoly) }
        case .eraser, .pixelEraser: erase(new.map(\.location))
        case .laser:
            laser?.points += laserPoints(new)
            if let l = laser { var shown = l; shown.points += laserPoints(predicted(t, e)); onActive?(shown) }
        default: renderActive(t, e)
        }
    }
    func inputEnded(_ t: UITouch, _ e: UIEvent, cancelled: Bool) {
        liftedAt = CACurrentMediaTime()
        defer { raw = []; inkDelegate?.canvasViewDidEndUsingTool?(self) }
        switch tool.kind {
        case .lasso:
            if let base = dragBase {
                let moved = hypot((raw.last?.location.x ?? 0) - downAt.x, (raw.last?.location.y ?? 0) - downAt.y) > 3
                if moved, !cancelled, let from = dragFrom, let p = raw.last?.location {
                    moveSelection(base, dx: p.x - from.x, dy: p.y - from.y, live: false)
                    selPoly = selPoly.map { CGPoint(x: $0.x + p.x - from.x, y: $0.y + p.y - from.y) }
                    drawLasso(selPoly, closed: true)
                    commit(from: base)
                } else if !moved { showMenu(at: downAt) }
                dragFrom = nil; dragBase = nil
                return
            }
            if cancelled || lassoPoly.count < 3 {
                clearSelection()
                if !cancelled, clipboard != nil { showMenu(at: downAt) }
                return
            }
            select(lassoPoly)
        case .eraser, .pixelEraser:
            if let b = before, cancelled { setDrawingLive(b) } else if let b = before { commit(from: b) }
        case .laser:
            laserDone = true
            onActive?(nil)
        default:
            activeLayer.path = nil
            onActive?(nil)
            guard !cancelled, !raw.isEmpty else { return }
            let s = InkStroke(kind: tool.kind, color: tool.color, width: tool.width, points: InkGeometry.smooth(raw))
            let b = drawing
            var d = drawing; d.strokes.append(s)
            drawing = d
            commit(from: b)
        }
    }
    private func renderActive(_ t: UITouch, _ e: UIEvent) {
        let s = InkStroke(kind: tool.kind, color: tool.color, width: tool.width, points: InkGeometry.smooth(raw + predicted(t, e)))
        draw(s, in: activeLayer)
        onActive?(s)
    }

    /// Notify + undo after a finished edit.
    private func commit(from b: InkDrawing) {
        registerUndo(b)
        inkDelegate?.canvasViewDrawingDidChange?(self)
    }
    private func setDrawingLive(_ d: InkDrawing) {
        drawing = d
        onLiveDrawing?(d)
    }

    // MARK: Erase
    private func erase(_ ps: [CGPoint]) {
        guard !ps.isEmpty else { return }
        let r = max(2, tool.width / 2)
        var d = drawing
        var changed = false
        if tool.kind == .eraser {
            d.strokes.removeAll { s in
                guard s.renderBounds.insetBy(dx: -r, dy: -r).intersects(box(ps, r)) else { return false }
                let pts = s.placed
                let hit = ps.contains { p in
                    if pts.count == 1 { return hypot(p.x - pts[0].x, p.y - pts[0].y) <= r + s.width / 2 }
                    for i in 1..<max(1, pts.count) where InkGeometry.distToSegment(p, pts[i - 1], pts[i]) <= r + s.width / 2 { return true }
                    return false
                }
                if hit { changed = true }
                return hit
            }
        } else {
            var out: [InkStroke] = []
            for s in d.strokes {
                guard s.kind.isInk, s.renderBounds.insetBy(dx: -r, dy: -r).intersects(box(ps, r)) else { out.append(s); continue }
                let pts = s.placed
                let gone = pts.map { q in ps.contains { hypot($0.x - q.x, $0.y - q.y) <= r } }
                guard gone.contains(true) else { out.append(s); continue }
                changed = true
                var run: [InkPoint] = []
                func flush() {
                    if run.count > 1 { var n = s; n.id = UUID(); n.points = run; n.transform = .identity; if s.transform != .identity { n.width = s.width * sqrt(abs(s.transform.a * s.transform.d - s.transform.b * s.transform.c)) }; out.append(n) }
                    run = []
                }
                let k = sqrt(abs(s.transform.a * s.transform.d - s.transform.b * s.transform.c))
                for (i, p) in s.points.enumerated() {
                    if gone[i] { flush() } else { var q = p; q.location = pts[i]; if q.size > 0 { q.size *= k }; run.append(q) }
                }
                flush()
            }
            d.strokes = out
        }
        if changed { setDrawingLive(d) }
    }
    private func box(_ ps: [CGPoint], _ r: CGFloat) -> CGRect {
        ps.reduce(CGRect.null) { $0.union(CGRect(x: $1.x - r, y: $1.y - r, width: r * 2, height: r * 2)) }
    }

    // MARK: Lasso
    private func drawLasso(_ poly: [CGPoint], closed: Bool = false) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let p = CGMutablePath()
        if let f = poly.first { p.move(to: f); p.addLines(between: poly); if closed { p.closeSubpath() } }
        lassoLayer.path = poly.isEmpty ? nil : p
        lassoLayer.lineWidth = 1.5 / max(zoomScale, 0.01)
        CATransaction.commit()
    }
    private func select(_ poly: [CGPoint]) {
        selection = []
        for s in drawing.strokes {
            let pts = s.placed
            guard !pts.isEmpty else { continue }
            let n = pts.filter { InkGeometry.inside($0, poly) }.count
            if n * 2 >= pts.count { selection.insert(s.id) }
        }
        if selection.isEmpty { clearSelection(); return }
        selPoly = poly
        drawLasso(poly, closed: true)
        showMenu(at: poly.last ?? downAt)
    }
    func clearSelection() { selection = []; selPoly = []; lassoPoly = []; drawLasso([]) }
    private func moveSelection(_ base: InkDrawing, dx: CGFloat, dy: CGFloat, live: Bool) {
        var d = base
        let t = CGAffineTransform(translationX: dx, y: dy)
        for i in d.strokes.indices where selection.contains(d.strokes[i].id) { d.strokes[i].transform = d.strokes[i].transform.concatenating(t) }
        drawLasso(selPoly.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }, closed: true)
        if live { setDrawingLive(d) } else { drawing = d }
    }

    // Menu: 拷贝 / 删除 (+ 粘贴 when something was copied)
    private lazy var menu = UIEditMenuInteraction(delegate: self)
    private static var clip: (strokes: [InkStroke], origin: CGPoint)?
    private var clipboard: (strokes: [InkStroke], origin: CGPoint)? { InkCanvas.clip }
    private var menuAt: CGPoint = .zero
    private func showMenu(at p: CGPoint) {
        menuAt = p
        let v = CGPoint(x: p.x * zoomScale, y: p.y * zoomScale)
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: v))
    }
    func editMenuInteraction(_ i: UIEditMenuInteraction, menuFor c: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        var a: [UIAction] = []
        if !selection.isEmpty {
            a.append(UIAction(title: "拷贝", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copySelection() })
            a.append(UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteSelection() })
        } else if clipboard != nil {
            a.append(UIAction(title: "粘贴", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.paste() })
        }
        return a.isEmpty ? nil : UIMenu(children: a)
    }
    func copySelection() {
        let ss = drawing.strokes.filter { selection.contains($0.id) }
        guard !ss.isEmpty else { return }
        let b = ss.reduce(CGRect.null) { $0.union($1.renderBounds) }
        InkCanvas.clip = (ss, b.origin)
        UIPasteboard.general.image = InkDrawing(strokes: ss).image(from: b, scale: 2)
    }
    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let b = drawing
        var d = drawing; d.strokes.removeAll { selection.contains($0.id) }
        clearSelection()
        drawing = d; commit(from: b)
    }
    func paste() {
        guard let c = InkCanvas.clip else { return }
        let b = drawing
        let t = CGAffineTransform(translationX: menuAt.x - c.origin.x, y: menuAt.y - c.origin.y)
        var d = drawing
        let new = c.strokes.map { s -> InkStroke in var n = s; n.id = UUID(); n.transform = s.transform.concatenating(t); return n }
        d.strokes += new
        drawing = d; commit(from: b)
        selection = Set(new.map(\.id))
        let r = new.reduce(CGRect.null) { $0.union($1.renderBounds) }
        selPoly = [r.origin, CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        drawLasso(selPoly, closed: true)
    }

    // MARK: Undo
    private let undos = UndoManager()
    override var undoManager: UndoManager? { undos }
    private func registerUndo(_ old: InkDrawing) {
        undos.registerUndo(withTarget: self) { c in
            let cur = c.drawing
            c.clearSelection()
            c.drawing = old
            c.registerUndo(cur)
            c.inkDelegate?.canvasViewDrawingDidChange?(c)
        }
    }
    func undo() { if undos.canUndo { undos.undo() } }
    func redo() { if undos.canRedo { undos.redo() } }

    // MARK: Responder / keyboard
    override var canBecomeFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { let r = super.becomeFirstResponder(); InkPaletteHost.refresh(); return r }
    override func resignFirstResponder() -> Bool { let r = super.resignFirstResponder(); InkPaletteHost.refresh(); return r }
    func toolPickerSelectedToolDidChange(_ p: InkToolPicker) { tool = p.selectedTool }

    private var picker: InkToolPicker? { InkToolPicker.all.allObjects.first { $0.visibleFor.contains(self) } }
    override var keyCommands: [UIKeyCommand]? {
        var k: [UIKeyCommand] = [
            UIKeyCommand(title: "撤销", action: #selector(kUndo), input: "z", modifierFlags: .command),
            UIKeyCommand(title: "重做", action: #selector(kRedo), input: "z", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "橡皮擦", action: #selector(kEraser), input: "e", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "套索", action: #selector(kLasso), input: "l", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "激光笔", action: #selector(kLaser), input: "k", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "拷贝所选", action: #selector(kCopy), input: "c", modifierFlags: .command),
            UIKeyCommand(title: "粘贴", action: #selector(kPaste), input: "v", modifierFlags: .command),
            UIKeyCommand(title: "删除所选", action: #selector(kDelete), input: UIKeyCommand.inputDelete, modifierFlags: [])
        ]
        for (i, p) in InkPresets.shared.presets.prefix(9).enumerated() {
            k.append(UIKeyCommand(title: "笔 \(i + 1)：\(p.kind.title)", action: #selector(kPreset(_:)), input: "\(i + 1)", modifierFlags: .command, propertyList: i))
        }
        k.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return k
    }
    @objc private func kUndo() { undo() }
    @objc private func kRedo() { redo() }
    private func pick(_ k: InkKind) {
        if let p = picker { p.select(kind: k) } else { let t = InkToolPicker(); t.select(kind: k); tool = t.selectedTool }
    }
    @objc private func kEraser() { pick(.eraser) }
    @objc private func kLasso() { pick(.lasso) }
    @objc private func kLaser() { pick(.laser) }
    @objc private func kCopy() { copySelection() }
    @objc private func kPaste() { menuAt = CGPoint(x: contentOffset.x / max(zoomScale, 0.01) + 40, y: contentOffset.y / max(zoomScale, 0.01) + 40); paste() }
    @objc private func kDelete() { deleteSelection() }
    @objc private func kPreset(_ c: UIKeyCommand) {
        guard let i = c.propertyList as? Int, InkPresets.shared.presets.indices.contains(i) else { return }
        let p = InkPresets.shared.presets[i]
        if let pk = picker { pk.select(p) } else { tool = p.tool }
    }
}
