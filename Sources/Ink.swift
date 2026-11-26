import SwiftUI
import PDFKit
import PencilKit

// MARK: - Persistent PencilKit writing on PDF papers (local only, one drawing file per page)

enum PDFInk {
    static var root: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("pdf-ink", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func safe(_ k: String) -> String {
        String((k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k).suffix(150))
    }
    static func dir(_ key: String) -> URL { root.appendingPathComponent(safe(key), isDirectory: true) }
    static func load(_ key: String, _ page: Int) -> PKDrawing? {
        (try? Data(contentsOf: dir(key).appendingPathComponent("\(page).drawing"))).flatMap { try? PKDrawing(data: $0) }
    }
    /// Canvas width the drawing was made at (to flatten onto the page at the right scale).
    static func width(_ key: String, _ page: Int) -> CGFloat? {
        (try? String(contentsOf: dir(key).appendingPathComponent("\(page).w"), encoding: .utf8)).flatMap { Double($0) }.map { CGFloat($0) }
    }
    static func save(_ key: String, _ page: Int, _ d: PKDrawing, title: String, width: CGFloat = 0) {
        let dd = dir(key)
        let f = dd.appendingPathComponent("\(page).drawing")
        if d.strokes.isEmpty { try? FileManager.default.removeItem(at: f); return }
        try? FileManager.default.createDirectory(at: dd, withIntermediateDirectories: true)
        try? d.dataRepresentation().write(to: f, options: .atomic)
        try? Data(title.utf8).write(to: dd.appendingPathComponent("title.txt"))
        if width > 0 { try? Data("\(Double(width))".utf8).write(to: dd.appendingPathComponent("\(page).w")) }
    }
    struct Entry: Identifiable { let id: String; let title: String; let size: Int; let date: Date; let pages: Int }
    static func papers() -> [Entry] {
        let fm = FileManager.default
        let ds = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return ds.compactMap { d in
            let files = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            let ink = files.filter { $0.pathExtension == "drawing" }
            guard !ink.isEmpty else { return nil }
            var size = 0; var date = Date.distantPast
            for f in ink {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                size += v?.fileSize ?? 0; date = max(date, v?.contentModificationDate ?? .distantPast)
            }
            let title = (try? String(contentsOf: d.appendingPathComponent("title.txt"), encoding: .utf8)) ?? d.lastPathComponent
            return Entry(id: d.lastPathComponent, title: title, size: size, date: date, pages: ink.count)
        }.sorted { $0.date > $1.date }
    }
    static func delete(_ id: String) { try? FileManager.default.removeItem(at: root.appendingPathComponent(id)) }
    static func deleteAll() { try? FileManager.default.removeItem(at: root) }
}

final class InkProvider: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    var key = ""
    var title = ""
    private var canvases: [Int: PKCanvasView] = [:]
    private let picker = PKToolPicker()
    var enabled = false { didSet { canvases.values.forEach(apply) } }

    override init() {
        super.init()
        PickerRestore.observe(self) { [weak self] in
            guard let self, self.enabled, let c = self.canvases.values.first(where: { $0.window != nil }) else { return }
            self.picker.setVisible(true, forFirstResponder: c); c.becomeFirstResponder()
        }
    }

    func reset(key: String, title: String) {
        if key != self.key { canvases = [:] }
        self.key = key; self.title = title
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFKit.PDFPage) -> UIView? {
        let i = view.document?.index(for: page) ?? 0
        if let c = canvases[i] { return c }
        let c = PKCanvasView()
        c.overrideUserInterfaceStyle = .light   // PDF pages are white: keep ink colours true in dark mode
        picker.colorUserInterfaceStyle = .light
        c.backgroundColor = .clear
        c.isOpaque = false
        c.drawingPolicy = .default
        c.isScrollEnabled = false
        c.tag = i
        if let d = PDFInk.load(key, i) { c.drawing = d }
        c.delegate = self
        canvases[i] = c
        apply(c)
        return c
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFKit.PDFPage) {
        guard let c = overlayView as? PKCanvasView else { return }
        PDFInk.save(key, c.tag, c.drawing, title: title, width: c.bounds.width)
        canvases[c.tag] = nil
    }

    func canvasViewDrawingDidChange(_ c: PKCanvasView) { PDFInk.save(key, c.tag, c.drawing, title: title, width: c.bounds.width) }

    private func apply(_ c: PKCanvasView) {
        c.isUserInteractionEnabled = enabled
        picker.addObserver(c)
        picker.setVisible(enabled, forFirstResponder: c)
        if enabled { c.becomeFirstResponder() } else { c.resignFirstResponder() }
    }
}

/// Toolbar toggle for writing on the PDF.
struct InkToggle: View {
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: { Image(systemName: on ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle") }
            .accessibilityLabel("在试卷上书写")
    }
}

/// 设置 › 存储: papers with handwriting.
struct PDFInkSection: View {
    @State private var items = PDFInk.papers()
    @State private var confirmAll = false
    var body: some View {
        Section {
            if items.isEmpty { Text("还没有在试卷上写过字").foregroundStyle(.secondary) }
            ForEach(items) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title).lineLimit(1)
                    Text("\(e.pages) 页 · " + ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file) + " · " + e.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions { Button("删除", role: .destructive) { PDFInk.delete(e.id); items = PDFInk.papers() } }
            }
            if !items.isEmpty { Button("全部删除", role: .destructive) { confirmAll = true } }
        } header: { Text("试卷上的手写") } footer: {
            Text("在 PDF 试卷上写的字只保存在这台设备，完成或结算后也会保留，直到在这里删除。左滑删除单份。")
        }
        .listRowBackground(Color.cardBackground)
        .onAppear { items = PDFInk.papers() }
        .confirmationDialog("删除所有试卷上的手写？", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("全部删除", role: .destructive) { PDFInk.deleteAll(); items = [] }
        }
    }
}

/// Text fields (e.g. the DeepSeek panel) steal first responder and hide the 笔盘.
/// When the keyboard goes away, canvases whose 笔盘 was on take it back.
enum PickerRestore {
    static func observe(_ owner: AnyObject, _ f: @escaping () -> Void) {
        let t = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak owner] _ in
            guard owner != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { f() }
        }
        objc_setAssociatedObject(owner, &tokenKey, Token(t), .OBJC_ASSOCIATION_RETAIN)
    }
    private static var tokenKey: UInt8 = 0
    final class Token { let t: NSObjectProtocol; init(_ t: NSObjectProtocol) { self.t = t }; deinit { NotificationCenter.default.removeObserver(t) } }
}
