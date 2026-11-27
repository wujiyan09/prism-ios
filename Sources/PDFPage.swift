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
    @State private var ink = InkProvider()
    @State private var inkOn = false
    @State private var vctl = ViewCtl()

    private var file: URL {
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
                    ShareLink(item: file) { Label(T("Share", "分享"), systemImage: "square.and.arrow.up") }
                }
            }
        }
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

struct PDFKitView: UIViewRepresentable {
    let doc: PDFDocument
    var onPage: ((Int) -> Void)? = nil
    var ink: InkProvider? = nil
    var inkKey = ""
    var inkTitle = ""
    var ctl: ViewCtl? = nil
    final class Coord: NSObject {
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
            PadHub.shared.setIndex(owner, i)
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
        var kvo: NSKeyValueObservation?
        var vpObs: NSObjectProtocol?
        /// Pad moved within a page: show the same rect.
        func padMoved(_ ch: String, _ r: CGRect) {
            guard Date().timeIntervalSince(userMoved) > 0.6 else { return }   // user is moving the big screen: don't snap it back
            guard PadHub.shared.mainFollows, let v = view, let d = v.document, ch.hasPrefix("pdf:\(inkKey):"),
                  let i = Int(ch.split(separator: ":").last ?? ""), let p = d.page(at: i) else { return }
            PadHub.shared.mainApplied = Date()
            let b = p.bounds(for: .mediaBox)
            if PadHub.syncZoom, r.width > 1, v.bounds.width > 1 {
                v.scaleFactor = min(v.maxScaleFactor, max(v.minScaleFactor, v.bounds.width / r.width))
            }
            v.go(to: CGRect(x: b.minX + r.minX, y: b.maxY - r.minY - 1, width: 1, height: 1), on: p)
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
            NotificationCenter.default.post(name: .mainViewport, object: "pdf:\(inkKey):\(d.index(for: p))", userInfo: ["r": top])
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
        let v = PDFView()
        context.coordinator.onPage = onPage
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coord.changed(_:)), name: .PDFViewPageChanged, object: v)
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = UIColor(Color.appBackground)
        if let ink {
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
                co?.kvo = sv.observe(\.contentOffset, options: [.new]) { _, _ in DispatchQueue.main.async { co?.mainScrolled(); co?.updateAdd() } }
                co?.updateAdd()
            }
            NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coord.padPage(_:)), name: .padPage, object: nil)
            PadHub.shared.activate(src)
        }
        context.coordinator.view = v
        v.document = doc
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
        if !coordinator.owner.isEmpty { PadHub.shared.deactivate(coordinator.owner) }
    }
    func updateUIView(_ v: PDFView, context: Context) {
        if v.document !== doc { v.document = doc }
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
