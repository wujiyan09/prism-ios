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
        /// Main window follows the pad's page.
        @objc func padPage(_ n: Notification) {
            guard (n.object as? String) == owner, let i = n.userInfo?["i"] as? Int, let v = view, let p = v.document?.page(at: i) else { return }
            v.go(to: p)
        }
    }
    func makeCoordinator() -> Coord { Coord() }
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        context.coordinator.onPage = onPage
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coord.changed(_:)), name: .PDFViewPageChanged, object: v)
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = UIColor(Color.appBackground)
        if let ink {
            ink.reset(key: inkKey, title: inkTitle)
            v.pageOverlayViewProvider = ink
            v.isInMarkupMode = true
            let src = PadSources.pdf(doc, key: inkKey, title: inkTitle)
            context.coordinator.owner = src.owner
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
