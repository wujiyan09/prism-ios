import SwiftUI
import PencilKit
import PDFKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - 手写板: a second window (on the iPad screen) that writes into the canvas active in the main window.

/// One writable page, in logical coordinates (independent of any view's size).
struct PadPage {
    let channel: String
    let size: CGSize
    let background: () -> UIImage?
    let load: () -> PKDrawing
    let save: (PKDrawing) -> Void
    /// Images placed on the sheet (scratch figures), in logical units.
    var figures: () -> [(UIImage, CGRect)] = { [] }
}

struct PadSource {
    let owner: String
    let title: String
    /// true = one tall sheet (scratch) that scrolls; false = separate pages.
    let continuous: Bool
    let pages: [PadPage]
}

struct PadMC { var count: Int; var selected: Int?; var pick: (Int) -> Void }

/// Shared, in-process hub: the active canvas, live stroke sync between windows, and the main window's controls.
@Observable
final class PadHub {
    static let shared = PadHub()

    private(set) var source: PadSource?
    /// Page shown in the main window (paged sources).
    var index = 0
    /// Top of the main scratch column, in sheet points (continuous sources).
    var scratchY: CGFloat = 0
    /// Visible width of the main scratch column, in sheet units (zoom sync).
    var scratchW: CGFloat = 0
    var mcCount = 0
    var mcSelected: Int?
    var padOpen = false { didSet { if padOpen != oldValue { if !padOpen { latest = [:] }; NotificationCenter.default.post(name: .padState, object: nil) } } }
    /// Id of the stroke being previewed; cleared when its PKStroke commits or the touch is cancelled.
    @ObservationIgnored var strokeSeq = 0

    @ObservationIgnored var prev: (() -> Void)?
    @ObservationIgnored var next: (() -> Void)?
    @ObservationIgnored private var mcPick: ((Int) -> Void)?
    @ObservationIgnored private var latest: [String: PKDrawing] = [:]
    @ObservationIgnored private var listeners: [String: [(id: ObjectIdentifier, f: (PKDrawing) -> Void)]] = [:]

    func activate(_ s: PadSource, index i: Int = 0, force: Bool = false) {
        if force || source?.owner != s.owner || source?.pages.count != s.pages.count || source?.title != s.title { source = s }
        if index != i { index = i }
    }
    func deactivate(_ owner: String) { if source?.owner == owner { source = nil } }
    func setIndex(_ owner: String, _ i: Int) { if source?.owner == owner && index != i { index = i } }

    func setMC(_ m: PadMC?) {
        mcPick = m?.pick
        let c = m?.count ?? 0
        if mcCount != c { mcCount = c }
        if mcSelected != m?.selected { mcSelected = m?.selected }
    }
    func pick(_ i: Int) { mcPick?(i) }

    // Live strokes
    func publish(_ ch: String, _ d: PKDrawing, from o: AnyObject) {
        latest[ch] = d
        let me = ObjectIdentifier(o)
        for l in listeners[ch] ?? [] where l.id != me { l.f(d) }
    }
    func current(_ ch: String) -> PKDrawing? { latest[ch] }
    func listen(_ ch: String, _ o: AnyObject, _ f: @escaping (PKDrawing) -> Void) {
        let me = ObjectIdentifier(o)
        var ls = (listeners[ch] ?? []).filter { $0.id != me }
        ls.append((me, f)); listeners[ch] = ls
    }
    func stop(_ o: AnyObject) {
        let me = ObjectIdentifier(o)
        for k in listeners.keys { listeners[k]?.removeAll { $0.id == me } }
    }
    func forget(_ ch: String) { latest[ch] = nil }

    // Live mid-stroke preview (pad → main), points in logical units. nil points = clear.
    enum Kind { case pen, pencil, marker, eraser, bitmapEraser, lasso, other }
    /// width: logical units; forces: 0…1 per point (empty = constant width).
    struct Live { var points: [CGPoint]; var color: UIColor; var width: CGFloat; var forces: [CGFloat] = []; var kind: Kind = .pen }
    static func describe(_ t: PKTool) -> (Kind, UIColor, CGFloat) {
        if let i = t as? PKInkingTool {
            switch i.inkType {
            case .pen: return (.pen, i.color, i.width)
            case .pencil: return (.pencil, i.color, i.width)
            case .marker: return (.marker, i.color, i.width)
            default: return (.other, i.color, i.width)
            }
        }
        if let e = t as? PKEraserTool {
            var w: CGFloat = 16
            if #available(iOS 16.4, *) { w = e.width }
            return (e.eraserType == .bitmap ? .bitmapEraser : .eraser, .systemGray, w)
        }
        if t is PKLassoTool { return (.lasso, .systemBlue, 2) }
        return (.other, .systemGray, 6)
    }
    @ObservationIgnored private var liveListeners: [String: [(id: ObjectIdentifier, f: (Live?) -> Void)]] = [:]
    func live(_ ch: String, _ l: Live?) { for x in liveListeners[ch] ?? [] { x.f(l) } }
    func listenLive(_ ch: String, _ o: AnyObject, _ f: @escaping (Live?) -> Void) {
        let me = ObjectIdentifier(o)
        var ls = (liveListeners[ch] ?? []).filter { $0.id != me }
        ls.append((me, f)); liveListeners[ch] = ls
    }
    func stopLive(_ o: AnyObject) {
        let me = ObjectIdentifier(o)
        for k in liveListeners.keys { liveListeners[k]?.removeAll { $0.id == me } }
    }

    // The pad drives position; the main window follows while 主窗口跟随 is on.
    var mainFollows = true
    @ObservationIgnored var navOwner: UUID?
    /// Last time a window applied the other's viewport (echo guard).
    @ObservationIgnored var padApplied = Date.distantPast
    @ObservationIgnored var mainApplied = Date.distantPast
    /// 同步范围: true = 页码 + 上下位置 + 缩放 (default), false = 页码 + 上下位置.
    static var syncZoom: Bool { UserDefaults.standard.object(forKey: "pad.syncZoom") as? Bool ?? true }
    /// Page the pad shows (paged sources); main window follows.
    var padIndex = 0
    @ObservationIgnored private var posListeners: [String: [(id: ObjectIdentifier, f: (CGFloat, CGFloat) -> Void)]] = [:]
    /// Pad's top y in logical units (continuous sources).
    /// Pad is the master: the main window always follows the pad's viewport (top y, visible width; sheet units).
    func padMoved(_ ch: String, _ y: CGFloat, _ w: CGFloat) { guard padOpen else { return }; for x in posListeners[ch] ?? [] { x.f(y, w) } }
    func listenPos(_ ch: String, _ o: AnyObject, _ f: @escaping (CGFloat, CGFloat) -> Void) {
        let me = ObjectIdentifier(o)
        var ls = (posListeners[ch] ?? []).filter { $0.id != me }
        ls.append((me, f)); posListeners[ch] = ls
    }
    func stopPos(_ o: AnyObject) {
        let me = ObjectIdentifier(o)
        for k in posListeners.keys { posListeners[k]?.removeAll { $0.id == me } }
    }
}

/// Main-window side of a live preview: a shape layer that grows with the pad's pen.
final class LivePreview {
    let layer = CAShapeLayer()
    private var buckets: [CAShapeLayer] = []
    init() { layer.fillColor = nil; layer.lineCap = .round; layer.lineJoin = .round; layer.zPosition = 100 }
    /// Paper colour for the bitmap-eraser preview.
    var paper: UIColor = .white
    /// k: logical → host-layer units. dark: host shows ink inverted (dark scratch).
    func show(_ l: PadHub.Live?, k: CGFloat, in host: CALayer, dark: Bool = false) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let l, l.points.count > 0, l.kind != .eraser else { layer.path = nil; buckets.forEach { $0.path = nil }; return }
        if layer.superlayer !== host { host.addSublayer(layer) }
        let pts = l.points.map { CGPoint(x: $0.x * k, y: $0.y * k) }
        var colour = l.color
        if dark { colour = PKInkingTool.convertColor(colour, from: .light, to: .dark) }
        var alpha: CGFloat = 1
        var base = l.width * k
        switch l.kind {
        case .pencil: alpha = 0.75
        case .marker: alpha = 0.5
        case .bitmapEraser: colour = paper
        default: break
        }
        layer.lineDashPattern = l.kind == .lasso ? [6, 5] : nil
        if l.kind == .lasso { base = 2; colour = .systemBlue }
        if l.kind == .lasso || l.kind == .marker || l.kind == .bitmapEraser || l.forces.count != pts.count {
            // Constant width: one stroked path.
            buckets.forEach { $0.path = nil }
            // Smooth: quad curves through midpoints.
            let p = UIBezierPath()
            p.move(to: pts[0])
            if pts.count > 2 {
                for i in 1..<(pts.count - 1) {
                    let m = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                    p.addQuadCurve(to: m, controlPoint: pts[i])
                }
                p.addLine(to: pts[pts.count - 1])
            } else { for q in pts.dropFirst() { p.addLine(to: q) } }
            if pts.count == 1 { p.addLine(to: CGPoint(x: pts[0].x + 0.1, y: pts[0].y)) }
            layer.path = p.cgPath
            layer.fillColor = nil
            layer.strokeColor = colour.withAlphaComponent(alpha).cgColor
            layer.lineWidth = max(1, base)
            layer.lineCap = l.kind == .marker ? .square : .round
            return
        }
        // Pressure-sensitive (pen / pencil): continuous round-capped segments, grouped into width buckets
        // (one sublayer per bucket) so the line never breaks up into dots.
        if l.kind == .pencil { base *= 0.8 }
        func w(_ i: Int) -> CGFloat { max(0.6, base * (0.35 + 0.9 * min(1, l.forces[i]))) }
        let n = 8
        while buckets.count < n { let b = CAShapeLayer(); b.fillColor = nil; b.lineCap = .round; b.lineJoin = .round; layer.addSublayer(b); buckets.append(b) }
        let lo = max(0.6, base * 0.35), hi = max(lo + 0.01, base * 1.25)
        var paths = (0..<n).map { _ in CGMutablePath() }
        if pts.count == 1 { paths[0].move(to: pts[0]); paths[0].addLine(to: CGPoint(x: pts[0].x + 0.1, y: pts[0].y)) }
        for i in pts.indices.dropFirst() {
            let ww = (w(i - 1) + w(i)) / 2
            let b = min(n - 1, max(0, Int(((ww - lo) / (hi - lo)) * CGFloat(n))))
            paths[b].move(to: pts[i - 1]); paths[b].addLine(to: pts[i])
        }
        layer.path = nil
        let c = colour.withAlphaComponent(alpha).cgColor
        for (k2, b) in buckets.enumerated() {
            b.path = paths[k2].isEmpty ? nil : paths[k2]
            b.strokeColor = c
            b.lineWidth = lo + (hi - lo) * (CGFloat(k2) + 0.5) / CGFloat(n)
        }
    }
    /// Pencil hover cursor: a dot at points[0]; width = diameter in logical units.
    func dot(_ l: PadHub.Live?, k: CGFloat, in host: CALayer) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let l, let p = l.points.first else { layer.path = nil; return }
        if layer.superlayer !== host { host.addSublayer(layer) }
        let r = max(3, l.width * k / 2)
        layer.path = UIBezierPath(ovalIn: CGRect(x: p.x * k - r, y: p.y * k - r, width: r * 2, height: r * 2)).cgPath
        if l.kind == .eraser || l.kind == .bitmapEraser {
            layer.fillColor = UIColor.white.withAlphaComponent(0.25).cgColor
            layer.strokeColor = UIColor.systemGray.cgColor
            layer.lineWidth = 1.5
        } else {
            layer.fillColor = l.color.withAlphaComponent(0.55).cgColor
            layer.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
            layer.lineWidth = 1
        }
    }
}

/// Main-window glue: live stroke preview + hover dot for one channel.
final class LiveHost {
    let stroke = LivePreview()
    let cursor = LivePreview()
    var dark: () -> Bool = { false }
    func attach(_ ch: String, k: @escaping () -> CGFloat, host: @escaping () -> CALayer?) {
        PadHub.shared.listenLive(ch, self) { [weak self] l in
            guard let self, let h = host() else { return }
            self.stroke.show(l, k: k(), in: h, dark: self.dark())
            // Erasers: a cursor ring at the pen tip while erasing.
            if let l, l.kind == .eraser || l.kind == .bitmapEraser, let last = l.points.last {
                var c = l; c.points = [last]; self.cursor.dot(c, k: k(), in: h)
            } else if l == nil { self.cursor.dot(nil, k: k(), in: h) }
        }
        PadHub.shared.listenLive("hover:" + ch, self) { [weak self] l in
            guard let self, let h = host() else { return }
            self.cursor.dot(l, k: k(), in: h)
        }
    }
    func detach() { PadHub.shared.stopLive(self); stroke.layer.removeFromSuperlayer(); cursor.layer.removeFromSuperlayer() }
}

/// Watches pen touches on the pad without interfering with PencilKit, streaming points (incl. coalesced) to the main window.
final class PenTap: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onPoints: (([CGPoint], [CGFloat]) -> Void)?
    private var fs: [CGFloat] = []
    var onEnd: (() -> Void)?
    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?
    private var pts: [CGPoint] = []
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        delegate = self
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent) {
        pts = []; fs = []; onBegin?(); add(t, e)
    }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent) { add(t, e) }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent) { add(t, e); finish() }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent) { pts = []; onCancel?(); state = .failed }
    private func add(_ t: Set<UITouch>, _ e: UIEvent) {
        guard let v = view, let touch = t.first else { return }
        func f(_ t: UITouch) -> CGFloat { t.maximumPossibleForce > 0 ? t.force / t.maximumPossibleForce : 0.5 }
        for c in e.coalescedTouches(for: touch) ?? [touch] { pts.append(c.location(in: v)); fs.append(f(c)) }
        var show = pts, sf = fs
        for p in e.predictedTouches(for: touch) ?? [] { show.append(p.location(in: v)); sf.append(f(p)) }
        onPoints?(show, sf)
    }
    private func finish() { pts = []; onEnd?(); state = .failed }
    override func reset() { pts = [] }
}

extension Notification.Name {
    static let padAskDS = Notification.Name("padAskDS")
    static let padState = Notification.Name("padState")
    /// Pad turned the page (object = source owner, userInfo["i"]); main window follows when 主窗口跟随 is on.
    static let padPage = Notification.Name("padPage")
    /// Viewport of a paged page, object = channel, userInfo["r"] = visible rect in page units (top-left origin).
    static let padViewport = Notification.Name("padViewport")
    static let mainViewport = Notification.Name("mainViewport")
}

/// Main-window canvases: everything pad-related is installed only while the 手写板 scene is open.
final class PadLink {
    let channel: String
    weak var canvas: PKCanvasView?
    let live = LiveHost()
    private var on = false
    var isOn: Bool { on }
    private var obs: NSObjectProtocol?
    var applying = false
    private let eraseTap = NSObject()
    var host: () -> CALayer? = { nil }
    /// Main-canvas units per logical unit.
    var k: () -> CGFloat = { 1 }
    var onScroll: ((CGFloat, CGFloat) -> Void)?
    init(_ ch: String, canvas: PKCanvasView) {
        channel = ch; self.canvas = canvas
        obs = NotificationCenter.default.addObserver(forName: .padState, object: nil, queue: .main) { [weak self] _ in self?.sync() }
        DispatchQueue.main.async { [weak self] in self?.sync() }
    }
    deinit { if let obs { NotificationCenter.default.removeObserver(obs) }; tearDown() }
    func sync() { PadHub.shared.padOpen ? setUp() : tearDown() }
    private func setUp() {
        guard !on else { return }; on = true
        PadHub.shared.listen(channel, self) { [weak self] d in
            guard let self, let c = self.canvas else { return }
            let s = self.k()
            self.applying = true; c.drawing = s == 1 ? d : d.transformed(using: CGAffineTransform(scaleX: s, y: s)); self.applying = false
        }
        live.attach(channel, k: { [weak self] in self?.k() ?? 1 }, host: { [weak self] in self?.host() })
        // Live vector erase: remove strokes the pad's eraser passes over, before the commit arrives.
        PadHub.shared.listenLive(channel, eraseTap) { [weak self] l in
            guard let self, let l, l.kind == .eraser, let c = self.canvas, let p = l.points.last else { return }
            let s = self.k()
            let q = CGPoint(x: p.x * s, y: p.y * s)
            let r = max(6, l.width * s / 2)
            let box = CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)
            let old = c.drawing.strokes
            let keep = old.filter { st in
                guard st.renderBounds.intersects(box) else { return true }
                for pt in st.path.interpolatedPoints(by: .distance(3)) {
                    let a = pt.location.applying(st.transform)
                    if hypot(a.x - q.x, a.y - q.y) <= r + pt.size.width / 2 { return false }
                }
                return true
            }
            if keep.count != old.count { self.applying = true; c.drawing = PKDrawing(strokes: keep); self.applying = false }
        }
        PadHub.shared.listenPos(channel, self) { [weak self] y, w in self?.onScroll?(y, w) }
    }
    func tearDown() {
        guard on else { return }; on = false
        PadHub.shared.stop(self); PadHub.shared.stopPos(self); PadHub.shared.stopLive(eraseTap); live.detach()
    }
    /// Main canvas changed (finger/pencil on the main window): mirror to the pad.
    func changed(_ d: PKDrawing) {
        guard on && !applying else { return }
        let s = k()
        PadHub.shared.publish(channel, s == 1 || s <= 0 ? d : d.transformed(using: CGAffineTransform(scaleX: 1 / s, y: 1 / s)), from: self)
    }
}

// MARK: Sources

enum PadSources {
    static func scratch(_ itemID: String, height: CGFloat) -> PadSource {
        let ch = "scratch:" + itemID
        let page = PadPage(channel: ch, size: CGSize(width: CanvasRep.width, height: height), background: { nil },
                           load: { ScratchStore.shared.load(itemID).flatMap { try? PKDrawing(data: $0.drawing) } ?? PKDrawing() },
                           save: { d in
                               let old = ScratchStore.shared.load(itemID)
                               ScratchStore.shared.save(itemID, ScratchDraft(drawing: d.dataRepresentation(), placed: old?.placed ?? [], height: old?.height))
                           })
        var pg = page
        pg.figures = {
            (ScratchStore.shared.load(itemID)?.placed ?? []).compactMap { f in
                guard let d = f.png, let img = UIImage(data: d), img.size.width > 0 else { return nil }
                return (img, CGRect(x: f.x, y: f.y, width: f.w, height: f.w * Double(img.size.height / img.size.width)))
            }
        }
        return PadSource(owner: ch, title: "草稿纸", continuous: true, pages: [pg])
    }

    static func note(_ id: String) -> PadSource? {
        guard let doc = NoteStore.shared.docs[id] else { return nil }
        let pages = doc.pages.map { p in
            let key = NoteStore.inkKey(id, p.id)
            return PadPage(channel: "note:" + key, size: CGSize(width: NoteRender.logicalWidth, height: NoteRender.logicalWidth * CGFloat(p.aspect)),
                           background: { NoteRender.background(id, p, width: 1400) },
                           load: { PDFInk.load(key, 0) ?? PKDrawing() },
                           save: { d in PDFInk.save(key, 0, d, title: doc.title, width: NoteRender.logicalWidth) })
        }
        return PadSource(owner: "note-" + id, title: doc.title, continuous: false, pages: pages)
    }

    static func pdf(_ doc: PDFDocument, key: String, title: String) -> PadSource {
        var pages: [PadPage] = []
        for i in 0..<doc.pageCount {
            guard let pg = doc.page(at: i) else { continue }
            let size = pg.bounds(for: .mediaBox).size
            pages.append(PadPage(channel: "pdf:\(key):\(i)", size: size,
                                 background: { pg.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .mediaBox) },
                                 load: {
                                     guard let d = PDFInk.load(key, i) else { return PKDrawing() }
                                     let w = PDFInk.width(key, i) ?? size.width
                                     return d.transformed(using: CGAffineTransform(scaleX: size.width / w, y: size.width / w))
                                 },
                                 save: { d in
                                     let w = PDFInk.width(key, i) ?? size.width
                                     PDFInk.save(key, i, d.transformed(using: CGAffineTransform(scaleX: w / size.width, y: w / size.width)), title: title, width: w)
                                 }))
        }
        return PadSource(owner: "pdf:" + key, title: title, continuous: false, pages: pages)
    }
}

// MARK: Entry button

struct PadButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad && UIApplication.shared.supportsMultipleScenes {
            Button { openWindow(id: "pad") } label: { Label("打开手写板", systemImage: "rectangle.and.pencil.and.ellipsis") }
        }
    }
}

// MARK: Pad window

struct PadView: View {
    @State private var hub = PadHub.shared
    @Environment(\.scenePhase) private var phase
    @State private var zoom: CGFloat = 1
    @State private var zlock = false
    @State private var jumpCtl = ViewCtl()
    @State private var jumping = false

    private var pageIndex: Int {
        guard let s = hub.source, !s.pages.isEmpty else { return 0 }
        return min(max(0, hub.padIndex), s.pages.count - 1)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let s = hub.source, !s.pages.isEmpty {
                    let p = s.pages[s.continuous ? 0 : pageIndex]
                    PadCanvas(page: p, continuous: s.continuous, followY: hub.mainFollows && s.continuous ? hub.scratchY : nil,
                              followW: hub.mainFollows && s.continuous ? hub.scratchW : nil, zoom: $zoom, locked: zlock)
                        .id(p.channel + "|\(Int(p.size.height))")
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("没有可书写的页面", systemImage: "pencil.slash",
                                           description: Text("在主窗口打开草稿纸、笔记或 PDF 试卷，这里会自动跟上。"))
                }
            }
            .navigationTitle(hub.source.map { s in s.continuous ? s.title : "\(s.title) · \(pageIndex + 1)/\(s.pages.count)" } ?? "手写板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { bar }
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        }
        .onAppear { hub.padOpen = true; hub.padIndex = hub.index }
        .onDisappear { hub.padOpen = false }
        .onChange(of: phase) { _, p in hub.padOpen = p != .background }
        .onChange(of: hub.source?.owner) { _, _ in if hub.mainFollows { hub.padIndex = hub.index } }
        .onChange(of: hub.padIndex) { _, i in
            guard hub.mainFollows, let o = hub.source?.owner, i != hub.index else { return }
            NotificationCenter.default.post(name: .padPage, object: o, userInfo: ["i": i])
        }
        .onChange(of: hub.index) { _, i in if hub.mainFollows && hub.padIndex != i { hub.padIndex = i } }
        .onChange(of: hub.mainFollows) { _, on in if on { hub.padIndex = hub.index } }
        .onChange(of: hub.source?.owner, initial: true) { _, o in zlock = ZoomLock.get(o ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .zoomLockChanged)) { n in
            if let o = hub.source?.owner, (n.object as? String) == o { zlock = ZoomLock.get(o) }
        }
    }

    @ToolbarContentBuilder private var bar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if abs(zoom - 1) > 0.01 { Button("\(Int(zoom * 100))%") { if !zlock { zoom = 1 } } }
            Button { if let o = hub.source?.owner { zlock.toggle(); ZoomLock.set(o, zlock) } } label: {
                Label(zlock ? "解锁缩放" : "锁定缩放", systemImage: zlock ? "lock.fill" : "lock.open")
            }
            Button { hub.mainFollows.toggle() } label: {
                Label(hub.mainFollows ? "已与主窗口同步" : "独立浏览", systemImage: hub.mainFollows ? "link" : "link.badge.plus")
            }
        }
    }

    private var paged: Bool { hub.source.map { !$0.continuous } ?? false }
    private var hasQuestions: Bool { hub.prev != nil || hub.next != nil || KeyRouter.shared.pager != nil || hub.mcCount > 0 }

    /// The big screen isn't touchable: page / question controls live here, as floating glass.
    @ViewBuilder private var controls: some View {
        let row = HStack(spacing: 12) {
            if paged, let s = hub.source {
                glass {
                    HStack(spacing: 2) {
                        Button { hub.padIndex = max(0, pageIndex - 1) } label: { Label("上一页", systemImage: "chevron.up") }.disabled(pageIndex == 0)
                        Button {
                            jumpCtl.count = s.pages.count; jumpCtl.page = pageIndex
                            jumpCtl.goPage = { i in hub.padIndex = min(max(0, i), s.pages.count - 1) }
                            jumpCtl.thumb = { i in s.pages.indices.contains(i) ? s.pages[i].background() : nil }
                            jumping = true
                        } label: { Text("\(pageIndex + 1)/\(s.pages.count)").font(.subheadline.monospacedDigit()).padding(.horizontal, 6) }
                        .popover(isPresented: $jumping) { PageJump(ctl: jumpCtl) { jumping = false }.padding().frame(minWidth: 320) }
                        Button { hub.padIndex = min(s.pages.count - 1, pageIndex + 1) } label: { Label("下一页", systemImage: "chevron.down") }.disabled(pageIndex >= s.pages.count - 1)
                    }
                }
            }
            if hasQuestions || !paged {
                glass {
                    HStack(spacing: 2) {
                        Button { (hub.prev ?? KeyRouter.shared.pager?.prev)?() } label: { Label("上一题", systemImage: "chevron.left") }
                        Button { (hub.next ?? KeyRouter.shared.pager?.next)?() } label: { Label("下一题", systemImage: "chevron.right") }
                    }
                }
            }
            if hub.mcCount > 0 {
                glass {
                    HStack(spacing: 4) {
                        ForEach(0..<min(hub.mcCount, 6), id: \.self) { i in
                            Button { hub.pick(i) } label: {
                                Text(["A", "B", "C", "D", "E", "F"][i]).font(.headline).frame(minWidth: 30, minHeight: 30)
                                    .foregroundStyle(hub.mcSelected == i ? Color.white : Color.primary)
                                    .background(hub.mcSelected == i ? Color.accentColor : Color.clear, in: Circle())
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            glass {
                Button { NotificationCenter.default.post(name: .padAskDS, object: nil) } label: { Label("问 DeepSeek", systemImage: "sparkles") }
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.bottom, 10).padding(.top, 4)
        if #available(iOS 26.0, *) { GlassEffectContainer { row } } else { row }
    }

    @ViewBuilder private func glass<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        let v = c().padding(.horizontal, 12).frame(minHeight: 44)
        if #available(iOS 26.0, *) { v.glassEffect(.regular.interactive(), in: .capsule) }
        else { v.background(.regularMaterial, in: Capsule()) }
    }
}

/// Full-screen PencilKit page for the pad. Drawing is in logical units; the canvas zoom maps it to the screen.
struct PadCanvas: UIViewRepresentable {
    let page: PadPage
    let continuous: Bool
    let followY: CGFloat?
    var followW: CGFloat? = nil
    @Binding var zoom: CGFloat
    var locked = false

    func makeCoordinator() -> Coord { Coord(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let c = context.coordinator
        let v = QuietCanvas()
        v.drawingPolicy = .default
        v.backgroundColor = .clear
        v.isOpaque = false
        v.contentInsetAdjustmentBehavior = .never
        v.alwaysBounceVertical = true
        v.bouncesZoom = true
        if page.background() != nil {
            v.overrideUserInterfaceStyle = .light   // white paper: true ink colours, light tool palette
            c.picker.colorUserInterfaceStyle = .light
            c.picker.overrideUserInterfaceStyle = .light
        }
        v.drawing = PadHub.shared.current(page.channel) ?? page.load()
        let under = UIView(frame: CGRect(origin: .zero, size: page.size))
        under.layer.anchorPoint = .zero
        under.layer.position = .zero
        under.isUserInteractionEnabled = false
        if let bg = page.background() {
            let iv = UIImageView(image: bg); iv.frame = under.bounds; iv.contentMode = .scaleToFill
            under.addSubview(iv)
        } else {
            under.backgroundColor = .secondarySystemBackground
        }
        v.insertSubview(under, at: 0)
        c.under = under
        c.refreshFigures()
        c.vpObs = NotificationCenter.default.addObserver(forName: .mainViewport, object: page.channel, queue: .main) { [weak c] n in
            if PadHub.shared.mainFollows, let r = n.userInfo?["r"] as? CGRect { c?.mainMoved(r) }
        }
        c.figObs = NotificationCenter.default.addObserver(forName: .scratchSaved, object: nil, queue: .main) { [weak c] _ in c?.refreshFigures() }
        c.canvas = v
        v.delegate = c
        c.picker.addObserver(v)
        PadHub.shared.listen(page.channel, c) { [weak c] d in c?.remote(d) }
        let pen = PenTap(target: nil, action: nil)
        pen.onBegin = { [weak c] in
            PadHub.shared.strokeSeq += 1
            if let ch = c?.parent.page.channel { PadHub.shared.live("hover:" + ch, nil) }   // hover dot off at pen-down
        }
        pen.onCancel = { [weak c] in if let ch = c?.parent.page.channel { PadHub.shared.live(ch, nil) } }
        pen.onPoints = { [weak c, weak v] pts, fs in
            guard let c, let v else { return }
            let (kind, color, width) = PadHub.describe(c.picker.selectedTool)
            guard kind != .other else { return }
            let z = max(v.zoomScale, 0.0001)
            c.penFed = true
            PadHub.shared.live(c.parent.page.channel, .init(points: pts.map { CGPoint(x: $0.x / z, y: $0.y / z) }, color: color, width: width, forces: fs, kind: kind))
        }
        // Fallback that always works: follow PencilKit's own drawing recogniser (if the pen watcher gets no touches).
        v.drawingGestureRecognizer.addTarget(c, action: #selector(Coord.drawing(_:)))
        pen.onEnd = { [weak c] in
            // Preview stays until this stroke's PKStroke commits; fallback if PencilKit drops it (e.g. a tap).
            guard let ch = c?.parent.page.channel else { return }
            let id = PadHub.shared.strokeSeq
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if PadHub.shared.strokeSeq == id, c?.committed != id { PadHub.shared.live(ch, nil) } }
        }
        v.addGestureRecognizer(pen)
        let hover = UIHoverGestureRecognizer(target: c, action: #selector(Coord.hovered(_:)))
        v.addGestureRecognizer(hover)
        DispatchQueue.main.async {
            c.fit()
            c.picker.setVisible(true, forFirstResponder: v)
            v.becomeFirstResponder()
        }
        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if v.bounds.width > 10 && abs(v.bounds.width - c.fittedWidth) > 1 { c.fit() }
        if c.base > 0 {
            v.minimumZoomScale = locked ? v.zoomScale : c.base * 0.5
            v.maximumZoomScale = locked ? v.zoomScale : c.base * 4
        }
        let target = c.base * zoom
        if let w = followW, w > 10, continuous, !locked, PadHub.syncZoom, !v.isZooming, abs(w - c.lastW) > 1, v.bounds.width > 10 {
            c.lastW = w
            c.following = true
            v.zoomScale = min(v.maximumZoomScale, max(v.minimumZoomScale, v.bounds.width / w))
            c.following = false
            if c.base > 0 { let z = v.zoomScale / c.base; DispatchQueue.main.async { zoom = z } }
        } else if !v.isZooming && abs(v.zoomScale - target) > 0.001 && c.base > 0 { v.setZoomScale(target, animated: true) }
        if let y = followY, continuous, abs(y - c.lastFollow) > 1 {
            c.lastFollow = y
            c.following = true
            defer { c.following = false }
            let maxY = max(0, v.contentSize.height - v.bounds.height)
            v.setContentOffset(CGPoint(x: v.contentOffset.x, y: min(maxY, max(0, y * v.zoomScale))), animated: true)
        }
    }

    static func dismantleUIView(_ v: PKCanvasView, coordinator c: Coord) {
        c.flush()
        PadHub.shared.stop(c)
        c.picker.setVisible(false, forFirstResponder: v)
        c.picker.removeObserver(v)
    }

    final class Coord: NSObject, PKCanvasViewDelegate {
        var parent: PadCanvas
        weak var canvas: PKCanvasView?
        var under: UIView?
        var figObs: NSObjectProtocol?
        private var figViews: [UIImageView] = []
        private var figSig = ""
        deinit { if let figObs { NotificationCenter.default.removeObserver(figObs) }; if let vpObs { NotificationCenter.default.removeObserver(vpObs) }; ToolSync.shared.unregister(picker) }
        func refreshFigures() {
            guard let under else { return }
            let figs = parent.page.figures()
            let sig = figs.map { "\($0.1)" }.joined()
            guard sig != figSig else { return }
            figSig = sig
            figViews.forEach { $0.removeFromSuperview() }
            figViews = figs.map { img, r in
                let iv = UIImageView(image: img); iv.frame = r; iv.contentMode = .scaleAspectFit
                iv.backgroundColor = .white
                under.addSubview(iv); return iv
            }
        }
        let picker: PKToolPicker = { let p = PKToolPicker(); ToolSync.shared.register(p); return p }()
        var base: CGFloat = 1
        var fittedWidth: CGFloat = 0
        var lastFollow: CGFloat = -1
        var lastW: CGFloat = -1
        var penFed = false
        var vpObs: NSObjectProtocol?
        /// Main window moved/zoomed a PDF page: follow it (same page only).
        func mainMoved(_ r: CGRect) {
            guard let v = canvas, !parent.continuous, r.width > 1, v.bounds.width > 1 else { return }
            PadHub.shared.padApplied = Date()
            following = true; defer { following = false }
            if PadHub.syncZoom, !parent.locked {
                v.zoomScale = min(v.maximumZoomScale, max(v.minimumZoomScale, v.bounds.width / r.width))
            }
            let z = v.zoomScale
            let maxY = max(0, v.contentSize.height - v.bounds.height), maxX = max(0, v.contentSize.width - v.bounds.width)
            v.contentOffset = CGPoint(x: PadHub.syncZoom ? min(maxX, max(0, r.minX * z)) : v.contentOffset.x, y: min(maxY, max(0, r.minY * z)))
        }
        private var dpts: [CGPoint] = []
        @objc func drawing(_ g: UIGestureRecognizer) {
            guard let v = canvas else { return }
            let ch = parent.page.channel
            switch g.state {
            case .began:
                dpts = []
                if !penFed { PadHub.shared.strokeSeq += 1 }
                PadHub.shared.live("hover:" + ch, nil)
                fallthrough
            case .changed:
                guard !penFed else { return }
                let z = max(v.zoomScale, 0.0001)
                let p = g.location(in: v)
                dpts.append(CGPoint(x: p.x / z, y: p.y / z))
                let (kind, color, width) = PadHub.describe(picker.selectedTool)
                guard kind != .other else { return }
                PadHub.shared.live(ch, .init(points: dpts, color: color, width: width, kind: kind))
            case .cancelled, .failed:
                dpts = []; penFed = false; PadHub.shared.live(ch, nil)
            default:
                dpts = []; penFed = false
                let id = PadHub.shared.strokeSeq
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    if PadHub.shared.strokeSeq == id, self?.committed != id { PadHub.shared.live(ch, nil) }
                }
            }
        }
        var following = false
        var committed = -1
        private var applying = false
        private var pending: DispatchWorkItem?
        init(_ p: PadCanvas) { parent = p }

        func fit() {
            guard let v = canvas, v.bounds.width > 10 else { return }
            fittedWidth = v.bounds.width
            base = v.bounds.width / parent.page.size.width
            v.minimumZoomScale = base * 0.5
            v.maximumZoomScale = base * 4
            v.zoomScale = base * parent.zoom
            layout(v)
        }
        private func layout(_ v: UIScrollView) {
            let z = v.zoomScale
            v.contentSize = CGSize(width: parent.page.size.width * z, height: parent.page.size.height * z)
            under?.transform = CGAffineTransform(scaleX: z, y: z)
            under?.layer.position = .zero
            let ix = max(0, (v.bounds.width - v.contentSize.width) / 2)
            let iy = parent.continuous ? 0 : max(0, (v.bounds.height - v.contentSize.height) / 2)
            v.contentInset = UIEdgeInsets(top: iy, left: ix, bottom: iy, right: ix)
            v.alwaysBounceHorizontal = v.contentSize.width > v.bounds.width + 1
        }
        func scrollViewDidZoom(_ v: UIScrollView) { layout(v); scrollViewDidScroll(v) }
        @objc func hovered(_ g: UIHoverGestureRecognizer) {
            guard let v = canvas else { return }
            let ch = "hover:" + parent.page.channel
            switch g.state {
            case .began, .changed:
                let z = max(v.zoomScale, 0.0001)
                let p = g.location(in: v)
                let (kind, color, w) = PadHub.describe(picker.selectedTool)
                let lift = g.zOffset   // 0 (touching) … 1 (max hover height)
                let eraser = kind == .eraser || kind == .bitmapEraser
                PadHub.shared.live(ch, .init(points: [CGPoint(x: p.x / z, y: p.y / z)], color: color,
                                             width: eraser ? w : max(6, w) * (1 + 2 * lift), kind: kind))
            default:
                PadHub.shared.live(ch, nil)
            }
        }
        func scrollViewDidScroll(_ v: UIScrollView) {
            guard v.zoomScale > 0, !following else { return }
            if !parent.continuous {
                guard Date().timeIntervalSince(PadHub.shared.padApplied) > 0.35 else { return }
                let z = v.zoomScale
                NotificationCenter.default.post(name: .padViewport, object: parent.page.channel,
                    userInfo: ["r": CGRect(x: v.contentOffset.x / z, y: v.contentOffset.y / z, width: v.bounds.width / z, height: v.bounds.height / z)])
                return
            }
            PadHub.shared.padMoved(parent.page.channel, max(0, v.contentOffset.y) / v.zoomScale, v.bounds.width / v.zoomScale)
        }
        func scrollViewDidEndZooming(_ v: UIScrollView, with view: UIView?, atScale s: CGFloat) {
            if base > 0 { let z = s / base; DispatchQueue.main.async { self.parent.zoom = z } }
        }

        func remote(_ d: PKDrawing) {
            guard let v = canvas else { return }
            applying = true; v.drawing = d; applying = false
        }
        func canvasViewDrawingDidChange(_ v: PKCanvasView) {
            guard !applying else { return }
            PadHub.shared.publish(parent.page.channel, v.drawing, from: self)
            committed = PadHub.shared.strokeSeq
            PadHub.shared.live(parent.page.channel, nil)
            pending?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.flush() }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
        }
        func flush() {
            pending?.cancel(); pending = nil
            guard let v = canvas else { return }
            parent.page.save(v.drawing)
        }
    }
}

/// Registers the current question's MC choices for the pad's A–D buttons (cheap: a few stored values).
struct PadMCRegister: ViewModifier {
    let id: String
    let count: Int
    let selected: Int?
    let pick: (Int) -> Void
    func body(content: Content) -> some View {
        content
            .onAppear { PadHub.shared.setMC(PadMC(count: count, selected: selected, pick: pick)) }
            .onChange(of: id + "|\(selected ?? -1)|\(count)") { _, _ in PadHub.shared.setMC(PadMC(count: count, selected: selected, pick: pick)) }
            .onDisappear { PadHub.shared.setMC(nil) }
    }
}
extension View {
    func padMC(_ id: String, count: Int, selected: Int?, pick: @escaping (Int) -> Void) -> some View {
        modifier(PadMCRegister(id: id, count: count, selected: selected, pick: pick))
    }
}

/// PKCanvasView without the tap edit menu (全选 / 插入空白); lasso actions stay.
final class QuietCanvas: PKCanvasView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let n = NSStringFromSelector(action).lowercased()
        if action == #selector(selectAll(_:)) || n.contains("insertspace") || n.contains("insertspacing") || n.contains("selectall") { return false }
        return super.canPerformAction(action, withSender: sender)
    }
}

/// Keeps the pad's and the main window's tool pickers on the same tool (type, colour, width, eraser).
final class ToolSync: NSObject, PKToolPickerObserver {
    static let shared = ToolSync()
    private var pickers: [PKToolPicker] = []
    private var busy = false
    func register(_ p: PKToolPicker) {
        guard !pickers.contains(where: { $0 === p }) else { return }
        pickers.append(p); p.addObserver(self)
        if let other = pickers.first(where: { $0 !== p }) { busy = true; p.selectedTool = other.selectedTool; busy = false }
    }
    func unregister(_ p: PKToolPicker) { p.removeObserver(self); pickers.removeAll { $0 === p } }
    func toolPickerSelectedToolDidChange(_ src: PKToolPicker) {
        guard !busy, PadHub.shared.padOpen else { return }
        busy = true; defer { busy = false }
        for p in pickers where p !== src { p.selectedTool = src.selectedTool }
    }
}
