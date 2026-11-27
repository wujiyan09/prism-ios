import SwiftUI
import PDFKit
import PencilKit
import PhotosUI
import VisionKit
import UniformTypeIdentifiers

// MARK: - 导入的试卷: imported papers (PDF / photos / scans), one local library, manual delete only.

struct ImpQ: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var page: Int
    var n: String
    var text: String
    var options: [String] = []
    var marks: Int? = nil
    var box: [Double]? = nil        // figure crop on the page image, 0–1 (x, y, w, h), top-left origin
    var answer: String? = nil       // from the marking scheme (MC letter / final answer)
    var scheme: String? = nil
    var isMC: Bool { options.count >= 2 }
}

struct ImpPaper: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var subject: String
    var chapters: [String] = []
    var created: Double
    var mode = "ink"                // ink | cards
    var qs: [ImpQ] = []
    var parsedPages: [Int] = []
    var msParsed: [Int] = []
    var mc: [String: Int] = [:]
    var typed: [String: String] = [:]
    var hand: [String: Bool] = [:]
    var submitted = false
    var settled = false
    var score: Int? = nil
    var total: Int? = nil
    var manualScore: Int? = nil
    var manualTotal: Int? = nil
    var hasMS = false
}

/// Synced summary (files stay on the device).
struct ImpSummary: Codable, Hashable { var id: String; var name: String; var subject: String; var created: Double; var score: Int?; var total: Int?; var settled: Bool }

@Observable
final class ImportStore {
    static let shared = ImportStore()
    var papers: [String: ImpPaper] = [:]
    var remote: [String: ImpSummary] = [:]

    static var root: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    static func paperURL(_ id: String) -> URL { dir(id).appendingPathComponent("paper.pdf") }
    static func msURL(_ id: String) -> URL { dir(id).appendingPathComponent("ms.pdf") }

    init() {
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? [] {
            if let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")), let p = try? JSONDecoder().decode(ImpPaper.self, from: data) { papers[p.id] = p }
        }
        if let d = UserDefaults.standard.data(forKey: "imp.remote"), let r = try? JSONDecoder().decode([String: ImpSummary].self, from: d) { remote = r }
    }
    var sorted: [ImpPaper] { papers.values.sorted { $0.created > $1.created } }

    func save(_ p: ImpPaper) {
        papers[p.id] = p
        try? FileManager.default.createDirectory(at: Self.dir(p.id), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(p) { try? d.write(to: Self.dir(p.id).appendingPathComponent("meta.json"), options: .atomic) }
    }
    func create(name: String, subject: String, chapters: [String], pdf: PDFDocument) -> ImpPaper {
        let p = ImpPaper(id: UUID().uuidString, name: name, subject: subject, chapters: chapters, created: Date().timeIntervalSince1970)
        try? FileManager.default.createDirectory(at: Self.dir(p.id), withIntermediateDirectories: true)
        pdf.write(to: Self.paperURL(p.id))
        save(p)
        Task { await SyncManager.shared.sync() }
        return p
    }
    func setMS(_ id: String, _ pdf: PDFDocument) {
        pdf.write(to: Self.msURL(id))
        if var p = papers[id] { p.hasMS = true; p.msParsed = []; save(p) }
    }
    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: Self.dir(id))
        for k in ["imp:" + id, "imp:" + id + "-ms"] { try? FileManager.default.removeItem(at: PDFInk.dir(k)) }
        papers[id] = nil
        remote[id] = nil
        saveRemote()
    }
    func size(_ id: String) -> Int {
        let fm = FileManager.default
        var n = 0
        for d in [Self.dir(id), PDFInk.dir("imp:" + id), PDFInk.dir("imp:" + id + "-ms")] {
            for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                n += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return n
    }
    func doc(_ id: String) -> PDFDocument? { PDFDocument(url: Self.paperURL(id)) }
    func ms(_ id: String) -> PDFDocument? { PDFDocument(url: Self.msURL(id)) }

    // Sync: summaries only.
    func collect() -> [String: String] {
        var o: [String: String] = [:]
        for p in papers.values {
            let s = ImpSummary(id: p.id, name: p.name, subject: p.subject, created: p.created, score: p.score, total: p.total, settled: p.settled)
            if let d = try? JSONEncoder().encode(s), let t = String(data: d, encoding: .utf8) { o["imp/" + p.id] = t }
        }
        return o
    }
    func apply(_ id: String, _ v: String?, deleted: Bool) {
        // Remote deletes never remove local files.
        if deleted { remote[id] = nil; saveRemote(); return }
        guard let v, let s = try? JSONDecoder().decode(ImpSummary.self, from: Data(v.utf8)) else { return }
        if var p = papers[id] {
            if p.name != s.name || p.score != s.score || p.total != s.total || p.settled != s.settled {
                p.name = s.name; p.score = s.score; p.total = s.total; p.settled = s.settled; save(p)
            }
        } else { remote[id] = s; saveRemote() }
    }
    private func saveRemote() { if let d = try? JSONEncoder().encode(remote) { UserDefaults.standard.set(d, forKey: "imp.remote") } }
}

// MARK: - Building PDFs from picks

enum ImpPDF {
    static func from(images: [UIImage]) -> PDFDocument {
        let d = PDFDocument()
        for im in images { if let p = PDFKit.PDFPage(image: im) { d.insert(p, at: d.pageCount) } }
        return d
    }
    static func pageImage(_ d: PDFDocument, _ i: Int, width: CGFloat = 1400) -> UIImage? {
        guard let p = d.page(at: i) else { return nil }
        let b = p.bounds(for: .mediaBox)
        let h = width * b.height / max(1, b.width)
        return p.thumbnail(of: CGSize(width: width, height: h), for: .mediaBox)
    }
    static func crop(_ im: UIImage, _ box: [Double]?) -> UIImage? {
        guard let box, box.count == 4, let cg = im.cgImage else { return nil }
        let W = Double(cg.width), H = Double(cg.height)
        let r = CGRect(x: box[0] * W, y: box[1] * H, width: box[2] * W, height: box[3] * H).integral
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard r.width > 8, r.height > 8, let c = cg.cropping(to: r) else { return nil }
        return UIImage(cgImage: c)
    }
}

// MARK: - DeepSeek parsing (page by page, cached in the paper)

enum ImpParse {
    static let perPage = 0.0013   // US$ estimate per page with flash (image + JSON out)

    static func questions(page: UIImage, text: String, index: Int, count: Int) async throws -> [ImpQ] {
        let prompt = """
        这是一份试卷的第 \(index + 1) 页（共 \(count) 页）。把这一页上的题目逐题拆出来。只输出 JSON：
        {"questions":[{"n":"题号，例如 1 或 3(a)","text":"题目全文，数学一律用 $...$ LaTeX，保留换行","options":["A 选项文字","B 选项文字"] 或 [],"marks":分数或 null,"figure":[x,y,w,h] 或 null}]}
        options 只放选择题选项的文字（不要字母）。figure 是这题附图在页面图片中的位置，用 0–1 比例，左上角为原点；没有附图写 null。
        如果一题是从上一页延续的，n 写成 "续" 加题号。这一页没有题目就输出 {"questions":[]}。JSON 字符串里的反斜杠要写成两个。
        \(text.isEmpty ? "" : "\n页面文字层（可能不完整，仅供参考）：\n" + String(text.prefix(4000)))
        """
        let s = try await DSClient.complete([DSClient.message("user", DSPart(text: prompt, images: [page]), vision: true)], model: .flash, json: true)
        guard let o = DSJSON.object(s), let arr = o["questions"] as? [[String: Any]] else { throw DSError.server(200, "第 \(index + 1) 页解析失败") }
        return arr.map { q in
            var x = ImpQ(page: index, n: "\(q["n"] ?? "")", text: q["text"] as? String ?? "")
            x.options = (q["options"] as? [Any] ?? []).map { "\($0)" }
            x.marks = (q["marks"] as? NSNumber)?.intValue
            x.box = (q["figure"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
            if x.box?.count != 4 { x.box = nil }
            return x
        }
    }

    static func scheme(page: UIImage, text: String, index: Int, numbers: [String]) async throws -> [(String, String, String)] {
        let prompt = """
        这是这份试卷评分标准（或答案）的第 \(index + 1) 页。试卷题号：\(numbers.joined(separator: "、"))。
        只输出 JSON：{"items":[{"n":"题号（跟试卷题号一致）","answer":"选择题写字母；其他写最终答案","scheme":"这题评分标准全文，保留每行分数如 1M、1A、(2)；数学用 $...$"}]}
        这一页没有内容就输出 {"items":[]}。JSON 字符串里的反斜杠要写成两个。
        \(text.isEmpty ? "" : "\n页面文字层：\n" + String(text.prefix(5000)))
        """
        let s = try await DSClient.complete([DSClient.message("user", DSPart(text: prompt, images: [page]), vision: true)], model: .flash, json: true)
        guard let o = DSJSON.object(s), let arr = o["items"] as? [[String: Any]] else { throw DSError.server(200, "评分标准第 \(index + 1) 页解析失败") }
        return arr.map { ("\($0["n"] ?? "")", $0["answer"] as? String ?? "", $0["scheme"] as? String ?? "") }
    }

    static func norm(_ n: String) -> String {
        n.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "q", with: "").replacingOccurrences(of: "续", with: "")
    }

    /// Adds a page's questions, joining "续" continuations onto the previous question.
    static func merge(_ qs: inout [ImpQ], _ new: [ImpQ]) {
        for q in new {
            if q.n.hasPrefix("续"), let i = qs.lastIndex(where: { norm($0.n) == norm(q.n) }) ?? (qs.isEmpty ? nil : qs.count - 1) {
                qs[i].text += "\n" + q.text
                if qs[i].options.isEmpty { qs[i].options = q.options }
            } else { qs.append(q) }
        }
    }
}

// MARK: - Library

struct ImportLibraryView: View {
    @State private var store = ImportStore.shared
    @State private var selection = Set<String>()
    @State private var edit: EditMode = .inactive
    @State private var confirm: [String] = []
    @State private var picker: ImportSource?
    @State private var pending: PendingDoc?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var error: String?

    var body: some View {
        List(selection: $selection) {
            if store.papers.isEmpty {
                ContentUnavailableView("还没有导入的试卷", systemImage: "square.and.arrow.down", description: Text("右上角 + 可以从文件、照片导入，或直接扫描纸本试卷。"))
                    .listRowBackground(Color.clear)
            }
            ForEach(store.sorted) { p in
                NavigationLink { ImportPaperView(id: p.id) } label: { row(p) }
                    .tag(p.id)
                    .swipeActions { Button("删除", role: .destructive) { confirm = [p.id] } }
            }
            .listRowBackground(Color.cardBackground)
            if !store.remote.isEmpty {
                Section {
                    ForEach(Array(store.remote.values).sorted { $0.created > $1.created }, id: \.id) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name)
                            Text(scoreText(s.score, s.total) + " · 文件在其他设备上").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("其他设备") }
                .listRowBackground(Color.cardBackground)
            }
        }
        .environment(\.editMode, $edit)
        .appList()
        .navigationTitle("导入的试卷")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { picker = .files } label: { Label("从文件（PDF / 图片）", systemImage: "folder") }
                    Button { picker = .photos } label: { Label("从照片", systemImage: "photo.on.rectangle") }
                    if VNDocumentCameraViewController.isSupported {
                        Button { picker = .scan } label: { Label("扫描纸本", systemImage: "doc.viewfinder") }
                    }
                } label: { Image(systemName: "plus") }
            }
            if edit == .active {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { withAnimation { edit = .inactive; selection = [] } }.bold() }
            } else {
                ToolbarItem(placement: .primaryAction) { Button("选择") { withAnimation { edit = .active; selection = [] } }.foregroundStyle(.primary) }
            }
            if edit == .active && !selection.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button("删除 \(selection.count) 份", role: .destructive) { confirm = Array(selection) }
                }
            }
        }
        .confirmationDialog("删除 \(confirm.count) 份试卷？试卷、评分标准、手写和答题记录都会从这台设备删除。", isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = [] } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { confirm.forEach { store.delete($0) }; confirm = []; selection = [] }
        }
        .importPickers(source: $picker, photos: $photoItems) { doc, err in
            if let doc { pending = PendingDoc(doc: doc) } else if let err { error = err }
        }
        .sheet(item: $pending) { p in
            NavigationStack { ImportNewSheet(doc: p.doc) { pending = nil } }
        }
        .alert("导入失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {} message: { Text(error ?? "") }
    }

    private func row(_ p: ImpPaper) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(p.name).font(.headline)
            HStack(spacing: 6) {
                Text(DSContext.subjectName(p.subject))
                Text("·")
                Text(Date(timeIntervalSince1970: p.created).formatted(date: .abbreviated, time: .omitted))
                if p.hasMS { Text("· 有评分标准") }
                if !p.qs.isEmpty { Text("· \(p.qs.count) 题") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if p.settled { Text(scoreText(p.score, p.total)).font(.caption.bold()).foregroundStyle(Color.accentColor) }
            else if p.submitted { Text("已交卷，待评分").font(.caption.bold()).foregroundStyle(.orange) }
        }
    }
}

func scoreText(_ s: Int?, _ t: Int?) -> String {
    guard let s else { return "未评分" }
    return (t ?? 0) > 0 ? "得分 \(s)/\(t!)" : "得分 \(s)"
}

struct PendingDoc: Identifiable { let id = UUID(); let doc: PDFDocument }
enum ImportSource: String, Identifiable { case files, photos, scan; var id: String { rawValue } }

extension View {
    /// Files / Photos / document-camera pickers that hand back one PDF (images become pages). `.prismpaper` bundles restore directly.
    func importPickers(source: Binding<ImportSource?>, photos: Binding<[PhotosPickerItem]>, done: @escaping (PDFDocument?, String?) -> Void) -> some View {
        modifier(ImportPickers(source: source, photos: photos, done: done))
    }
}

struct ImportPickers: ViewModifier {
    @Binding var source: ImportSource?
    @Binding var photos: [PhotosPickerItem]
    let done: (PDFDocument?, String?) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: source) { _, s in
                guard s == .files else { return }
                source = nil
                FilePick.open { urls in handle(urls) }
            }
            .photosPicker(isPresented: Binding(get: { source == .photos }, set: { if !$0 { source = nil } }), selection: $photos, matching: .images)
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    var ims: [UIImage] = []
                    for it in items { if let d = try? await it.loadTransferable(type: Data.self), let im = UIImage(data: d) { ims.append(im) } }
                    photos = []
                    let d = ims.isEmpty ? nil : ImpPDF.from(images: ims)
                    try? await Task.sleep(for: .milliseconds(600))   // let the picker finish dismissing
                    done(d, ims.isEmpty ? "没有读到图片" : nil)
                }
            }
            .fullScreenCover(isPresented: Binding(get: { source == .scan }, set: { if !$0 { source = nil } })) {
                DocScanner { ims in source = nil; if !ims.isEmpty { done(ImpPDF.from(images: ims), nil) } }.ignoresSafeArea()
            }
    }

    private func handle(_ urls: [URL]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ImportPickers.read(urls, done) }
    }

    static func read(_ urls: [URL], _ done: (PDFDocument?, String?) -> Void) {
        var ims: [UIImage] = []
        let out = PDFDocument()
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            if u.pathExtension.lowercased() == "prismpaper" {
                if let d = try? Data(contentsOf: u), ImpBundle.restore(d) != nil || NoteBundle.restore(d) != nil { done(nil, nil) } else { done(nil, "这个导出包无法读取") }
                return
            }
            guard let data = try? Data(contentsOf: u) else { continue }
            if let d = PDFDocument(data: data) {
                for i in 0..<d.pageCount { if let p = d.page(at: i) { out.insert(p, at: out.pageCount) } }
            } else if let im = UIImage(data: data) { ims.append(im) }
        }
        for im in ims { if let p = PDFKit.PDFPage(image: im) { out.insert(p, at: out.pageCount) } }
        // Original filename (no extension) travels with the document; used as the name, no naming dialog.
        if let u = urls.first(where: { $0.pathExtension.lowercased() != "prismpaper" }) {
            var a = out.documentAttributes ?? [:]; a[PDFDocumentAttribute.titleAttribute] = u.deletingPathExtension().lastPathComponent; out.documentAttributes = a
        }
        done(out.pageCount > 0 ? out : nil, out.pageCount > 0 ? nil : "没有可以导入的 PDF 或图片")
    }
}

struct DocScanner: UIViewControllerRepresentable {
    let done: ([UIImage]) -> Void
    func makeCoordinator() -> Coord { Coord(done) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let v = VNDocumentCameraViewController(); v.delegate = context.coordinator; return v
    }
    func updateUIViewController(_ v: VNDocumentCameraViewController, context: Context) {}
    final class Coord: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: ([UIImage]) -> Void
        init(_ d: @escaping ([UIImage]) -> Void) { done = d }
        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            done((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }
        func documentCameraViewControllerDidCancel(_ c: VNDocumentCameraViewController) { done([]) }
        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFailWithError error: Error) { done([]) }
    }
}

struct ImportNewSheet: View {
    let doc: PDFDocument
    let close: () -> Void
    @State private var name = "导入的试卷 " + Date().formatted(date: .numeric, time: .omitted)
    @State private var subject = "math"
    private var fileName: String? { (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    @State private var chapters: [String] = []

    private var options: [(String, String)] {
        switch subject {
        case "ict": return Library.shared.chapters.map { ($0.id, $0.name) }
        case "math": return MathLibrary.shared.chapters("math").map { ($0.id, $0.label) }
        case "zh": return MathLibrary.shared.chapters("zh").map { ($0.id, $0.t) }
        case "chem": return MathLibrary.shared.chapters("chem").map { ($0.id, $0.label) }
        default: return []
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("名称", value: name)
                LabeledContent("页数", value: "\(doc.pageCount)")
                Picker("科目", selection: $subject) {
                    Text("Mathematics").tag("math"); Text("M2").tag("m2"); Text("ICT").tag("ict"); Text("Physics").tag("phy")
                    Text("Chemistry").tag("chem"); Text("中文").tag("zh"); Text("其他").tag("other")
                }
                .onChange(of: subject) { _, _ in chapters = [] }
            }
            .listRowBackground(Color.cardBackground)
            .onAppear { if let f = fileName { name = f } }
            if !options.isEmpty {
                Section {
                    ForEach(options, id: \.0) { o in
                        Toggle(o.1, isOn: Binding(get: { chapters.contains(o.0) }, set: { on in
                            chapters.removeAll { $0 == o.0 }; if on { chapters.append(o.0) }
                        }))
                    }
                } header: { Text("章节（可选）") } footer: { Text("选了章节，DeepSeek 会附上本章内容。") }
                .listRowBackground(Color.cardBackground)
            }
        }
        .appList()
        .navigationTitle("导入试卷")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { close() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("导入") { _ = ImportStore.shared.create(name: name.isEmpty ? "导入的试卷" : name, subject: subject, chapters: chapters, pdf: doc); close() }.bold()
            }
        }
    }
}

// MARK: - Paper screen

struct ImportPaperView: View {
    let id: String
    @State private var store = ImportStore.shared
    @AppStorage("math.split.on") private var splitOn = true
    @State private var doc: PDFDocument?
    @State private var ms: PDFDocument?
    @State private var ink = InkProvider()
    @State private var msInk = InkProvider()
    @State private var inkOn = false
    @State private var swap = false
    @State private var index = 0
    @State private var page = 0
    @State private var parsing: String?
    @State private var parseError: String?
    @State private var showEdit = false
    @State private var showMark = false
    @State private var msSource: ImportSource?
    @State private var msPhotos: [PhotosPickerItem] = []
    @State private var share: ShareItem?
    @State private var confirmSubmit = false
    @State private var confirmSettle = false
    @State private var confirmParse = false
    @State private var showQuiz = false
    @State private var newPaper: String?

    private var p: ImpPaper? { store.papers[id] }
    private var sheet: String { "imp-" + id }

    var body: some View {
        Group {
            if let p {
                if p.mode == "cards" { cards(p) } else { inkView(p) }
            } else {
                ContentUnavailableView("找不到这份试卷", systemImage: "doc.questionmark")
            }
        }
        .appScreen()
        .navigationTitle(p?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onChange(of: inkOn) { _, v in ink.enabled = v; msInk.enabled = v }
        .importPickers(source: $msSource, photos: $msPhotos) { d, _ in
            if let d { store.setMS(id, d); ms = store.ms(id) }
        }
        .sheet(isPresented: $showEdit) { NavigationStack { ImportEditSheet(id: id) } }
        .sheet(isPresented: $showQuiz) {
            if let d = doc, let p {
                NavigationStack {
                    PDFQuizSheet(title: p.name, subject: p.subject, chapters: p.chapters, pageCount: d.pageCount,
                                 page: { i in (ImpPDF.pageImage(d, i, width: 1400), d.page(at: i)?.string ?? "") },
                                 pdf: { d }, startPage: page, onDone: { nid in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { newPaper = nid } })
                }
            }
        }
        .navigationDestination(item: $newPaper) { nid in ImportPaperView(id: nid) }
        .sheet(isPresented: $showMark) { NavigationStack { ImportInkMarkSheet(id: id) } }
        .sheet(item: $share) { s in ActivitySheet(url: s.url) }
        .confirmationDialog("确定交卷？", isPresented: $confirmSubmit, titleVisibility: .visible) {
            Button("交卷") { update { $0.submitted = true } }
        } message: { Text("交卷后可以上传评分标准，自评或让 DeepSeek 批改。") }
        .confirmationDialog(settleSummary, isPresented: $confirmSettle, titleVisibility: .visible) {
            Button("结算") { settle() }
        }
        .confirmationDialog(parseCost, isPresented: $confirmParse, titleVisibility: .visible) {
            Button("开始解析") { Task { await parse() } }
        } message: { Text("用 deepseek-flash 逐页看图拆题，已解析的页会缓存，不会重复收费。") }
        .alert("解析出错", isPresented: Binding(get: { parseError != nil }, set: { if !$0 { parseError = nil } })) {} message: { Text(parseError ?? "") }
        .workingSession(sheet, clearOnLeave: false)
        .task {
            doc = store.doc(id); ms = store.ms(id)
        }
    }

    private func update(_ f: (inout ImpPaper) -> Void) {
        guard var x = store.papers[id] else { return }
        f(&x); store.save(x)
    }

    // MARK: ink mode

    @ViewBuilder private func inkView(_ p: ImpPaper) -> some View {
        if let doc {
            if p.submitted, let ms {
                SplitContainer(key: "imp.ms.ratio", defaultRatio: 0.5) {
                    pdf(swap ? ms : doc, isMS: swap)
                } second: {
                    pdf(swap ? doc : ms, isMS: !swap)
                }
            } else {
                pdf(doc, isMS: false)
            }
        } else { ProgressView() }
    }

    @State private var vctl = ViewCtl()
    @State private var msCtl = ViewCtl()
    private func pdf(_ d: PDFDocument, isMS: Bool) -> some View {
        PDFKitView(doc: d, onPage: { if !isMS { page = $0 } }, ink: isMS ? msInk : ink,
                   inkKey: "imp:" + id + (isMS ? "-ms" : ""), inkTitle: (p?.name ?? "") + (isMS ? " · 评分标准" : ""), ctl: isMS ? msCtl : vctl)
            .id((isMS ? "ms" : "p") + (swap ? "1" : "0"))
            .overlay(alignment: .topTrailing) { ViewHUD(ctl: isMS ? msCtl : vctl) }
            .deepSeek(pageContext(d, isMS: isMS))
    }

    private func pageContext(_ d: PDFDocument, isMS: Bool) -> DSContext? {
        guard let p else { return nil }
        let ans = (!isMS ? ms?.string : nil).map { DSStudy.cut($0, 12000) }
        var c = DSContext.pdfPage(d, page, title: p.name, url: isMS ? ImportStore.msURL(id) : ImportStore.paperURL(id), subject: p.subject, answer: ans)
        c.chapter = ImpCtx.chapter(p)
        if !isMS, let ink = flattened(page) { c.images.append(ink) }
        return c
    }

    private func flattened(_ i: Int) -> UIImage? {
        guard let d = doc, PDFInk.load("imp:" + id, i) != nil else { return nil }
        return ImpExport.flatPage(d, i, key: "imp:" + id)
    }

    // MARK: cards mode

    @ViewBuilder private func cards(_ p: ImpPaper) -> some View {
        if p.qs.isEmpty || parsing != nil {
            VStack(spacing: 16) {
                Image(systemName: "sparkles.rectangle.stack").font(.system(size: 44)).foregroundStyle(.secondary)
                if let s = parsing {
                    ProgressView(s)
                } else {
                    Text("AI 答题卡：DeepSeek 逐页看试卷，拆成一题一卡（选择题变成选项，长题可以打字或手写）。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Text(parseCost).font(.footnote).foregroundStyle(.secondary)
                    Button("解析试卷") { confirmParse = true }.glassButton(prominent: true).disabled(!DSKey.has)
                    if !DSKey.has { Text("先在 设置 › DeepSeek 填 API key").font(.footnote).foregroundStyle(.orange) }
                }
            }
            .padding(30).frame(maxWidth: 520).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let q = p.qs[min(index, p.qs.count - 1)]
            let hand = p.hand[q.id] ?? false
            WorkSplit(on: splitOn && (hand || !q.isMC), sheetID: sheet, figs: []) {
                ImportQuestionView(id: id, qid: q.id, doc: doc, sheetID: sheet)
                    .id(q.id)
                    .deepSeek(ImpCtx.question(p, q, doc: doc, sheet: splitOn ? sheet : nil))
            } bar: {
                PageCluster(index: index, count: p.qs.count,
                            prev: index > 0 ? { index -= 1 } : nil,
                            next: index < p.qs.count - 1 ? { index += 1 } : nil)
            }
        }
    }

    private var remainingPages: [Int] {
        guard let d = doc, let p else { return [] }
        return (0..<d.pageCount).filter { !p.parsedPages.contains($0) }
    }
    private var parseCost: String {
        let n = remainingPages.count
        return n == 0 ? "所有页都已解析" : String(format: "要解析 %d 页，预计约 US$%.3f（每页约 US$%.4f）", n, Double(n) * ImpParse.perPage, ImpParse.perPage)
    }

    private func parse() async {
        guard let d = doc else { return }
        let pages = remainingPages
        for (k, i) in pages.enumerated() {
            parsing = "正在解析第 \(i + 1) 页（\(k + 1)/\(pages.count)）…"
            guard let im = ImpPDF.pageImage(d, i) else { continue }
            do {
                let qs = try await ImpParse.questions(page: im, text: d.page(at: i)?.string ?? "", index: i, count: d.pageCount)
                update { x in ImpParse.merge(&x.qs, qs); x.parsedPages.append(i) }
            } catch {
                parseError = (error as? DSError)?.errorDescription ?? error.localizedDescription
                break
            }
        }
        parsing = nil
        if let p, p.hasMS { await parseMS() }
    }

    func parseMS() async {
        guard let m = ms, let p else { return }
        let nums = p.qs.map(\.n)
        for i in 0..<m.pageCount where !p.msParsed.contains(i) {
            parsing = "正在读评分标准第 \(i + 1)/\(m.pageCount) 页…"
            guard let im = ImpPDF.pageImage(m, i) else { continue }
            do {
                let items = try await ImpParse.scheme(page: im, text: m.page(at: i)?.string ?? "", index: i, numbers: nums)
                update { x in
                    for (n, a, s) in items {
                        guard let j = x.qs.firstIndex(where: { ImpParse.norm($0.n) == ImpParse.norm(n) }) else { continue }
                        if !a.isEmpty { x.qs[j].answer = a }
                        if !s.isEmpty { x.qs[j].scheme = ((x.qs[j].scheme ?? "").isEmpty ? "" : x.qs[j].scheme! + "\n") + s }
                    }
                    x.msParsed.append(i)
                }
            } catch {
                parseError = (error as? DSError)?.errorDescription ?? error.localizedDescription
                break
            }
        }
        parsing = nil
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let p {
            ToolbarItem(placement: .principal) {
                Picker("", selection: Binding(get: { p.mode }, set: { v in update { $0.mode = v } })) {
                    Text("直接做在上面").tag("ink")
                    Text("AI 答题卡").tag("cards")
                }
                .pickerStyle(.segmented).frame(width: 240)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if p.mode == "ink" {
                    InkToggle(on: $inkOn)
                    PadButton()
                    if p.submitted && ms != nil { Button { swap.toggle() } label: { Image(systemName: "arrow.left.arrow.right") }.accessibilityLabel("交换左右") }
                } else {
                    Button { withAnimation { splitOn.toggle() } } label: { Image(systemName: splitOn ? "rectangle.split.2x1.fill" : "rectangle.split.2x1") }
                }
                Menu {
                    Button { showQuiz = true } label: { Label("根据此 PDF 出题", systemImage: "sparkles.rectangle.stack") }.disabled(doc == nil)
                    if p.mode == "cards" {
                        Button { showEdit = true } label: { Label("编辑 / 合并 / 拆分题目", systemImage: "pencil") }.disabled(p.qs.isEmpty)
                        if !remainingPages.isEmpty && !p.qs.isEmpty { Button { confirmParse = true } label: { Label("解析剩下的页", systemImage: "sparkles") } }
                        Button(role: .destructive) { update { $0.qs = []; $0.parsedPages = []; $0.msParsed = [] }; index = 0 } label: { Label("清空题目重新解析", systemImage: "arrow.counterclockwise") }
                    }
                    Section("评分标准") {
                        Button { msSource = .files } label: { Label(p.hasMS ? "替换评分标准（文件）" : "上传评分标准（文件）", systemImage: "folder") }
                        Button { msSource = .photos } label: { Label("评分标准（照片）", systemImage: "photo") }
                        if VNDocumentCameraViewController.isSupported { Button { msSource = .scan } label: { Label("评分标准（扫描）", systemImage: "doc.viewfinder") } }
                        if p.hasMS && p.mode == "cards" && !p.qs.isEmpty {
                            Button { Task { await parseMS() } } label: { Label("让 DeepSeek 读评分标准", systemImage: "sparkles") }
                        }
                    }
                    Section("导出") {
                        Button { share = ImpExport.annotated(id).map { ShareItem(url: $0) } } label: { Label("带手写的 PDF", systemImage: "pencil.and.outline") }
                        Button { share = ImpExport.original(id).map { ShareItem(url: $0) } } label: { Label("原始 PDF", systemImage: "doc") }
                        Button { share = ImpExport.results(id).map { ShareItem(url: $0) } } label: { Label("答题与批改结果 PDF", systemImage: "list.bullet.clipboard") }
                        Button { share = ImpExport.bundle(id).map { ShareItem(url: $0) } } label: { Label("完整导出包（可再导入）", systemImage: "shippingbox") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            ToolbarItem(placement: .confirmationAction) {
                if !p.submitted { Button("交卷") { confirmSubmit = true } }
                else if p.mode == "ink" && p.qs.isEmpty { Button("评分") { showMark = true }.bold() }
                else { Button(p.settled ? "重新结算" : "结算") { confirmSettle = true }.bold() }
            }
        }
    }

    private var settleSummary: String {
        guard let p else { return "" }
        let t = ImpScore.tally(p)
        return "得分 \(t.got)/\(t.total)" + (t.unmarked > 0 ? "（\(t.unmarked) 题未评分，不计入）" : "")
    }

    private func settle() {
        guard let p else { return }
        let t = ImpScore.tally(p)
        update { $0.score = t.got; $0.total = t.total; $0.settled = true }
        ImpScore.record(p)
        Task { await SyncManager.shared.sync() }
    }
}

struct ShareItem: Identifiable { let id = UUID(); let url: URL }
struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ v: UIActivityViewController, context: Context) {}
}

// MARK: - Scores

enum ImpScore {
    static func key(_ p: ImpPaper, _ q: ImpQ) -> String { "imp:" + p.id + ":" + q.id }
    static func letter(_ s: String?) -> Int? {
        guard let s = s?.trimmingCharacters(in: .whitespaces).uppercased(), let c = s.first, let a = "ABCDEF".firstIndex(of: c) else { return nil }
        return "ABCDEF".distance(from: "ABCDEF".startIndex, to: a)
    }
    static func mcRight(_ p: ImpPaper, _ q: ImpQ) -> Bool? {
        guard q.isMC, let k = letter(q.answer), let m = p.mc[q.id] else { return nil }
        return k == m
    }
    static func tally(_ p: ImpPaper) -> (got: Int, total: Int, unmarked: Int) {
        if p.qs.isEmpty { return (p.manualScore ?? 0, p.manualTotal ?? 0, p.manualScore == nil ? 1 : 0) }
        var got = 0, total = 0, un = 0
        for q in p.qs {
            if q.isMC {
                let m = q.marks ?? 1
                if let r = mcRight(p, q) { total += m; if r { got += m } }
                else if letter(q.answer) == nil, let s = ProgressStore.shared.scores[key(p, q)] { got += s; total += m }
                else if p.mc[q.id] == nil && letter(q.answer) != nil { total += m }
                else { un += 1 }
            } else if let s = ProgressStore.shared.scores[key(p, q)] {
                got += s; total += q.marks ?? max(s, 1)
            } else { un += 1 }
        }
        return (got, total, un)
    }
    /// MC answers go into the answer history (and, with chapters set, under that chapter's key for review).
    static func record(_ p: ImpPaper) {
        for q in p.qs { if let r = mcRight(p, q) { ProgressStore.shared.record(key(p, q), ok: r) } }
    }
}

// MARK: - DeepSeek context

enum ImpCtx {
    static func chapter(_ p: ImpPaper) -> String? {
        let parts: [String] = p.chapters.compactMap { id in
            if let c = Library.shared.chapter(id), !c.isStub { return DSContext.ictChapter(c, budget: 4000) }
            if let c = MathLibrary.shared.chapter(id) { return DSContext.mathChapter(c, budget: c.isZh ? 8000 : 4000) }
            return nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
    static func question(_ p: ImpPaper, _ q: ImpQ, doc: PDFDocument?, sheet: String?) -> DSContext {
        let L = ["A", "B", "C", "D", "E", "F"]
        var page = "第 \(q.n) 题" + (q.marks.map { "（\($0) 分）" } ?? "") + "\n" + q.text
        if q.isMC { page += "\n" + q.options.enumerated().map { "\(L[min($0.offset, 5)]). " + $0.element }.joined(separator: "\n") }
        if let t = p.typed[q.id], !t.isEmpty { page += "\n\n【学生作答】\n" + t }
        var imgs: [UIImage] = []
        if let d = doc, let im = ImpPDF.pageImage(d, q.page, width: 1200) { imgs.append(im) }
        var s = ""
        if let a = q.answer, !a.isEmpty { s += "答案：" + a + "\n" }
        if let m = p.mc[q.id], q.isMC { s += "学生选了 " + L[min(m, 5)] + "\n" }
        if let x = q.scheme, !x.isEmpty { s += "评分标准：\n" + x }
        let sv: String? = s.isEmpty ? nil : s
        return DSContext(key: "imp-" + p.id + "-" + q.id, subject: p.subject, title: p.name + " · 第 \(q.n) 题", page: page, images: imgs,
                         revealed: p.submitted ? sv : nil, answer: p.submitted ? nil : sv, chapter: chapter(p), sheetID: sheet)
    }
}

// MARK: - Question card

struct ImportQuestionView: View {
    let id: String
    let qid: String
    let doc: PDFDocument?
    let sheetID: String
    @State private var store = ImportStore.shared
    @State private var showPage = false
    private let L = ["A", "B", "C", "D", "E", "F"]

    var body: some View {
        if let p = store.papers[id], let q = p.qs.first(where: { $0.id == qid }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("第 \(q.n) 题").font(.subheadline.bold()).foregroundStyle(.secondary)
                        if let m = q.marks { Text("\(m) 分").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button { showPage = true } label: { Label("原页 \(q.page + 1)", systemImage: "doc.text.magnifyingglass") }.font(.caption).buttonStyle(.bordered)
                    }
                    MathText(text: q.text, size: 18)
                    if let d = doc, let im = ImpPDF.pageImage(d, q.page), let fig = ImpPDF.crop(im, q.box) {
                        Image(uiImage: fig).resizable().scaledToFit().frame(maxHeight: 360).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if q.isMC { mcRows(p, q) } else { longInput(p, q) }
                    if p.submitted { marking(p, q) }
                }
                .padding(.vertical)
                .readingMargin()
            }
            .softEdges()
            .sheet(isPresented: $showPage) {
                NavigationStack {
                    ScrollView { if let d = doc, let im = ImpPDF.pageImage(d, q.page, width: 1800) { Image(uiImage: im).resizable().scaledToFit() } }
                        .navigationTitle("第 \(q.page + 1) 页").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showPage = false } } }
                }
            }
        }
    }

    private func set(_ f: (inout ImpPaper) -> Void) {
        guard var x = store.papers[id] else { return }
        f(&x); store.save(x)
    }

    private func state(_ p: ImpPaper, _ q: ImpQ, _ i: Int) -> MCState {
        let picked = p.mc[q.id] == i
        guard p.submitted, let k = ImpScore.letter(q.answer) else { return picked ? .selected : .idle }
        if k == i { return .correct }
        return picked ? .wrong : .idle
    }

    private func mcRows(_ p: ImpPaper, _ q: ImpQ) -> some View {
        ForEach(Array(q.options.enumerated()), id: \.offset) { i, t in
            Button { if !p.submitted { set { $0.mc[q.id] = $0.mc[q.id] == i ? nil : i } } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    MCLetter(l: L[min(i, 5)])
                    MathText(text: t, size: 17)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .mcGlass(state(p, q, i))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func longInput(_ p: ImpPaper, _ q: ImpQ) -> some View {
        let hand = p.hand[q.id] ?? false
        Picker("", selection: Binding(get: { hand }, set: { v in set { $0.hand[q.id] = v } })) {
            Text("打字").tag(false)
            Text("手写").tag(true)
        }
        .pickerStyle(.segmented).frame(maxWidth: 240)
        if hand {
            Text("在旁边的草稿纸上作答（打开分屏）。").font(.footnote).foregroundStyle(.secondary)
        } else {
            TextEditor(text: Binding(get: { store.papers[id]?.typed[q.id] ?? "" }, set: { v in set { $0.typed[q.id] = v } }))
                .font(.body)
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .disabled(p.submitted)
        }
    }

    @ViewBuilder private func marking(_ p: ImpPaper, _ q: ImpQ) -> some View {
        if q.isMC, let r = ImpScore.mcRight(p, q) {
            Label(r ? "答对了" : "答错了，答案 \(q.answer ?? "")", systemImage: r ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(r ? Color.green : Color.red).font(.headline)
        } else if q.isMC && ImpScore.letter(q.answer) != nil {
            Text("没作答 · 答案 \(q.answer ?? "")").foregroundStyle(.secondary)
        } else {
            if let s = q.scheme, !s.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("评分标准").font(.headline)
                    MathText(text: s, size: 16)
                }.card()
            } else if !p.hasMS {
                Text("还没有评分标准：右上角 ⋯ › 上传评分标准，再让 DeepSeek 读取。也可以直接自评。").font(.footnote).foregroundStyle(.secondary)
            }
            let hand = p.hand[q.id] ?? false
            LongMarkCard(key: ImpScore.key(p, q), question: q.text, scheme: q.scheme ?? (q.answer ?? ""),
                         images: [doc.flatMap { ImpPDF.pageImage($0, q.page, width: 1200) }].compactMap { $0 },
                         sheetID: hand ? sheetID : nil, max: q.marks ?? (q.isMC ? 1 : nil),
                         score: Binding(get: { ProgressStore.shared.scores[ImpScore.key(p, q)] },
                                        set: { ProgressStore.shared.setScore(ImpScore.key(p, q), $0, max: q.marks ?? 0) }),
                         answerText: hand ? nil : p.typed[q.id], context: ImpCtx.chapter(p))
        }
    }
}

// MARK: - Fix questions after parsing

struct ImportEditSheet: View {
    let id: String
    @State private var store = ImportStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let qs = store.papers[id]?.qs ?? []
        List {
            ForEach(Array(qs.enumerated()), id: \.element.id) { i, q in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("题号", text: bind(q.id, \.n)).font(.headline).frame(maxWidth: 120)
                        Stepper("第 \(q.page + 1) 页", value: Binding(get: { q.page }, set: { v in edit(q.id) { $0.page = max(0, v) } }), in: 0...max(0, (store.doc(id)?.pageCount ?? 1) - 1))
                            .font(.caption)
                    }
                    TextEditor(text: bind(q.id, \.text)).frame(minHeight: 90).font(.callout)
                        .scrollContentBackground(.hidden).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    Text("选项（一行一个，留空 = 长题）").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { q.options.joined(separator: "\n") }, set: { v in
                        edit(q.id) { $0.options = v.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
                    })).frame(minHeight: 50).font(.callout)
                        .scrollContentBackground(.hidden).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        TextField("答案", text: Binding(get: { q.answer ?? "" }, set: { v in edit(q.id) { $0.answer = v.isEmpty ? nil : v } })).frame(maxWidth: 140)
                        TextField("分数", value: Binding(get: { q.marks }, set: { v in edit(q.id) { $0.marks = v } }), format: .number).frame(maxWidth: 70).keyboardType(.numberPad)
                        Spacer()
                        if i < qs.count - 1 { Button("与下一题合并") { merge(i) }.buttonStyle(.bordered) }
                        Button("拆分") { split(i) }.buttonStyle(.bordered)
                    }
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }
            .onDelete { idx in mutate { $0.qs.remove(atOffsets: idx) } }
            .onMove { from, to in mutate { $0.qs.move(fromOffsets: from, toOffset: to) } }
            .listRowBackground(Color.cardBackground)
        }
        .appList()
        .navigationTitle("编辑题目（\(qs.count)）")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { EditButton().tint(.primary).foregroundStyle(.primary) }
            ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.bold() }
            ToolbarItem(placement: .bottomBar) {
                Button { mutate { $0.qs.append(ImpQ(page: $0.qs.last?.page ?? 0, n: "\($0.qs.count + 1)", text: "")) } } label: { Label("加一题", systemImage: "plus") }
            }
        }
    }

    private func mutate(_ f: (inout ImpPaper) -> Void) {
        guard var x = store.papers[id] else { return }
        f(&x); store.save(x)
    }
    private func edit(_ qid: String, _ f: (inout ImpQ) -> Void) {
        mutate { x in if let i = x.qs.firstIndex(where: { $0.id == qid }) { f(&x.qs[i]) } }
    }
    private func bind(_ qid: String, _ kp: WritableKeyPath<ImpQ, String>) -> Binding<String> {
        Binding(get: { store.papers[id]?.qs.first { $0.id == qid }?[keyPath: kp] ?? "" }, set: { v in edit(qid) { $0[keyPath: kp] = v } })
    }
    private func merge(_ i: Int) {
        mutate { x in
            guard i + 1 < x.qs.count else { return }
            let b = x.qs.remove(at: i + 1)
            x.qs[i].text += "\n" + b.text
            x.qs[i].options += b.options
            if x.qs[i].box == nil { x.qs[i].box = b.box }
            if let m = b.marks { x.qs[i].marks = (x.qs[i].marks ?? 0) + m }
        }
    }
    /// Splits at the first blank line (or in half); fix the text afterwards.
    private func split(_ i: Int) {
        mutate { x in
            let q = x.qs[i]
            var a = q.text, b = ""
            if let r = q.text.range(of: "\n\n") { a = String(q.text[..<r.lowerBound]); b = String(q.text[r.upperBound...]) }
            else { let mid = q.text.index(q.text.startIndex, offsetBy: q.text.count / 2); a = String(q.text[..<mid]); b = String(q.text[mid...]) }
            x.qs[i].text = a
            var n = ImpQ(page: q.page, n: q.n + "'", text: b)
            n.options = q.options; x.qs[i].options = []
            x.qs.insert(n, at: i + 1)
        }
    }
}

// MARK: - Marking for "直接做在上面" without parsed questions

struct ImportInkMarkSheet: View {
    let id: String
    @State private var store = ImportStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var grading: Int?
    @State private var results: [Int: DSGradeResult] = [:]
    @State private var error: String?

    var body: some View {
        let p = store.papers[id]
        let pages = store.doc(id)?.pageCount ?? 0
        Form {
            Section {
                Stepper("得分：\(p?.manualScore.map { "\($0)" } ?? "—")", value: Binding(get: { p?.manualScore ?? 0 }, set: { v in mutate { $0.manualScore = max(0, v) } }), in: 0...999)
                Stepper("满分：\(p?.manualTotal.map { "\($0)" } ?? "—")", value: Binding(get: { p?.manualTotal ?? 0 }, set: { v in mutate { $0.manualTotal = max(0, v) } }), in: 0...999)
            } header: { Text("自评") } footer: { Text("对照右边的评分标准自己给分。想逐题批改，可以切到「AI 答题卡」先拆题。") }
            .listRowBackground(Color.cardBackground)
            if p?.hasMS == true {
                Section {
                    ForEach(0..<pages, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("第 \(i + 1) 页")
                                Spacer()
                                if grading == i { ProgressView() }
                                else { Button(results[i] == nil ? "DeepSeek 批改" : "重新批改") { grade(i) }.buttonStyle(.bordered).disabled(grading != nil) }
                            }
                            if let r = results[i] {
                                Text("\(r.score)/\(r.max) · " + r.summary).font(.callout)
                                ForEach(r.points) { pt in
                                    Text("• \(pt.point)：\(Int(pt.awarded))/\(Int(pt.max))" + (pt.comment.isEmpty ? "" : " — " + pt.comment)).font(.caption).foregroundStyle(.secondary)
                                }
                                Button("采用这一页的分数") {
                                    mutate { $0.manualScore = ($0.manualScore ?? 0) + r.score; $0.manualTotal = ($0.manualTotal ?? 0) + r.max }
                                }.font(.caption)
                            }
                        }
                    }
                } header: { Text("DeepSeek 按评分标准批改") } footer: {
                    Text("每页把你写在试卷上的字（拍平成图）和评分标准一起发给 DeepSeek。采用会累加到上面的分数。")
                }
                .listRowBackground(Color.cardBackground)
            }
            if let e = error { Text(e).foregroundStyle(.red).listRowBackground(Color.cardBackground) }
            Section {
                Button("结算") {
                    mutate { $0.score = $0.manualScore; $0.total = $0.manualTotal; $0.settled = $0.manualScore != nil }
                    Task { await SyncManager.shared.sync() }
                    dismiss()
                }.bold().disabled(p?.manualScore == nil)
            }
            .listRowBackground(Color.cardBackground)
        }
        .appList()
        .navigationTitle("评分")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }

    private func mutate(_ f: (inout ImpPaper) -> Void) {
        guard var x = store.papers[id] else { return }
        f(&x); store.save(x)
    }

    private func grade(_ i: Int) {
        guard let d = store.doc(id), let m = store.ms(id) else { return }
        grading = i; error = nil
        let img = ImpExport.flatPage(d, i, key: "imp:" + id) ?? ImpPDF.pageImage(d, i)
        let spec = DSGradeSpec(question: "试卷第 \(i + 1) 页上的所有题目（学生直接写在附图的试卷上）。" + (d.page(at: i)?.string.map { "\n页面文字：\n" + DSStudy.cut($0, 4000) } ?? ""),
                               scheme: DSStudy.cut(m.string ?? "（评分标准只有图片，见附图）", 12000), maxMarks: 0,
                               images: [img].compactMap { $0 } + ((m.string ?? "").isEmpty ? (0..<min(m.pageCount, 3)).compactMap { ImpPDF.pageImage(m, $0, width: 1100) } : []))
        Task {
            do { results[i] = try await DSGrader.grade(spec) }
            catch { self.error = (error as? DSError)?.errorDescription ?? error.localizedDescription }
            grading = nil
        }
    }
}

// MARK: - Export

enum ImpExport {
    static var out: URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("prism-export", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func fileName(_ id: String, _ suffix: String, _ ext: String) -> URL {
        let n = (ImportStore.shared.papers[id]?.name ?? "paper").replacingOccurrences(of: "/", with: "-")
        return out.appendingPathComponent(n + suffix + "." + ext)
    }

    /// One page rendered with its handwriting on top.
    static func flatPage(_ d: PDFDocument, _ i: Int, key: String, width: CGFloat = 1400) -> UIImage? {
        guard let p = d.page(at: i) else { return nil }
        let b = p.bounds(for: .mediaBox)
        let s = width / max(1, b.width)
        let size = CGSize(width: width, height: b.height * s)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.saveGState(); cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: s, y: -s)
            p.draw(with: .mediaBox, to: cg); cg.restoreGState()
            drawInk(key, i, in: CGRect(origin: .zero, size: size))
        }
    }

    static func drawInk(_ key: String, _ i: Int, in r: CGRect) {
        guard let dr = PDFInk.load(key, i) else { return }
        let w = PDFInk.width(key, i) ?? max(dr.bounds.maxX, 1)
        let h = w * r.height / max(1, r.width)
        var im = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {   // dark mode would turn black ink white
            im = dr.image(from: CGRect(x: 0, y: 0, width: w, height: h), scale: 2)
        }
        im.draw(in: r)
    }

    static func annotated(_ id: String) -> URL? {
        guard let d = ImportStore.shared.doc(id) else { return nil }
        let u = fileName(id, "（手写）", "pdf")
        let r = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        try? r.writePDF(to: u) { ctx in
            for i in 0..<d.pageCount {
                guard let p = d.page(at: i) else { continue }
                let b = p.bounds(for: .mediaBox)
                ctx.beginPage(withBounds: CGRect(origin: .zero, size: b.size), pageInfo: [:])
                let cg = ctx.cgContext
                cg.saveGState(); cg.translateBy(x: 0, y: b.height); cg.scaleBy(x: 1, y: -1)
                p.draw(with: .mediaBox, to: cg); cg.restoreGState()
                drawInk("imp:" + id, i, in: CGRect(origin: .zero, size: b.size))
            }
        }
        return u
    }

    static func original(_ id: String) -> URL? {
        let u = fileName(id, "", "pdf")
        try? FileManager.default.removeItem(at: u)
        try? FileManager.default.copyItem(at: ImportStore.paperURL(id), to: u)
        return u
    }

    static func results(_ id: String) -> URL? {
        guard let p = ImportStore.shared.papers[id] else { return nil }
        let u = fileName(id, "（批改结果）", "pdf")
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let m: CGFloat = 40
        let r = UIGraphicsPDFRenderer(bounds: page)
        let doc = ImportStore.shared.doc(id)
        try? r.writePDF(to: u) { ctx in
            var y: CGFloat = 0
            func newPage() { ctx.beginPage(); y = m }
            func text(_ s: String, _ font: UIFont, _ color: UIColor = .black) {
                let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
                let h = ceil(a.boundingRect(with: CGSize(width: page.width - 2 * m, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).height)
                if y + min(h, page.height - 2 * m) > page.height - m { newPage() }
                a.draw(with: CGRect(x: m, y: y, width: page.width - 2 * m, height: h), options: [.usesLineFragmentOrigin], context: nil)
                y += h + 6
            }
            func image(_ im: UIImage, maxH: CGFloat) {
                let w = page.width - 2 * m
                var s = CGSize(width: w, height: w * im.size.height / max(1, im.size.width))
                if s.height > maxH { s = CGSize(width: s.width * maxH / s.height, height: maxH) }
                if y + s.height > page.height - m { newPage() }
                im.draw(in: CGRect(x: m, y: y, width: s.width, height: s.height))
                y += s.height + 8
            }
            newPage()
            let t = ImpScore.tally(p)
            text(p.name, .boldSystemFont(ofSize: 20))
            text(DSContext.subjectName(p.subject) + " · " + Date(timeIntervalSince1970: p.created).formatted(date: .abbreviated, time: .omitted) + " · " + (p.settled ? scoreText(p.score, p.total) : "得分 \(t.got)/\(t.total)（未结算）"), .systemFont(ofSize: 12), .darkGray)
            let L = ["A", "B", "C", "D", "E", "F"]
            for q in p.qs {
                y += 6
                text("第 \(q.n) 题" + (q.marks.map { "（\($0) 分）" } ?? ""), .boldSystemFont(ofSize: 14))
                text(q.text, .systemFont(ofSize: 12))
                if q.isMC {
                    text(q.options.enumerated().map { "\(L[min($0.offset, 5)]). " + $0.element }.joined(separator: "\n"), .systemFont(ofSize: 12))
                    let mine = p.mc[q.id].map { L[min($0, 5)] } ?? "未作答"
                    let ok = ImpScore.mcRight(p, q)
                    text("我的答案：\(mine)　正确答案：\(q.answer ?? "—")　" + (ok == nil ? "" : (ok! ? "✓" : "✗")), .boldSystemFont(ofSize: 12), ok == false ? .systemRed : .systemGreen)
                } else {
                    if let a = p.typed[q.id], !a.isEmpty { text("我的作答：\n" + a, .systemFont(ofSize: 12), .darkGray) }
                    let s = ProgressStore.shared.scores[ImpScore.key(p, q)]
                    text("得分：" + (s.map { "\($0)" + (q.marks.map { "/\($0)" } ?? "") } ?? "未评分"), .boldSystemFont(ofSize: 12))
                    if let d = UserDefaults.standard.data(forKey: "lm." + ImpScore.key(p, q)), let pts = try? JSONDecoder().decode([LMPoint].self, from: d) {
                        for pt in pts {
                            text("• " + pt.text + "：" + (pt.got.map { "\($0)" } ?? "—") + "/\(pt.max)" + ((pt.comment ?? "").isEmpty ? "" : "　DeepSeek：" + pt.comment!), .systemFont(ofSize: 11), .darkGray)
                        }
                    }
                }
                if let x = q.scheme, !x.isEmpty { text("评分标准：\n" + x, .systemFont(ofSize: 11), .gray) }
            }
            if let s = DSContext.scratchImage("imp-" + id) { newPage(); text("草稿纸（手写作答）", .boldSystemFont(ofSize: 14)); image(s, maxH: page.height - 2 * m - 30) }
            if let d = doc {
                for i in 0..<d.pageCount where PDFInk.load("imp:" + id, i) != nil {
                    if let im = flatPage(d, i, key: "imp:" + id, width: 1100) { newPage(); text("试卷第 \(i + 1) 页（手写）", .boldSystemFont(ofSize: 14)); image(im, maxH: page.height - 2 * m - 30) }
                }
            }
        }
        return u
    }

    static func bundle(_ id: String) -> URL? {
        guard let d = ImpBundle.make(id) else { return nil }
        let u = fileName(id, "", "prismpaper")
        try? d.write(to: u, options: .atomic)
        return u
    }
}

/// Full export: one JSON file with the paper metadata and every file base64-encoded. Re-import from 导入 › 文件.
enum ImpBundle {
    struct B: Codable { var v = 1; var paper: ImpPaper; var files: [String: Data]; var ink: [String: [String: Data]]; var marks: [String: Data]; var scores: [String: Int] }

    static func make(_ id: String) -> Data? {
        guard let p = ImportStore.shared.papers[id] else { return nil }
        var files: [String: Data] = [:]
        for n in ["paper.pdf", "ms.pdf"] { if let d = try? Data(contentsOf: ImportStore.dir(id).appendingPathComponent(n)) { files[n] = d } }
        var ink: [String: [String: Data]] = [:]
        for (tag, key) in [("p", "imp:" + id), ("ms", "imp:" + id + "-ms")] {
            var m: [String: Data] = [:]
            for f in (try? FileManager.default.contentsOfDirectory(at: PDFInk.dir(key), includingPropertiesForKeys: nil)) ?? [] {
                if let d = try? Data(contentsOf: f) { m[f.lastPathComponent] = d }
            }
            if !m.isEmpty { ink[tag] = m }
        }
        var marks: [String: Data] = [:], scores: [String: Int] = [:]
        for q in p.qs {
            let k = ImpScore.key(p, q)
            if let d = UserDefaults.standard.data(forKey: "lm." + k) { marks[q.id] = d }
            if let s = ProgressStore.shared.scores[k] { scores[q.id] = s }
        }
        return try? JSONEncoder().encode(B(paper: p, files: files, ink: ink, marks: marks, scores: scores))
    }

    @discardableResult
    static func restore(_ data: Data) -> String? {
        guard var b = try? JSONDecoder().decode(B.self, from: data) else { return nil }
        let old = b.paper.id
        if ImportStore.shared.papers[old] != nil { b.paper.id = UUID().uuidString; b.paper.name += "（导入）" }
        let id = b.paper.id
        try? FileManager.default.createDirectory(at: ImportStore.dir(id), withIntermediateDirectories: true)
        for (n, d) in b.files { try? d.write(to: ImportStore.dir(id).appendingPathComponent(n)) }
        for (tag, m) in b.ink {
            let dir = PDFInk.dir("imp:" + id + (tag == "ms" ? "-ms" : ""))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (n, d) in m { try? d.write(to: dir.appendingPathComponent(n)) }
        }
        ImportStore.shared.save(b.paper)
        for q in b.paper.qs {
            let k = ImpScore.key(b.paper, q)
            if let d = b.marks[q.id] { UserDefaults.standard.set(d, forKey: "lm." + k) }
            if let s = b.scores[q.id] { ProgressStore.shared.setScore(k, s, max: q.marks ?? 0) }
        }
        return id
    }
}

// MARK: - Entry rows and storage

struct ImportLibraryLink: View {
    @State private var store = ImportStore.shared
    var body: some View {
        NavigationLink { ImportLibraryView() } label: {
            HStack {
                Label("导入的试卷", systemImage: "square.and.arrow.down.on.square")
                Spacer()
                if !store.papers.isEmpty { Text("\(store.papers.count)").foregroundStyle(.secondary) }
            }
        }
    }
}

struct ImportStorageSection: View {
    @State private var store = ImportStore.shared
    @State private var confirmAll = false
    var body: some View {
        Section {
            if store.papers.isEmpty { Text("没有导入的试卷").foregroundStyle(.secondary) }
            ForEach(store.sorted) { p in
                LabeledContent(p.name, value: ByteCountFormatter.string(fromByteCount: Int64(store.size(p.id)), countStyle: .file))
                    .swipeActions { Button("删除", role: .destructive) { store.delete(p.id) } }
            }
            if !store.papers.isEmpty { Button("全部删除", role: .destructive) { confirmAll = true } }
        } header: { Text("导入的试卷") } footer: { Text("导入的试卷、评分标准和手写只存在这台设备，不会自动删除。分数和名称会同步。") }
        .listRowBackground(Color.cardBackground)
        .confirmationDialog("删除所有导入的试卷？", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("全部删除", role: .destructive) { store.papers.keys.forEach { store.delete($0) } }
        }
    }
}

/// One UIKit document picker presented from the top view controller (copies files in, so no security-scope issues
/// and no clash between several SwiftUI fileImporters in one navigation stack).
enum FilePick {
    private final class Del: NSObject, UIDocumentPickerDelegate {
        let done: ([URL]) -> Void
        init(_ d: @escaping ([URL]) -> Void) { done = d }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls); FilePick.del = nil }
        func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) { FilePick.del = nil }
    }
    private static var del: Del?
    static func top() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var vc = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.windows.first { $0.isKeyWindow }?.rootViewController
        while let p = vc?.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }
    static func open(types: [UTType] = [.pdf, .image, UTType(filenameExtension: "prismpaper") ?? .data], _ done: @escaping ([URL]) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {   // let a closing Menu finish first
            let p = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            p.allowsMultipleSelection = true
            let d = Del(done); del = d; p.delegate = d
            top()?.present(p, animated: true)
        }
    }
}
