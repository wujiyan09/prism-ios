import SwiftUI
import PDFKit

/// Downloads a PDF once, caches it, and shows it natively with PDFKit.
struct PDFPage: View {
    let url: URL
    let title: String
    @Environment(\.tr) private var T
    @State private var doc: PDFDocument?
    @State private var failed = false
    @State private var pageIndex = 0

    private var file: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("papers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let name = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.lastPathComponent
        return d.appendingPathComponent(String(name.suffix(120)) + ".pdf")
    }

    var body: some View {
        Group {
            if let doc {
                PDFKitView(doc: doc, onPage: { pageIndex = $0 }).ignoresSafeArea(edges: .bottom)
            } else if failed {
                ContentUnavailableView {
                    Label(T("Couldn't load the paper", "试卷下载失败"), systemImage: "wifi.exclamationmark")
                } actions: {
                    Button(T("Try again", "重试")) { Task { await load() } }.buttonStyle(.borderedProminent)
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
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: file) { Label(T("Share", "分享"), systemImage: "square.and.arrow.up") }
                }
            }
        }
        .deepSeek(doc.map { DSContext.pdfPage($0, pageIndex, title: title, url: url) })
        .task { await load() }
    }

    private func load() async {
        failed = false
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
    final class Coord: NSObject {
        var onPage: ((Int) -> Void)?
        @objc func changed(_ n: Notification) {
            guard let v = n.object as? PDFView, let p = v.currentPage, let d = v.document else { return }
            let i = d.index(for: p)
            DispatchQueue.main.async { self.onPage?(i) }
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
        v.document = doc
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {
        if v.document !== doc { v.document = doc }
    }
}
