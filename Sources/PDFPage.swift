import SwiftUI
import PDFKit

/// Downloads a PDF once, caches it, and shows it natively with PDFKit.
struct PDFPage: View {
    let url: URL
    let title: String
    var inkID: String? = nil      // stable ink key (local files move between installs)
    var subject = "ict"
    @Environment(\.tr) private var T
    @State private var doc: PDFDocument?
    @State private var failed = false
    @State private var pageIndex = 0
    @State private var share: ShareItem?
    @State private var ink = InkProvider()
    @State private var inkOn = false
    @State private var vctl = ViewCtl()

    /// Downloaded papers live in Application Support (Caches can be purged by iOS → re-download on every open).
    private var file: URL {
        let name0 = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.lastPathComponent
        let fn = String(name0.suffix(120)) + ".pdf"
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("papers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let old = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("papers/" + fn)
        if !FileManager.default.fileExists(atPath: d.appendingPathComponent(fn).path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: d.appendingPathComponent(fn))
        }
        return d.appendingPathComponent(fn)
    }
    private var fileOld: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("papers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let name = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.lastPathComponent
        return d.appendingPathComponent(String(name.suffix(120)) + ".pdf")
    }

    var body: some View {
        Group {
            if let doc {
                PDFKitView(doc: doc, onPage: { pageIndex = $0 }, ink: ink, inkKey: inkID ?? ("pdf:" + url.absoluteString), inkTitle: title, ctl: vctl).ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .topTrailing) { ViewHUD(ctl: vctl) }
            } else if failed {
                ContentUnavailableView {
                    Label(T("Couldn't load the paper", "试卷下载失败"), systemImage: "wifi.exclamationmark")
                } actions: {
                    Button(T("Try again", "重试")) { Task { await load() } }.glassButton(prominent: true)
                }
            } else {
                ProgressView(T("Downloading…", "正在下载…"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appScreen()
        .navigationTitle(title)
        .noteRecent(.pdf(url.absoluteString, title), title, "PDF")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if doc != nil {
                ToolbarItem(placement: .primaryAction) { InkToggle(on: $inkOn) }
                ToolbarItem(placement: .primaryAction) { PadButton() }
                ToolbarItem(placement: .primaryAction) {
                    Button { share = ShareItem(url: file) } label: { Label(T("Share", "分享"), systemImage: "square.and.arrow.up") }
                }
            }
        }
        .sheet(item: $share) { s in RangeShareSheet(url: s.url, current: pageIndex) }
        .deepSeek(doc.map { DSContext.pdfPage($0, pageIndex, title: title, url: url, subject: subject) })
        .onChange(of: inkOn) { _, v in ink.enabled = v }
        .task { await load() }
    }

    private func load() async {
        failed = false
        if url.isFileURL { doc = PDFDocument(url: url); failed = doc == nil; return }
        if let d = PDFDocument(url: file) { doc = d; return }
        do {
            var req = URLRequest(url: url, timeoutInterval: 120)
            req.setValue("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, data.starts(with: Data("%PDF".utf8)) else { throw URLError(.badServerResponse) }
            try data.write(to: file, options: .atomic)
            doc = PDFDocument(data: data)
            if doc == nil { failed = true }
        } catch {
            failed = true
        }
    }
}

/// PDFView whose scroll view runs to the very bottom edge: no automatic bottom inset (home indicator), the top
/// inset is kept so the first page isn't under the navigation bar.
final class EdgePDFView: PDFView {
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); fixInsets() }
    private var lastWidth: CGFloat = 0
    /// Resizing the view (DeepSeek panel / sidebar dragged) used to re-scale the pages and leave the scroll position
    /// where it was in points: the page jumped or turned. Keep the point at the top of the view anchored instead.
    override func layoutSubviews() {
        let w = bounds.width
        var anchor: (PDFKit.PDFPage, CGPoint)?
        if lastWidth > 0, abs(w - lastWidth) > 0.5, document != nil {
            let probe = CGPoint(x: bounds.midX, y: safeAreaInsets.top + 1)
            if let pg = page(for: probe, nearest: true) { anchor = (pg, convert(probe, to: pg)) }
        }
        lastWidth = w
        super.layoutSubviews(); fixInsets()
        if let (pg, pt) = anchor {
            let restore = { [weak self] in
                guard let self else { return }
                self.go(to: PDFDestination(page: pg, at: CGPoint(x: pg.bounds(for: self.displayBox).minX, y: pt.y)))
            }
            restore()
            DispatchQueue.main.async(execute: restore)
        }
    }
    private func fixInsets() {
        guard let sv = PDFKitView.scroller(in: self) else { return }
        if sv.contentInsetAdjustmentBehavior != .never { sv.contentInsetAdjustmentBehavior = .never }
        let top = safeAreaInsets.top
        if sv.contentInset.top != top || sv.contentInset.bottom != 0 { sv.contentInset = UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0) }
        sv.verticalScrollIndicatorInsets = UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
    }
}

struct PDFKitView: UIViewRepresentable {
    let doc: PDFDocument
    var onPage: ((Int) -> Void)? = nil
    var ink: InkProvider? = nil
    var inkKey = ""
    var inkTitle = ""
    var ctl: ViewCtl? = nil
    /// Set for a note shown through PDFKit: ink keys per page (in page order) and the note id.
    var noteID: String? = nil
    var noteKeys: [String]? = nil
    final class Coord: NSObject {
        var channels: [String]?
        func channel(_ i: Int) -> String { if let c = channels, c.indices.contains(i) { return "note:" + c[i] }; return "pdf:\(inkKey):\(i)" }
        func index(_ ch: String) -> Int? {
            if let c = channels { return c.firstIndex { "note:" + $0 == ch } }
            guard ch.hasPrefix("pdf:\(inkKey):") else { return nil }
            return Int(ch.split(separator: ":").last ?? "")
        }
        var cmd: CmdZoom?
        weak var ctl: ViewCtl?
        @objc func scaled(_ n: Notification) {
            guard let v = n.object as? PDFView, v.scaleFactorForSizeToFit > 0 else { return }
            ctl?.report(zoom: v.scaleFactor / v.scaleFactorForSizeToFit)
        }
        var onPage: ((Int) -> Void)?
        var owner = ""
        weak var view: PDFView?
        @objc func changed(_ n: Notification) {
            guard let v = n.object as? PDFView, let p = v.currentPage, let d = v.document else { return }
            let i = d.index(for: p)
            // While following the pad's offset, the page comes from the pad: don't send it back (that ping-pong made the
            // page number flicker and stuttered at page boundaries).
            if Date().timeIntervalSince(PadHub.shared.mainApplied) > 0.4 { PadHub.shared.setIndex(owner, i) }
            ctl?.report(page: i, of: d.pageCount)
            DispatchQueue.main.async { self.onPage?(i) }
        }
        var inkKey = ""
        weak var addButton: UIButton?
        /// 加一页 shows at the bottom of the last page.
        func updateAdd() {
            guard let b = addButton, let v = view, let d = v.document, let p = d.page(at: d.pageCount - 1) else { return }
            let r = v.convert(p.bounds(for: .mediaBox), from: p)
            b.isHidden = r.maxY > v.bounds.height + 40
        }
        var inkTitle = ""
        func addPage() {
            guard let v = view, let d = v.document else { return }
            PDFExtra.add(d, key: inkKey)
            v.layoutDocumentView()
            if let p = d.page(at: d.pageCount - 1) { v.go(to: p) }
            PadHub.shared.activate(PadSources.pdf(d, key: inkKey, title: inkTitle))
            updateAdd()
        }
        @objc func padAdd(_ n: Notification) { if !owner.isEmpty, (n.object as? String) == owner { addPage() } }
        var userMoved = Date.distantPast
        var lastTick: CFTimeInterval = 0
        // Reopening shows the same page, spot and zoom as last time.
        var posKey = ""
        private var posSaveAt = Date.distantPast
        private var restoring = true
        func rememberPos() {
            guard !posKey.isEmpty, !restoring, let v = view, let p = v.currentPage, let d = v.document, v.scaleFactorForSizeToFit > 0 else { return }
            guard Date().timeIntervalSince(posSaveAt) > 0.3 else { return }
            posSaveAt = Date()
            let pt = v.convert(CGPoint(x: v.bounds.minX, y: v.bounds.minY + v.safeAreaInsets.top), to: p)
            UserDefaults.standard.set([Double(d.index(for: p)), Double(pt.x), Double(pt.y), Double(v.scaleFactor / v.scaleFactorForSizeToFit)], forKey: posKey)
        }
        func restorePos() {
            guard !posKey.isEmpty, let a = UserDefaults.standard.array(forKey: posKey) as? [Double], a.count == 4 else { restoring = false; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, let v = self.view, let d = v.document, let p = d.page(at: Int(a[0])) else { self?.restoring = false; return }
                if a[3] > 0.2, v.scaleFactorForSizeToFit > 0, abs(a[3] - 1) > 0.01 { v.autoScales = false; v.scaleFactor = v.scaleFactorForSizeToFit * CGFloat(a[3]); v.layoutIfNeeded() }
                v.go(to: PDFDestination(page: p, at: CGPoint(x: a[1], y: a[2])))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.restoring = false }
            }
        }
        var kvo: NSKeyValueObservation?
        var vpObs: NSObjectProtocol?
        /// Pad moved within a page: show the same rect.
        func padMoved(_ ch: String, _ r: CGRect) {
            guard Date().timeIntervalSince(userMoved) > 0.6 else { return }   // user is moving the big screen: don't snap it back
            guard PadHub.shared.mainFollows, let v = view, let d = v.document,
                  let i = index(ch), let p = d.page(at: i) else { return }
            PadHub.shared.mainApplied = Date()
            let b = p.bounds(for: .mediaBox)
            if PadHub.syncZoom, r.width > 1, v.bounds.width > 1 {
                v.maxScaleFactor = max(v.maxScaleFactor, v.scaleFactorForSizeToFit * DisplayInfo.maxZoom)
                let z = min(v.maxScaleFactor, max(v.minScaleFactor, v.bounds.width / r.width))
                if abs(z - v.scaleFactor) / max(z, 0.01) > 0.01 {
                    v.autoScales = false          // otherwise PDFKit re-fits and recentres, undoing x
                    v.scaleFactor = z              // only on a real change: each set relayouts PDFView
                    v.layoutIfNeeded()             // convert below must see the new scale
                }
            }
            // Move the scroll view directly (cheap) instead of go(to:), which relayouts every frame and stuttered.
            if let sv = PDFKitView.scroller(in: v) {
                let pt = v.convert(CGPoint(x: b.minX + r.minX, y: b.maxY - r.minY), from: p)
                let dy = pt.y
                let dx = pt.x
                let maxY = max(-sv.adjustedContentInset.top, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
                // PDFKit keeps the page centred with content insets, so the x range includes them (clamping at 0 lost x).
                if v.autoScales { v.autoScales = false }   // autoScales re-fits and recentres after we move: x snapped back
                let minX = -sv.adjustedContentInset.left
                let maxX = max(minX, sv.contentSize.width - sv.bounds.width + sv.adjustedContentInset.right)
                let o = CGPoint(x: min(maxX, max(minX, sv.contentOffset.x + dx)), y: min(maxY, max(-sv.adjustedContentInset.top, sv.contentOffset.y + dy)))
                if abs(o.y - sv.contentOffset.y) > 0.5 || abs(o.x - sv.contentOffset.x) > 0.5 { sv.contentOffset = o }
            } else {
                v.go(to: CGRect(x: b.minX + r.minX, y: b.maxY - r.minY - 1, width: 1, height: 1), on: p)
            }
        }
        /// Main window scrolled: tell the pad (visible rect of the current page).
        func mainScrolled() {
            guard PadHub.shared.padOpen, let v = view, let p = v.currentPage, let d = v.document else { return }
            // Only the user's own scrolling on the big screen is sent (never the echo of following the pad).
            guard let sv = PDFKitView.scroller(in: v), sv.isTracking || sv.isDragging || sv.isDecelerating || sv.isZooming else { return }
            userMoved = Date()
            let b = p.bounds(for: .mediaBox)
            let r = v.convert(v.bounds, to: p)
            let top = CGRect(x: r.minX - b.minX, y: b.maxY - r.maxY, width: r.width, height: r.height)
            NotificationCenter.default.post(name: .mainViewport, object: channel(d.index(for: p)), userInfo: ["r": top])
        }
        /// Main window follows the pad's page.
        @objc func padPage(_ n: Notification) {
            guard (n.object as? String) == owner, let i = n.userInfo?["i"] as? Int, let v = view, let p = v.document?.page(at: i) else { return }
            v.go(to: p)
        }
    }
    func makeCoordinator() -> Coord { Coord() }
    static func addButton() -> UIButton {
        let b: UIButton
        if #available(iOS 26.0, *) { b = UIButton(configuration: .glass()) } else { b = UIButton(configuration: .gray()) }
        b.configuration?.title = "加一页"
        b.configuration?.image = UIImage(systemName: "plus")
        b.configuration?.imagePadding = 6
        b.configuration?.cornerStyle = .capsule
        return b
    }
    static func scroller(in v: UIView) -> UIScrollView? {
        for s in v.subviews { if let sc = s as? UIScrollView { return sc }; if let f = scroller(in: s) { return f } }
        return nil
    }
    func makeUIView(context: Context) -> PDFView {
        let v = EdgePDFView()
        context.coordinator.onPage = onPage
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coord.changed(_:)), name: .PDFViewPageChanged, object: v)
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = UIColor(Color.appBackground)
        if let ink, let nid = noteID {
            // Note through PDFKit: no margins / 加一页 (pages are managed by the note), pad source = the note.
            ink.noteKeys = noteKeys
            ink.reset(key: inkKey, title: inkTitle)
            context.coordinator.inkTitle = inkTitle
            v.pageOverlayViewProvider = ink
            v.isInMarkupMode = true
            let co = context.coordinator
            co.inkKey = inkKey; co.channels = noteKeys; co.owner = "note-" + nid
            co.vpObs = NotificationCenter.default.addObserver(forName: .padViewport, object: nil, queue: .main) { [weak co] n in
                if let ch = n.object as? String, let r = n.userInfo?["r"] as? CGRect { co?.padMoved(ch, r) }
            }
            DispatchQueue.main.async { [weak v, weak co] in
                guard let v, let sv = Self.scroller(in: v) else { return }
                co?.kvo = sv.observe(\.contentOffset, options: [.new]) { _, _ in
                    let now = CACurrentMediaTime(); guard now - (co?.lastTick ?? 0) > 1.0 / 30 else { return }; co?.lastTick = now
                    DispatchQueue.main.async { co?.mainScrolled(); co?.rememberPos() }
                }
            }
            NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coord.padPage(_:)), name: .padPage, object: nil)
            if let s = PadSources.note(nid) { PadHub.shared.activate(s) }
        } else if let ink {
            PDFExtra.apply(doc, key: inkKey)
            let add = Self.addButton()
            add.isHidden = doc.pageCount > 1
            context.coordinator.inkTitle = inkTitle
            add.addAction(UIAction { [weak co = context.coordinator] _ in co?.addPage() }, for: .primaryActionTriggered)
            NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coord.padAdd(_:)), name: .padAddPage, object: nil)
            v.addSubview(add)
            add.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                add.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                add.bottomAnchor.constraint(equalTo: v.safeAreaLayoutGuide.bottomAnchor, constant: -16)
            ])
            context.coordinator.addButton = add
            ink.reset(key: inkKey, title: inkTitle)
            let k = inkKey; for i in 0..<doc.pageCount { InkBitmapCache.prewarm({ PDFInk.load(k, i) }) }   // every page's ink ready before it's turned to
            PDFMargins.apply(doc, key: inkKey)
            let mb = UIButton(configuration: .gray())
            mb.configuration?.image = UIImage(systemName: "arrow.left.and.right.square")
            mb.configuration?.cornerStyle = .capsule
            mb.accessibilityLabel = "页边距"
            mb.showsMenuAsPrimaryAction = true
            let key = inkKey, title = inkTitle
            mb.menu = UIMenu(title: "页边距（可书写）", children: [UIDeferredMenuElement.uncached { done in
                let m = PDFMargins.get(key)
                func side(_ name: String, _ cur: CGFloat, _ f: @escaping (CGFloat) -> Void) -> UIMenu {
                    UIMenu(title: name, options: .displayInline, children: PDFMargins.steps.map { s in
                        UIAction(title: s == 0 ? "\(name) 无" : "\(name) \(Int(s))", state: abs(s - cur) < 0.5 ? .on : .off) { _ in f(s) }
                    })
                }
                let change: (CGFloat, CGFloat) -> Void = { [weak v, weak ink] l, r in
                    guard let v, let d = v.document else { return }
                    PDFMargins.set(key, l: l, r: r, doc: d, title: title)
                    ink?.reload()
                    let at = v.currentPage.flatMap { d.index(for: $0) } ?? 0
                    v.document = nil; v.document = d
                    if let p = d.page(at: at) { v.go(to: p) }
                    PadHub.shared.activate(PadSources.pdf(d, key: key, title: title), force: true)
                }
                done([side("左", m.l) { change($0, PDFMargins.get(key).r) }, side("右", m.r) { change(PDFMargins.get(key).l, $0) }])
            }])
            v.addSubview(mb)
            mb.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                mb.leadingAnchor.constraint(equalTo: v.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                mb.bottomAnchor.constraint(equalTo: v.safeAreaLayoutGuide.bottomAnchor, constant: -16)
            ])
            v.pageOverlayViewProvider = ink
            v.isInMarkupMode = true
            let src = PadSources.pdf(doc, key: inkKey, title: inkTitle)
            context.coordinator.owner = src.owner
            let co = context.coordinator
            co.inkKey = inkKey
            co.vpObs = NotificationCenter.default.addObserver(forName: .padViewport, object: nil, queue: .main) { [weak co] n in
                if let ch = n.object as? String, let r = n.userInfo?["r"] as? CGRect { co?.padMoved(ch, r) }
            }
            DispatchQueue.main.async { [weak v, weak co] in
                guard let v, let sv = Self.scroller(in: v) else { return }
                co?.kvo = sv.observe(\.contentOffset, options: [.new]) { _, _ in
                    // ≤ 30 sync pushes a second while scrolling (was one per offset change).
                    let now = CACurrentMediaTime(); guard now - (co?.lastTick ?? 0) > 1.0 / 30 else { return }; co?.lastTick = now
                    DispatchQueue.main.async { co?.mainScrolled(); co?.updateAdd(); co?.rememberPos() }
                }
                co?.updateAdd()
            }
            NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coord.padPage(_:)), name: .padPage, object: nil)
            PadHub.shared.activate(src)
        }
        context.coordinator.view = v
        context.coordinator.posKey = inkKey.isEmpty ? "" : "pos.pdf:" + inkKey
        v.document = doc
        context.coordinator.restorePos()
        if let ctl {
            let c = context.coordinator
            c.ctl = ctl
            ctl.view = v
            NotificationCenter.default.addObserver(c, selector: #selector(Coord.scaled(_:)), name: .PDFViewScaleChanged, object: v)
            ctl.setZoom = { [weak v] z in guard let v else { return }; v.scaleFactor = v.scaleFactorForSizeToFit * z }
            ctl.goPage = { [weak v] i in if let v, let p = v.document?.page(at: i) { v.go(to: p) } }
            ctl.thumb = { [weak doc] i in doc?.page(at: i)?.thumbnail(of: CGSize(width: 180, height: 240), for: .mediaBox) }
            ctl.applyLock = { [weak v] on in
                guard let v else { return }
                let fit = v.scaleFactorForSizeToFit
                v.minScaleFactor = on ? v.scaleFactor : fit * 0.5
                v.maxScaleFactor = on ? v.scaleFactor : fit * 4
            }
            ctl.report(page: 0, of: doc.pageCount)
            ctl.bind(key: "pdf:" + inkKey)
            c.cmd = CmdZoom.install(on: v, apply: { [weak v] k, _ in
                guard let v else { return }
                v.scaleFactor = min(v.maxScaleFactor, max(v.minScaleFactor, v.scaleFactor * k))
            }, blocked: { [weak ctl] in ctl?.locked ?? false })
        }
        return v
    }
    static func dismantleUIView(_ v: PDFView, coordinator: Coord) {
        (v.pageOverlayViewProvider as? InkProvider)?.flushAll()   // closing: write only pages that changed, off-main
        if !coordinator.owner.isEmpty { PadHub.shared.deactivate(coordinator.owner) }
    }
    func updateUIView(_ v: PDFView, context: Context) {
        if v.document !== doc {
            if let nk = noteKeys, let ink {
                // Note pages changed (added / moved / deleted): rebuild overlays with the new page → key mapping.
                ink.flushAll(); ink.noteKeys = nk; ink.reload(); context.coordinator.channels = nk
            }
            let at = v.currentPage.flatMap { v.document?.index(for: $0) }
            v.document = doc
            if let at, let p = doc.page(at: min(at, doc.pageCount - 1)) { v.go(to: p) }
        }
    }
}

/// 中文 範文 notes PDF (served by the content Worker; downloaded once, kept with the chapter).
struct ZhNotesPDF: View {
    let chapter: MChapter
    @State private var url: URL?
    @State private var failed = false
    var body: some View {
        Group {
            if let url {
                PDFPage(url: url, title: chapter.t + " 筆記", inkID: "zhnotes:" + chapter.id, subject: "zh")
            } else if failed {
                ContentUnavailableView {
                    Label("筆記下載失敗", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("重试") { Task { await load() } }.glassButton(prominent: true)
                }
            } else {
                ProgressView("正在下载筆記…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }
    private func load() async {
        failed = false
        if let u = MathContent.shared.local(chapter.notes), FileManager.default.fileExists(atPath: u.path) { url = u; return }
        await MathContent.shared.ensure("zhpdf-" + chapter.id)
        if let u = MathContent.shared.local(chapter.notes), FileManager.default.fileExists(atPath: u.path) { url = u } else { failed = true }
    }
}

/// Blank A4 writing pages added after a PDF's last page (count saved per document; ink saved by page index as usual).
enum PDFExtra {
    private static var applied = Set<ObjectIdentifier>()
    static func count(_ key: String) -> Int { UserDefaults.standard.integer(forKey: "pdf.extra." + key) }
    private static func blank() -> PDFKit.PDFPage? {
        let r = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = UIGraphicsPDFRenderer(bounds: r).pdfData { c in c.beginPage(); UIColor.white.setFill(); c.fill(r) }
        return PDFDocument(data: data)?.page(at: 0)
    }
    static func apply(_ doc: PDFDocument, key: String) {
        let id = ObjectIdentifier(doc)
        guard !applied.contains(id) else { return }
        applied.insert(id)
        for _ in 0..<count(key) { if let p = blank() { doc.insert(p, at: doc.pageCount) } }
    }
    static func add(_ doc: PDFDocument, key: String) {
        guard let p = blank() else { return }
        doc.insert(p, at: doc.pageCount)
        UserDefaults.standard.set(count(key) + 1, forKey: "pdf.extra." + key)
    }
}
