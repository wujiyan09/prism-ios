import os
import SwiftUI
import PDFKit
import UIKit

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
    /// Decoded drawings in memory (filled by background preload and by every save), so turning to a page never
    /// waits for disk, JSON / PencilKit decoding, or a save in progress on the main thread.
    final class Box { let d: InkDrawing?; init(_ d: InkDrawing?) { self.d = d } }
    static let mem: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 600; return c }()
    static let log = OSLog(subsystem: "com.wujiyan09.prism", category: .pointsOfInterest)
    static func load(_ key: String, _ page: Int) -> InkDrawing? {
        let f = dir(key).appendingPathComponent("\(page).drawing")
        if let b = mem.object(forKey: f.path as NSString) { return b.d }
        let sid = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "ink.load", signpostID: sid, "%{public}s p%d main=%d", key, page, Thread.isMainThread ? 1 : 0)
        let d = (try? Data(contentsOf: f)).flatMap { try? InkDrawing(data: $0) }
        os_signpost(.end, log: log, name: "ink.load", signpostID: sid, "%d strokes", d?.strokes.count ?? 0)
        mem.setObject(Box(d), forKey: f.path as NSString)
        return d
    }
    /// Cheap "has ink" check (no decoding).
    static func exists(_ key: String, _ page: Int) -> Bool {
        let f = dir(key).appendingPathComponent("\(page).drawing")
        if let b = mem.object(forKey: f.path as NSString) { return !(b.d?.strokes.isEmpty ?? true) }
        return FileManager.default.fileExists(atPath: f.path)
    }
    /// Canvas width the drawing was made at (to flatten onto the page at the right scale).
    static func width(_ key: String, _ page: Int) -> CGFloat? {
        (try? String(contentsOf: dir(key).appendingPathComponent("\(page).w"), encoding: .utf8)).flatMap { Double($0) }.map { CGFloat($0) }
    }
    /// Saves one page's ink. Data-safety rules (after a whole note's ink vanished):
    /// - an empty drawing never replaces a non-empty file unless `erased` (the user really erased everything on this canvas);
    /// - even then the old file is kept as `<page>.drawing.bak1`, not deleted;
    /// - before overwriting, the previous version is rotated into .bak1…bak3 (at most once every 5 minutes);
    /// - a save that would drop most of the strokes at once is refused unless `erased`.
    static func save(_ key: String, _ page: Int, _ d: InkDrawing, title: String, width: CGFloat = 0, erased: Bool = false) {
        let dd = dir(key)
        let f = dd.appendingPathComponent("\(page).drawing")
        let fm = FileManager.default
        let old = fm.fileExists(atPath: f.path) ? (try? Data(contentsOf: f)).flatMap { try? InkDrawing(data: $0) } : nil
        let oldCount = old?.strokes.count ?? 0
        if d.strokes.isEmpty {
            guard oldCount > 0 else { return }
            guard erased else { NSLog("PDFInk: refused to save empty drawing over \(oldCount) strokes (\(key) p\(page))"); return }
            backup(f, force: true)
            try? fm.removeItem(at: f); mem.setObject(Box(nil), forKey: f.path as NSString); return
        }
        if !erased, oldCount >= 10, d.strokes.count * 4 < oldCount {
            NSLog("PDFInk: refused save dropping \(oldCount) -> \(d.strokes.count) strokes (\(key) p\(page))"); return
        }
        try? fm.createDirectory(at: dd, withIntermediateDirectories: true)
        if oldCount > 0 { backup(f, force: d.strokes.count < oldCount) }
        // First write over an old PencilKit file: keep the original untouched as <page>.drawing.pk (read-only conversion).
        let pk = dd.appendingPathComponent("\(page).drawing.pk")
        if !fm.fileExists(atPath: pk.path), let h = try? FileHandle(forReadingFrom: f) {
            let first = (try? h.read(upToCount: 1)) ?? Data(); try? h.close()
            if let c = first.first, c != UInt8(ascii: "{") { try? fm.copyItem(at: f, to: pk) }
        }
        try? d.dataRepresentation().write(to: f, options: .atomic)
        mem.setObject(Box(d), forKey: f.path as NSString)
        try? Data(title.utf8).write(to: dd.appendingPathComponent("title.txt"))
        if width > 0 { try? Data("\(Double(width))".utf8).write(to: dd.appendingPathComponent("\(page).w")) }
    }
    /// Writes happen here, one at a time, never on the main thread (InkDrawing is a value: safe to encode off-main).
    static let saveQ = DispatchQueue(label: "pdfink.save", qos: .utility)
    static let loadQ = DispatchQueue(label: "pdfink.load", qos: .userInitiated, attributes: .concurrent)
    static func saveAsync(_ key: String, _ page: Int, _ d: InkDrawing, title: String, width: CGFloat = 0, erased: Bool = false) {
        // The latest drawing is what a reload must see, even before the write lands (no waiting on saveQ).
        if !d.strokes.isEmpty || erased { mem.setObject(Box(d.strokes.isEmpty ? nil : d), forKey: dir(key).appendingPathComponent("\(page).drawing").path as NSString) }
        saveQ.async {
            let sid = OSSignpostID(log: log)
            os_signpost(.begin, log: log, name: "ink.save", signpostID: sid, "%{public}s p%d", key, page)
            save(key, page, d, title: title, width: width, erased: erased)
            os_signpost(.end, log: log, name: "ink.save", signpostID: sid)
        }
    }
    /// Rolling local copies of an ink file: .bak1 (newest) … .bak3.
    static func backup(_ f: URL, force: Bool) {
        let fm = FileManager.default
        func b(_ n: Int) -> URL { f.deletingLastPathComponent().appendingPathComponent(f.lastPathComponent + ".bak\(n)") }
        if !force, let m = (try? b(1).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, Date().timeIntervalSince(m) < 300 { return }
        try? fm.removeItem(at: b(3))
        try? fm.moveItem(at: b(2), to: b(3))
        try? fm.moveItem(at: b(1), to: b(2))
        try? fm.copyItem(at: f, to: b(1))
    }
    /// Newest backup of a page with strokes (for recovery).
    static func latestBackup(_ key: String, _ page: Int) -> InkDrawing? {
        for n in 1...3 {
            let u = dir(key).appendingPathComponent("\(page).drawing.bak\(n)")
            if let d = (try? Data(contentsOf: u)).flatMap({ try? InkDrawing(data: $0) }), !d.strokes.isEmpty { return d }
        }
        return nil
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

final class InkProvider: NSObject, PDFPageOverlayViewProvider, InkCanvasDelegate {
    var key = ""
    /// Notes shown as a PDF: page i's ink lives under its own note key (page 0), pad channel "note:<key>".
    /// The display PDF's pages are NoteRender.logicalWidth wide, so ink coordinates are the same as before.
    var noteKeys: [String]? = nil
    /// Note pages shown with writable margins (logical units, page = NoteRender.logicalWidth): the stored ink stays in
    /// the note's own coordinates; it is shifted right by `l` for display and back when saved (files never migrated).
    var noteMargin: (l: CGFloat, r: CGFloat) = (0, 0)
    private func shiftK(_ c: InkCanvas) -> CGFloat {
        let full = NoteRender.logicalWidth + noteMargin.l + noteMargin.r
        return max(1, c.bounds.width) / full
    }
    private func store(_ i: Int) -> (String, Int) { if let n = noteKeys, n.indices.contains(i) { return (n[i], 0) }; return (key, i) }
    private func channel(_ i: Int) -> String { if let n = noteKeys, n.indices.contains(i) { return "note:" + n[i] }; return "pdf:\(key):\(i)" }
    var title = ""
    private var canvases: [Int: InkCanvas] = [:]
    private var links: [Int: PadLink] = [:]
    private lazy var flushObs: NSObjectProtocol = NotificationCenter.default.addObserver(forName: .noteInkFlush, object: nil, queue: .main) { [weak self] _ in self?.flushAll() }
    /// Pages written on since their last save; saved debounced, off-main. Untouched pages are never rewritten.
    private var dirty: Set<Int> = []
    private var pending: [Int: DispatchWorkItem] = [:]
    private func flush(_ c: InkCanvas) {
        pending[c.tag]?.cancel(); pending[c.tag] = nil
        guard dirty.remove(c.tag) != nil else { return }
        let (k, p) = store(c.tag)
        if noteKeys != nil, noteMargin.l + noteMargin.r > 0 {
            let f = shiftK(c)
            PDFInk.saveAsync(k, p, c.drawing.transformed(using: CGAffineTransform(translationX: -noteMargin.l * f, y: 0)), title: title,
                             width: c.bounds.width - (noteMargin.l + noteMargin.r) * f, erased: true)
            return
        }
        PDFInk.saveAsync(k, p, c.drawing, title: title, width: c.bounds.width, erased: true)
    }
    func flushAll() { canvases.values.forEach(flush) }
    deinit { flushAll(); ToolSync.shared.unregister(picker) }
    private let picker: InkToolPicker = { let p = ToolSync.makePicker(); ToolSync.shared.register(p); return p }()
    var enabled = false {
        didSet {
            canvases.values.forEach(apply)
            guard enabled, !oldValue else { return }
            // Turned on from the toolbar: always show the full palette (out of the corner disc) and make sure a visible
            // page's canvas owns it, retrying once if the page's canvas wasn't in the window yet.
            if InkPaletteHost.corner != nil { InkPaletteHost.expand(in: canvases.values.first(where: { $0.window != nil })?.window) }
            for delay in [0.05, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.enabled, !self.canvases.values.contains(where: { $0.isFirstResponder }) else { return }
                    if let c = self.canvases.values.filter({ $0.window != nil }).min(by: { abs($0.convert($0.bounds, to: nil).midY - 400) < abs($1.convert($1.bounds, to: nil).midY - 400) }) {
                        self.picker.setVisible(true, forFirstResponder: c); _ = c.becomeFirstResponder()
                    }
                }
            }
        }
    }

    override init() {
        super.init()
        PickerRestore.observe(self) { [weak self] in
            guard let self, self.enabled, let c = self.canvases.values.first(where: { $0.window != nil }) else { return }
            guard !DSInput.holding else { return }
            self.picker.setVisible(true, forFirstResponder: c); c.becomeFirstResponder()
        }
    }

    /// Pages changed size (margins): rebuild every overlay.
    func reload() { canvases = [:]; links.values.forEach { $0.tearDown() }; links = [:] }

    func reset(key: String, title: String) {
        if key != self.key { flushAll(); canvases = [:]; links.values.forEach { $0.tearDown() }; links = [:]; dirty = [] }
        self.key = key; self.title = title
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFKit.PDFPage) -> UIView? {
        let i = view.document?.index(for: page) ?? 0
        if let c = canvases[i] { return c }
        let c = QuietCanvas()
        c.overrideUserInterfaceStyle = .light   // PDF pages are white: keep ink colours true in dark mode
        picker.colorUserInterfaceStyle = .light
        picker.overrideUserInterfaceStyle = .light
        c.backgroundColor = .clear
        c.isOpaque = false
        c.drawingPolicy = .default
        c.isScrollEnabled = false
        c.tag = i
        if let d = PDFInk.load(store(i).0, store(i).1) {
            if noteKeys != nil, noteMargin.l > 0 {
                // Page is NoteRender.logicalWidth + margins wide in page units; stored ink is in note units (no margins).
                let full = NoteRender.logicalWidth + noteMargin.l + noteMargin.r
                let f = page.bounds(for: .mediaBox).width / full
                c.drawing = d.transformed(using: CGAffineTransform(translationX: noteMargin.l * f, y: 0))
            } else { c.drawing = d }
        }
        c.delegate = self
        canvases[i] = c
        _ = flushObs
        let pw = page.bounds(for: .mediaBox).width
        let link = PadLink(channel(i), canvas: c)
        link.host = { [weak c] in c?.inkView.layer }
        link.k = { [weak c] in max(1, c?.bounds.width ?? pw) / max(1, pw) }
        links[i] = link
        apply(c)
        return c
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFKit.PDFPage) {
        guard let c = overlayView as? InkCanvas else { return }
        flush(c)
        canvases[c.tag] = nil
        links[c.tag]?.tearDown(); links[c.tag] = nil
    }

    func canvasViewDrawingDidChange(_ c: InkCanvas) {
        links[c.tag]?.changed(c.drawing)
        dirty.insert(c.tag)
        pending[c.tag]?.cancel()
        let w = DispatchWorkItem { [weak self, weak c] in if let self, let c { self.flush(c) } }
        pending[c.tag] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    private func apply(_ c: InkCanvas) {
        c.isUserInteractionEnabled = enabled
        picker.addObserver(c)
        picker.setVisible(enabled, forFirstResponder: c)
        if enabled { if !DSInput.holding { c.becomeFirstResponder() } } else { c.resignFirstResponder() }
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


// MARK: - Manual left/right margins on PDFs (blank writable paper beside the page). Saved per document.

enum PDFMargins {
    static let steps: [CGFloat] = [0, 40, 80, 120, 160, 240]
    private static var originals: [ObjectIdentifier: CGRect] = [:]
    static func get(_ key: String) -> (l: CGFloat, r: CGFloat) {
        let a = UserDefaults.standard.array(forKey: "pdf.margins." + key) as? [Double] ?? []
        return a.count == 2 ? (CGFloat(a[0]), CGFloat(a[1])) : (0, 0)
    }
    private static func base(_ p: PDFKit.PDFPage) -> CGRect {
        let id = ObjectIdentifier(p)
        if let r = originals[id] { return r }
        let r = p.bounds(for: .mediaBox); originals[id] = r; return r
    }
    /// Widen every page's boxes by the saved margins (the PDF file itself is untouched).
    static func apply(_ doc: PDFDocument, key: String) {
        let m = get(key)
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            let b = base(p)
            let r = CGRect(x: b.minX - m.l, y: b.minY, width: b.width + m.l + m.r, height: b.height)
            p.setBounds(r, for: .mediaBox); p.setBounds(r, for: .cropBox)
        }
    }
    /// Change margins: existing ink moves with the page so it stays where it was written.
    static func set(_ key: String, l: CGFloat, r: CGFloat, doc: PDFDocument, title: String) {
        let old = get(key)
        let dx = l - old.l
        UserDefaults.standard.set([Double(l), Double(r)], forKey: "pdf.margins." + key)
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            let w = base(p).width + l + r
            if let d = PDFInk.load(key, i) {
                let ow = PDFInk.width(key, i) ?? (base(p).width + old.l + old.r)
                let k = ow / max(1, base(p).width + old.l + old.r)   // canvas units per page point
                PDFInk.save(key, i, d.transformed(using: CGAffineTransform(translationX: dx * k, y: 0)), title: title, width: w * k)
            }
        }
        apply(doc, key: key)
    }
}


/// One-time full copy of the app's data before the new ink format is first used (Sam's data must survive the upgrade).
enum DataMigration {
    static func backupOnce() {
        let k = "migr.inkv1.backup"
        guard !UserDefaults.standard.bool(forKey: k) else { return }
        let fm = FileManager.default
        let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dest = lib.appendingPathComponent(AppBrand.name + " 升级前备份 " + f.string(from: Date()), isDirectory: true)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for d in [fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], fm.urls(for: .documentDirectory, in: .userDomainMask)[0]] where fm.fileExists(atPath: d.path) {
                try fm.copyItem(at: d, to: dest.appendingPathComponent(d.lastPathComponent))
            }
            if let prefs = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") {
                (prefs as NSDictionary).write(to: dest.appendingPathComponent("settings.plist"), atomically: true)
            }
            UserDefaults.standard.set(true, forKey: k)
        } catch { NSLog("DataMigration backup failed: \(error)") }   // not marked done: retried next launch
    }
}
