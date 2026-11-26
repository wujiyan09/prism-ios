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
    enum Kind { case pen, pencil, marker, eraser, bitmapEraser, other }
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
    /// Page the pad shows (paged sources); main window follows.
    var padIndex = 0
    @ObservationIgnored private var posListeners: [String: [(id: ObjectIdentifier, f: (CGFloat) -> Void)]] = [:]
    /// Pad's top y in logical units (continuous sources).
    func padMoved(_ ch: String, _ y: CGFloat) { guard padOpen && mainFollows else { return }; for x in posListeners[ch] ?? [] { x.f(y) } }
    func listenPos(_ ch: String, _ o: AnyObject, _ f: @escaping (CGFloat) -> Void) {
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
    init() { layer.fillColor = nil; layer.lineCap = .round; layer.lineJoin = .round; layer.zPosition = 100 }
    /// Paper colour for the bitmap-eraser preview.
    var paper: UIColor = .white
    /// k: logical → host-layer units. dark: host shows ink inverted (dark scratch).
    func show(_ l: PadHub.Live?, k: CGFloat, in host: CALayer, dark: Bool = false) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let l, l.points.count > 0, l.kind != .eraser else { layer.path = nil; return }
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
        if l.kind == .marker || l.kind == .bitmapEraser || l.forces.count != pts.count {
            // Constant width: one stroked path.
            let p = UIBezierPath()
            p.move(to: pts[0])
            for q in pts.dropFirst() { p.addLine(to: q) }
            if pts.count == 1 { p.addLine(to: CGPoint(x: pts[0].x + 0.1, y: pts[0].y)) }
            layer.path = p.cgPath
            layer.fillColor = nil
            layer.strokeColor = colour.withAlphaComponent(alpha).cgColor
            layer.lineWidth = max(1, base)
            layer.lineCap = l.kind == .marker ? .square : .round
            return
        }
        // Pressure-sensitive (pen / pencil): filled outline of round segments, width from force.
        if l.kind == .pencil { base *= 0.8 }
        let p = UIBezierPath()
        func w(_ i: Int) -> CGFloat { max(0.6, base * (0.35 + 0.9 * min(1, l.forces[i]))) / 2 }
        for i in pts.indices {
            let r = w(i)
            p.append(UIBezierPath(ovalIn: CGRect(x: pts[i].x - r, y: pts[i].y - r, width: r * 2, height: r * 2)))
            if i > 0 {
                let a = pts[i - 1], b = pts[i], ra = w(i - 1)
                let dx = b.x - a.x, dy = b.y - a.y, d = max(0.001, hypot(dx, dy))
                let nx = -dy / d, ny = dx / d
                let q = UIBezierPath()
                q.move(to: CGPoint(x: a.x + nx * ra, y: a.y + ny * ra))
                q.addLine(to: CGPoint(x: b.x + nx * r, y: b.y + ny * r))
                q.addLine(to: CGPoint(x: b.x - nx * r, y: b.y - ny * r))
                q.addLine(to: CGPoint(x: a.x - nx * ra, y: a.y - ny * ra))
                q.close()
                p.append(q)
            }
        }
        p.usesEvenOddFillRule = false
        layer.path = p.cgPath
        layer.fillRule = .nonZero
        layer.fillColor = colour.withAlphaComponent(alpha).cgColor
        layer.strokeColor = nil
        layer.lineWidth = 0
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
    var host: () -> CALayer? = { nil }
    /// Main-canvas units per logical unit.
    var k: () -> CGFloat = { 1 }
    var onScroll: ((CGFloat) -> Void)?
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
        PadHub.shared.listenPos(channel, self) { [weak self] y in self?.onScroll?(y) }
    }
    func tearDown() {
        guard on else { return }; on = false
        PadHub.shared.stop(self); PadHub.shared.stopPos(self); live.detach()
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
        return PadSource(owner: ch, title: "草稿纸", continuous: true, pages: [page])
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

    private var pageIndex: Int {
        guard let s = hub.source, !s.pages.isEmpty else { return 0 }
        return min(max(0, hub.padIndex), s.pages.count - 1)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let s = hub.source, !s.pages.isEmpty {
                    let p = s.pages[s.continuous ? 0 : pageIndex]
                    PadCanvas(page: p, continuous: s.continuous, followY: hub.mainFollows && s.continuous ? hub.scratchY : nil, zoom: $zoom, locked: zlock)
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
                        Text("\(pageIndex + 1)/\(s.pages.count)").font(.subheadline.monospacedDigit()).padding(.horizontal, 6)
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
    @Binding var zoom: CGFloat
    var locked = false

    func makeCoordinator() -> Coord { Coord(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let c = context.coordinator
        let v = PKCanvasView()
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
            PadHub.shared.live(c.parent.page.channel, .init(points: pts.map { CGPoint(x: $0.x / z, y: $0.y / z) }, color: color, width: width, forces: fs, kind: kind))
        }
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
        if !v.isZooming && abs(v.zoomScale - target) > 0.001 && c.base > 0 { v.setZoomScale(target, animated: true) }
        if let y = followY, continuous, abs(y - c.lastFollow) > 1 {
            c.lastFollow = y
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
        let picker = PKToolPicker()
        var base: CGFloat = 1
        var fittedWidth: CGFloat = 0
        var lastFollow: CGFloat = -1
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
        func scrollViewDidZoom(_ v: UIScrollView) { layout(v) }
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
            guard parent.continuous, v.zoomScale > 0 else { return }
            PadHub.shared.padMoved(parent.page.channel, max(0, v.contentOffset.y) / v.zoomScale)
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
