import SwiftUI
import PDFKit
import PencilKit
import PhotosUI
import VisionKit
import UniformTypeIdentifiers

// MARK: - 笔记: a local document library (blank or imported pages, ink, images, text boxes).

struct NoteItem: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var kind: String            // text | image
    /// Position and size as fractions of the page width (y and h too, so boxes keep their shape).
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var text: String? = nil
    var file: String? = nil
}

struct NotePage: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var src: Int? = nil          // page index in base.pdf; nil = blank page
    var style: String = "blank"  // blank | lined | grid | dotted
    var size: [Double] = [595, 842]
    var items: [NoteItem] = []
    var aspect: Double { size[1] / max(1, size[0]) }
}

struct NoteDoc: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var folder: String = ""
    var created: Double
    var modified: Double
    var pages: [NotePage] = []
    var hasBase = false
}

struct NoteSummary: Codable, Hashable { var id: String; var title: String; var folder: String; var pages: Int; var modified: Double }

enum NotePaper: String, CaseIterable, Identifiable {
    case blank, lined, grid, dotted
    var id: String { rawValue }
    var name: String {
        switch self { case .blank: return "空白"; case .lined: return "横线"; case .grid: return "方格"; case .dotted: return "点阵" }
    }
}

@Observable
final class NoteStore {
    static let shared = NoteStore()
    var docs: [String: NoteDoc] = [:]
    var remote: [String: NoteSummary] = [:]

    static var root: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    static func baseURL(_ id: String) -> URL { dir(id).appendingPathComponent("base.pdf") }
    static func imgURL(_ id: String, _ f: String) -> URL { dir(id).appendingPathComponent("img", isDirectory: true).appendingPathComponent(f) }
    static func inkKey(_ id: String, _ page: String) -> String { "note:" + id + ":" + page }

    private var bases: [String: PDFDocument] = [:]
    private var images: [String: UIImage] = [:]

    init() {
        for d in (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? [] {
            if let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")), let n = try? JSONDecoder().decode(NoteDoc.self, from: data) { docs[n.id] = n }
        }
        if let d = UserDefaults.standard.data(forKey: "note.remote"), let r = try? JSONDecoder().decode([String: NoteSummary].self, from: d) { remote = r }
    }
    var sorted: [NoteDoc] { docs.values.sorted { $0.modified > $1.modified } }
    /// Folder paths ("A", "A/B"); empty folders persist.
    var folderList: [String] = (UserDefaults.standard.stringArray(forKey: "notes.folders") ?? []) { didSet { UserDefaults.standard.set(folderList, forKey: "notes.folders") } }
    var folders: [String] {
        var all = Set(folderList)
        for d in docs.values where !d.folder.isEmpty {
            var p = ""
            for c in d.folder.split(separator: "/") { p = p.isEmpty ? String(c) : p + "/" + c; all.insert(p) }
        }
        return all.sorted()
    }
    func children(_ parent: String) -> [String] {
        folders.filter { f in parent.isEmpty ? !f.contains("/") : (f.hasPrefix(parent + "/") && !f.dropFirst(parent.count + 1).contains("/")) }
    }
    static func leaf(_ f: String) -> String { String(f.split(separator: "/").last ?? "") }
    func addFolder(_ parent: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !n.isEmpty else { return }
        let p = parent.isEmpty ? n : parent + "/" + n
        if !folderList.contains(p) { folderList.append(p) }
    }
    func renameFolder(_ f: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !n.isEmpty else { return }
        let parent = f.split(separator: "/").dropLast().joined(separator: "/")
        let to = parent.isEmpty ? n : parent + "/" + n
        func map(_ x: String) -> String { x == f ? to : (x.hasPrefix(f + "/") ? to + x.dropFirst(f.count) : x) }
        folderList = folderList.map(map)
        if !folderList.contains(to) { folderList.append(to) }
        for d in docs.values where d.folder == f || d.folder.hasPrefix(f + "/") { update(d.id) { $0.folder = map($0.folder) } }
    }
    func deleteFolder(_ f: String, deleteNotes: Bool) {
        folderList.removeAll { $0 == f || $0.hasPrefix(f + "/") }
        for d in docs.values where d.folder == f || d.folder.hasPrefix(f + "/") {
            if deleteNotes { delete(d.id) } else { update(d.id) { $0.folder = "" } }
        }
    }

    func save(_ n: NoteDoc, touch: Bool = true) {
        var n = n
        if touch { n.modified = Date().timeIntervalSince1970 }
        docs[n.id] = n
        try? FileManager.default.createDirectory(at: Self.dir(n.id), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(n) { try? d.write(to: Self.dir(n.id).appendingPathComponent("meta.json"), options: .atomic) }
    }
    func update(_ id: String, _ f: (inout NoteDoc) -> Void) {
        guard var n = docs[id] else { return }
        f(&n); save(n)
    }

    func createBlank(title: String, style: NotePaper, size: [Double], pages: Int) -> NoteDoc {
        let now = Date().timeIntervalSince1970
        var n = NoteDoc(id: UUID().uuidString, title: title, created: now, modified: now)
        n.pages = (0..<max(1, pages)).map { _ in NotePage(style: style.rawValue, size: size) }
        save(n)
        Task { await SyncManager.shared.sync() }
        return n
    }
    func createFrom(title: String, pdf: PDFDocument) -> NoteDoc {
        let now = Date().timeIntervalSince1970
        var n = NoteDoc(id: UUID().uuidString, title: title, created: now, modified: now, hasBase: true)
        try? FileManager.default.createDirectory(at: Self.dir(n.id), withIntermediateDirectories: true)
        pdf.write(to: Self.baseURL(n.id))
        n.pages = (0..<pdf.pageCount).map { i in
            let b = pdf.page(at: i)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
            return NotePage(src: i, size: [Double(b.width), Double(b.height)])
        }
        save(n)
        Task { await SyncManager.shared.sync() }
        return n
    }
    func delete(_ id: String) {
        if let n = docs[id] { for p in n.pages { try? FileManager.default.removeItem(at: PDFInk.dir(Self.inkKey(id, p.id))) } }
        try? FileManager.default.removeItem(at: Self.dir(id))
        docs[id] = nil; bases[id] = nil
        remote[id] = nil; saveRemote()
    }
    func deletePage(_ id: String, _ pid: String) {
        try? FileManager.default.removeItem(at: PDFInk.dir(Self.inkKey(id, pid)))
        update(id) { $0.pages.removeAll { $0.id == pid } }
    }
    func size(_ id: String) -> Int {
        var n = 0
        let fm = FileManager.default
        var dirs = [Self.dir(id), Self.dir(id).appendingPathComponent("img")]
        for p in docs[id]?.pages ?? [] { dirs.append(PDFInk.dir(Self.inkKey(id, p.id))) }
        for d in dirs {
            for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                n += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return n
    }

    func base(_ id: String) -> PDFDocument? {
        if let b = bases[id] { return b }
        let b = PDFDocument(url: Self.baseURL(id)); bases[id] = b; return b
    }
    func addImage(_ id: String, _ im: UIImage) -> String? {
        let f = UUID().uuidString + ".jpg"
        let u = Self.imgURL(id, f)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scaled = Self.downscale(im, max: 2000)
        guard let d = scaled.jpegData(compressionQuality: 0.85), (try? d.write(to: u)) != nil else { return nil }
        images[id + "/" + f] = scaled
        return f
    }
    func image(_ id: String, _ f: String?) -> UIImage? {
        guard let f else { return nil }
        if let i = images[id + "/" + f] { return i }
        let i = UIImage(contentsOfFile: Self.imgURL(id, f).path); images[id + "/" + f] = i; return i
    }
    static func downscale(_ im: UIImage, max m: CGFloat) -> UIImage {
        let s = min(1, m / max(im.size.width, im.size.height))
        if s >= 1 { return im }
        let size = CGSize(width: im.size.width * s, height: im.size.height * s)
        return UIGraphicsImageRenderer(size: size).image { _ in im.draw(in: CGRect(origin: .zero, size: size)) }
    }

    // Sync: summaries only.
    func collect() -> [String: String] {
        var o: [String: String] = [:]
        for n in docs.values {
            let s = NoteSummary(id: n.id, title: n.title, folder: n.folder, pages: n.pages.count, modified: n.modified)
            if let d = try? JSONEncoder().encode(s), let t = String(data: d, encoding: .utf8) { o["note/" + n.id] = t }
        }
        return o
    }
    func apply(_ id: String, _ v: String?, deleted: Bool) {
        if deleted { remote[id] = nil; saveRemote(); return }     // never deletes local files
        guard let v, let s = try? JSONDecoder().decode(NoteSummary.self, from: Data(v.utf8)) else { return }
        if var n = docs[id] {
            if s.modified > n.modified + 1 && (n.title != s.title || n.folder != s.folder) {
                n.title = s.title; n.folder = s.folder; n.modified = s.modified; save(n, touch: false)
            }
        } else { remote[id] = s; saveRemote() }
    }
    private func saveRemote() { if let d = try? JSONEncoder().encode(remote) { UserDefaults.standard.set(d, forKey: "note.remote") } }
}

// MARK: - Rendering

enum NoteRender {
    static let logicalWidth: CGFloat = 1000

    static func drawPaper(_ style: String, in r: CGRect, _ cg: CGContext) {
        UIColor.white.setFill(); cg.fill(r)
        let step = r.width / 28
        cg.setStrokeColor(UIColor(white: 0.78, alpha: 1).cgColor)
        cg.setLineWidth(max(0.5, r.width / 1400))
        switch style {
        case "lined":
            var y = step * 3
            while y < r.height - step { cg.move(to: CGPoint(x: step, y: y)); cg.addLine(to: CGPoint(x: r.width - step, y: y)); y += step * 1.2 }
            cg.strokePath()
        case "grid":
            var x: CGFloat = 0
            while x <= r.width { cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: r.height)); x += step }
            var y: CGFloat = 0
            while y <= r.height { cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: r.width, y: y)); y += step }
            cg.strokePath()
        case "dotted":
            cg.setFillColor(UIColor(white: 0.6, alpha: 1).cgColor)
            let d = max(1.2, r.width / 500)
            var y = step
            while y < r.height { var x = step; while x < r.width { cg.fillEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)); x += step }; y += step }
        default: break
        }
    }

    /// Page background only (PDF page or paper), `width` px wide.
    /// Backgrounds cached per page + width bucket (zoom steps are powers of 2), so zooming back and forth doesn't re-render.
    private static let bgCache: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.totalCostLimit = 300_000_000; return c }()
    static func cachedBackground(_ id: String, _ p: NotePage, width: CGFloat) -> UIImage {
        let key = "\(id)|\(p.id)|\(p.src ?? -1)|\(p.style)|\(Int(width))" as NSString
        if let im = bgCache.object(forKey: key) { return im }
        let im = background(id, p, width: width)
        bgCache.setObject(im, forKey: key, cost: Int(im.size.width * im.size.height * im.scale * im.scale * 4))
        return im
    }
    static func background(_ id: String, _ p: NotePage, width: CGFloat) -> UIImage {
        let size = CGSize(width: width, height: width * p.aspect)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1   // width is already in pixels
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let cg = ctx.cgContext
            if let s = p.src, let pg = NoteStore.shared.base(id)?.page(at: s) {
                UIColor.white.setFill(); cg.fill(CGRect(origin: .zero, size: size))
                let b = pg.bounds(for: .mediaBox)
                let k = width / max(1, b.width)
                cg.saveGState(); cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: k, y: -k)
                pg.draw(with: .mediaBox, to: cg); cg.restoreGState()
            } else {
                drawPaper(p.style, in: CGRect(origin: .zero, size: size), cg)
            }
        }
    }

    static func textImage(_ s: String, width: CGFloat, height: CGFloat) -> NSAttributedString {
        let plain = s.replacingOccurrences(of: "$$", with: "").replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "\\\\", with: " ")
        return NSAttributedString(string: plain, attributes: [.font: UIFont.systemFont(ofSize: max(8, width / 42)), .foregroundColor: UIColor.black])
    }

    /// Items (images and text boxes) and ink drawn in a page rect.
    static func overlay(_ id: String, _ p: NotePage, in r: CGRect, text: Bool = true) {
        let W = r.width
        for it in p.items {
            let f = CGRect(x: r.minX + it.x * W, y: r.minY + it.y * W, width: it.w * W, height: it.h * W)
            if it.kind == "image", let im = NoteStore.shared.image(id, it.file) { im.draw(in: f) }
            else if it.kind == "text", text, let t = it.text { textImage(t, width: W, height: f.height).draw(with: f, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil) }
        }
        ImpExport.drawInk(NoteStore.inkKey(id, p.id), 0, in: r)
    }

    static func flat(_ id: String, _ p: NotePage, width: CGFloat) -> UIImage {
        let bg = background(id, p, width: width)
        return UIGraphicsImageRenderer(size: bg.size).image { _ in
            bg.draw(at: .zero)
            overlay(id, p, in: CGRect(origin: .zero, size: bg.size))
        }
    }

    static func annotated(_ p: NotePage, _ id: String) -> Bool {
        !p.items.isEmpty || PDFInk.load(NoteStore.inkKey(id, p.id), 0) != nil
    }

    static func pageText(_ id: String, _ p: NotePage) -> String {
        var s = ""
        if let i = p.src, let t = NoteStore.shared.base(id)?.page(at: i)?.string { s += t.trimmingCharacters(in: .whitespacesAndNewlines) }
        for it in p.items where it.kind == "text" { if let t = it.text, !t.isEmpty { s += (s.isEmpty ? "" : "\n") + "［文本框］" + t } }
        return s
    }
}

// MARK: - Library

struct NotesLibraryView: View {
    var folder = ""
    @State private var store = NoteStore.shared
    @State private var newFolder = false
    @State private var renameFolder: String?
    @State private var deleteFolder: String?
    @State private var search = ""
    @State private var selection = Set<String>()
    @State private var edit: EditMode = .inactive
    @State private var confirm: [String] = []
    @State private var picker: ImportSource?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pending: PendingDoc?
    @State private var showNew = false
    @State private var rename: NoteDoc?
    @State private var moving: NoteDoc?
    @State private var field = ""
    @State private var error: String?
    @State private var open: String?

    private var shown: [NoteDoc] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return store.sorted.filter { $0.title.localizedCaseInsensitiveContains(q) && ($0.folder == folder || $0.folder.hasPrefix(folder.isEmpty ? "" : folder + "/")) } }
        return store.sorted.filter { $0.folder == folder }
    }
    private var groups: [(String, [NoteDoc])] { shown.isEmpty ? [] : [("", shown)] }

    @ViewBuilder private var folderSection: some View {
        if search.isEmpty && !store.children(folder).isEmpty {
            Section {
                ForEach(store.children(folder), id: \.self) { f in
                    NavigationLink { NotesLibraryView(folder: f) } label: {
                        HStack {
                            Label(NoteStore.leaf(f), systemImage: "folder.fill")
                            Spacer()
                            Text(String(count(f))).foregroundStyle(.secondary)
                        }
                    }
                    .dropDestination(for: String.self) { ids, _ in dropNotes(ids, f) }
                    .contextMenu {
                        Button { field = NoteStore.leaf(f); renameFolder = f } label: { Label("重命名文件夹", systemImage: "pencil") }
                        Button(role: .destructive) { deleteFolder = f } label: { Label("删除文件夹", systemImage: "trash") }
                    }
                    .swipeActions { Button("删除", role: .destructive) { deleteFolder = f } }
                }
            }
            .listRowBackground(Color.cardBackground)
        }
    }
    private func count(_ f: String) -> Int { store.docs.values.filter { $0.folder == f || $0.folder.hasPrefix(f + "/") }.count }
    private func dropNotes(_ ids: [String], _ f: String) -> Bool {
        for id in ids { store.update(id) { $0.folder = f } }
        sync(); return !ids.isEmpty
    }

    @ViewBuilder private var notesHeader: some View { if !store.children(folder).isEmpty { Text("笔记") } }
    private func noteRow(_ n: NoteDoc) -> some View {
        NavigationLink { NoteDocView(id: n.id) } label: { row(n) }
            .tag(n.id)
            .draggable(n.id)
            .swipeActions { Button("删除", role: .destructive) { confirm = [n.id] } }
            .contextMenu { noteMenu(n) }
    }
    @ViewBuilder private func noteMenu(_ n: NoteDoc) -> some View {
        Button { field = n.title; rename = n } label: { Label("重命名", systemImage: "pencil") }
        Button { field = n.folder; moving = n } label: { Label("移到文件夹", systemImage: "folder") }
        Button(role: .destructive) { confirm = [n.id] } label: { Label("删除", systemImage: "trash") }
    }

    private var remoteSorted: [NoteSummary] { store.remote.values.sorted { $0.modified > $1.modified } }
    @ViewBuilder private var remoteSection: some View {
        if !store.remote.isEmpty && search.isEmpty && folder.isEmpty {
            Section("其他设备") {
                ForEach(remoteSorted, id: \.id) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title)
                        Text("\(s.pages) 页 · 文件在其他设备上").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(Color.cardBackground)
        }
    }

    private var listView: some View {
        List(selection: $selection) {
            folderSection
            if store.docs.isEmpty && folder.isEmpty {
                ContentUnavailableView("还没有笔记", systemImage: "note.text", description: Text("右上角 + 新建空白笔记，或导入 PDF、照片、扫描。"))
                    .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.0) { g in
                Section {
                    ForEach(g.1) { n in noteRow(n) }
                } header: { notesHeader }
                .listRowBackground(Color.cardBackground)
            }
            remoteSection
        }
        .environment(\.editMode, $edit)
        .searchable(text: $search, prompt: "搜索标题")
        .appList()
        .navigationTitle(folder.isEmpty ? "笔记" : NoteStore.leaf(folder))
        .navigationDestination(item: $open) { NoteDocView(id: $0) }
    }

    @ToolbarContentBuilder private var bar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { showNew = true } label: { Label("新建空白笔记", systemImage: "doc.badge.plus") }
                Button { field = ""; newFolder = true } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                Button { picker = .files } label: { Label("导入文件（PDF / 图片）", systemImage: "folder") }
                Button { picker = .photos } label: { Label("从照片", systemImage: "photo.on.rectangle") }
                if VNDocumentCameraViewController.isSupported { Button { picker = .scan } label: { Label("扫描纸本", systemImage: "doc.viewfinder") } }
            } label: { Image(systemName: "plus") }
        }
        if edit == .active {
            ToolbarItem(placement: .confirmationAction) { Button("完成") { withAnimation { edit = .inactive; selection = [] } }.bold() }
        } else {
            ToolbarItem(placement: .primaryAction) { Button { field = ""; newFolder = true } label: { Label("新建文件夹", systemImage: "folder.badge.plus") } }
            ToolbarItem(placement: .primaryAction) { Button("选择") { withAnimation { edit = .active; selection = [] } }.foregroundStyle(.primary) }
        }
        if edit == .active && !selection.isEmpty {
            ToolbarItem(placement: .bottomBar) { Button("删除 \(selection.count) 份", role: .destructive) { confirm = Array(selection) } }
        }
    }

    private var core: some View {
        listView
            .toolbar { bar }
        .confirmationDialog("删除 \(confirm.count) 份笔记？页面、手写、图片和文本框都会从这台设备删除。", isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = [] } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { confirm.forEach { store.delete($0) }; confirm = []; selection = [] }
        }
        .importPickers(source: $picker, photos: $photoItems) { doc, err in
            if let doc {
                let t = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "笔记 " + Date().formatted(date: .numeric, time: .omitted)
                let n = store.createFrom(title: t, pdf: doc); store.update(n.id) { $0.folder = folder }; open = n.id
            } else if let err { error = err }
        }
        .sheet(isPresented: $showNew) { NavigationStack { NoteNewSheet { id in showNew = false; if let id { store.update(id) { $0.folder = folder }; open = id } } } }
    }

    var body: some View {
        core
        .alert("新建文件夹", isPresented: $newFolder) {
            TextField("名称", text: $field)
            Button("取消", role: .cancel) {}
            Button("新建") { store.addFolder(folder, field) }
        }
        .alert("重命名文件夹", isPresented: Binding(get: { renameFolder != nil }, set: { if !$0 { renameFolder = nil } })) {
            TextField("名称", text: $field)
            Button("取消", role: .cancel) { renameFolder = nil }
            Button("好") { if let f = renameFolder { store.renameFolder(f, field); sync() }; renameFolder = nil }
        }
        .confirmationDialog("删除文件夹「\(deleteFolder.map(NoteStore.leaf) ?? "")」？", isPresented: Binding(get: { deleteFolder != nil }, set: { if !$0 { deleteFolder = nil } }), titleVisibility: .visible) {
            Button("删除文件夹，笔记移到未分类") { if let f = deleteFolder { store.deleteFolder(f, deleteNotes: false); sync() }; deleteFolder = nil }
            Button("连里面的笔记一起删除", role: .destructive) { if let f = deleteFolder { store.deleteFolder(f, deleteNotes: true); sync() }; deleteFolder = nil }
        }
        .alert("重命名", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
            TextField("名称", text: $field)
            Button("取消", role: .cancel) { rename = nil }
            Button("好") { if let n = rename, !field.isEmpty { store.update(n.id) { $0.title = field } }; rename = nil; sync() }
        }
        .alert("移到文件夹", isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
            TextField("文件夹路径，如 化学/UT3（留空 = 未分类）", text: $field)
            Button("取消", role: .cancel) { moving = nil }
            Button("好") {
                if let n = moving {
                    let f = field.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "/")
                    store.update(n.id) { $0.folder = f }
                    if !f.isEmpty && !store.folderList.contains(f) { store.folderList.append(f) }
                }
                moving = nil; sync()
            }
        } message: { Text(store.folders.isEmpty ? "输入新文件夹名称" : "已有：" + store.folders.joined(separator: "、")) }
        .alert("导入失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {} message: { Text(error ?? "") }
    }

    private func sync() { Task { await SyncManager.shared.sync() } }

    private func row(_ n: NoteDoc) -> some View {
        HStack(spacing: 12) {
            NoteThumb(id: n.id, page: n.pages.first).frame(width: 44, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(n.title).font(.headline)
                Text("\(n.pages.count) 页 · " + Date(timeIntervalSince1970: n.modified).formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct NoteThumb: View {
    let id: String
    let page: NotePage?
    @State private var img: UIImage?
    var body: some View {
        ZStack {
            Color.white
            if let img { Image(uiImage: img).resizable().scaledToFit() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        .task(id: page) { if let page { img = NoteRender.flat(id, page, width: 160) } }
    }
}

struct NoteNewSheet: View {
    let done: (String?) -> Void
    @State private var title = "笔记 " + Date().formatted(date: .numeric, time: .omitted)
    @State private var style: NotePaper = .lined
    @State private var letter = false
    @State private var pages = 1
    var body: some View {
        Form {
            Section {
                TextField("名称", text: $title)
                Picker("纸张", selection: $style) { ForEach(NotePaper.allCases) { Text($0.name).tag($0) } }
                Picker("尺寸", selection: $letter) { Text("A4").tag(false); Text("Letter").tag(true) }
                Stepper("页数：\(pages)", value: $pages, in: 1...50)
            }
            .listRowBackground(Color.cardBackground)
        }
        .appList()
        .navigationTitle("新建笔记").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { done(nil) } }
            ToolbarItem(placement: .confirmationAction) {
                Button("新建") {
                    let n = NoteStore.shared.createBlank(title: title.isEmpty ? "笔记" : title, style: style, size: letter ? [612, 792] : [595, 842], pages: pages)
                    done(n.id)
                }.bold()
            }
        }
    }
}

// MARK: - Document

enum NoteTool: String { case pen, select }

struct NoteDocView: View {
    let id: String
    @State private var store = NoteStore.shared
    @State private var zoom: CGFloat = 1
    @State private var jump: CGFloat?
    @State private var vctl = ViewCtl()
    @State private var current: String?
    @State private var selected: String?
    @State private var editing: NoteItem?
    @State private var showPages = false
    @State private var showQuiz = false
    /// Last user scroll on this window. A plain reference (not @State) so scrolling doesn't re-render the whole note every frame.
    private final class Stamp { var t = Date.distantPast }
    @State private var mainUser = Stamp()
    @State private var newPaper: String?
    @AppStorage("notes.dsScope") private var scope = "all"
    @State private var ctx: DSContext?
    @State private var share: ShareItem?
    @State private var imgSource: ImportSource?
    @State private var imgPhotos: [PhotosPickerItem] = []
    @State private var camera = false
    @State private var rename = false
    @State private var field = ""
    @AppStorage("notes.tools") private var showTools = true
    /// 笔盘 shown = drawing; hidden = scroll / select.
    private var tool: NoteTool { showTools ? .pen : .select }

    private var doc: NoteDoc? { store.docs[id] }
    private var pageIndex: Int { doc?.pages.firstIndex { $0.id == current } ?? 0 }

    var body: some View {
        Group {
            if let doc {
                VStack(spacing: 0) {
                    GeometryReader { geo in
                        let base = min(1000, max(200, geo.size.width - 32))
                        ZoomScroll(size: CGSize(width: base + 32, height: contentHeight(doc, base)), zoom: $zoom, jump: $jump,
                                   onScroll: { y in pageAt(doc, base, y) }, locked: vctl.locked, onUser: { top, z in
                                       // Big screen moved by the user: the pad follows (and stale pad positions are ignored for a moment).
                                       mainUser.t = Date()
                                       guard PadHub.shared.padOpen else { return }
                                       let f = base / NoteRender.logicalWidth
                                       var t = Self.pad
                                       for p in doc.pages {
                                           let h = blockH(p, base)
                                           if top < t + h + Self.gap {
                                               let r = CGRect(x: 0, y: max(0, top - t) / f, width: geo.size.width / z / f, height: geo.size.height / z / f)
                                               NotificationCenter.default.post(name: .mainViewport, object: "note:" + NoteStore.inkKey(id, p.id), userInfo: ["r": r])
                                               return
                                           }
                                           t += h + Self.gap
                                       }
                                   }) {
                            pagesStack(doc, base)
                        }
                        .overlay(alignment: .topTrailing) { ViewHUD(ctl: vctl) }
                        .onAppear {
                            vctl.goPage = { i in
                                guard let d = NoteStore.shared.docs[id], d.pages.indices.contains(i) else { return }
                                current = d.pages[i].id; jump = offset(d, base, d.pages[i].id)
                            }
                        }
                        .onChange(of: base) { _, b in
                            vctl.goPage = { i in
                                guard let d = NoteStore.shared.docs[id], d.pages.indices.contains(i) else { return }
                                current = d.pages[i].id; jump = offset(d, b, d.pages[i].id)
                            }
                        }
                        .onChange(of: showPages) { _, v in if !v, let c = current { jump = offset(doc, base, c) } }
                        .onReceive(NotificationCenter.default.publisher(for: .padViewport)) { n in
                            // 手写板 scrolled/zoomed: show the same part of the same page.
                            guard Date().timeIntervalSince(mainUser.t) > 0.6, PadHub.shared.mainFollows, let ch = n.object as? String, let r = n.userInfo?["r"] as? CGRect, r.width > 1,
                                  let pi = doc.pages.firstIndex(where: { "note:" + NoteStore.inkKey(id, $0.id) == ch }) else { return }
                            let f = base / NoteRender.logicalWidth
                            if PadHub.syncZoom && !vctl.locked {
                                let z = min(4, max(0.5, geo.size.width / (r.width * f + 32 * 0)))
                                if abs(z - zoom) > 0.01 { zoom = z }
                            }
                            var top = Self.pad
                            for q in doc.pages.prefix(pi) { top += blockH(q, base) + Self.gap }
                            let nj = top + r.minY * f
                            if abs(nj - (jump ?? -1000)) > 0.5 { jump = nj }
                            if current != doc.pages[pi].id { current = doc.pages[pi].id }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .padPage)) { n in
                            guard (n.object as? String) == "note-" + id, let i = n.userInfo?["i"] as? Int, doc.pages.indices.contains(i) else { return }
                            current = doc.pages[i].id; jump = offset(doc, base, doc.pages[i].id)
                        }
                    }
                }
            } else {
                ContentUnavailableView("找不到这份笔记", systemImage: "doc.questionmark")
            }
        }
        .appScreen()
        .navigationTitle(doc?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .deepSeek(ctx)
        .onChange(of: zoom) { _, z in vctl.report(zoom: z) }
        .onChange(of: pageIndex) { _, i in vctl.report(page: i, of: doc?.pages.count ?? 1) }
        .onAppear {
            vctl.setZoom = { z in zoom = z }
            vctl.thumb = { i in
                guard let d = NoteStore.shared.docs[id], d.pages.indices.contains(i) else { return nil }
                return NoteRender.background(id, d.pages[i], width: 180)
            }
            vctl.bind(key: "note-" + id)
            vctl.report(page: pageIndex, of: doc?.pages.count ?? 1)
            vctl.report(zoom: zoom)
            if current == nil { current = doc?.pages.first?.id }
            if let s = PadSources.note(id) { PadHub.shared.activate(s, index: pageIndex) }
        }
        .onDisappear { PadHub.shared.deactivate("note-" + id) }
        .onReceive(NotificationCenter.default.publisher(for: .padAddPage)) { n in
            guard (n.object as? String) == "note-" + id, let doc else { return }
            let last = doc.pages.last
            let p = NotePage(style: last?.src == nil ? last?.style ?? "lined" : "lined", size: last?.size ?? [595, 842])
            store.update(id) { $0.pages.append(p) }
            current = p.id
        }
        .onChange(of: current) { _, _ in PadHub.shared.setIndex("note-" + id, pageIndex) }
        .onChange(of: doc?.pages.count ?? 0) { _, _ in if let s = PadSources.note(id) { PadHub.shared.activate(s, index: pageIndex, force: true) } }
        .task(id: "\(scope)|\(current ?? "")|\(Int(doc?.modified ?? 0))") {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { ctx = makeContext() }
        }
        .onChange(of: showTools) { _, _ in selected = nil }
        .sheet(isPresented: $showQuiz) {
            if let doc {
                NavigationStack {
                    PDFQuizSheet(title: doc.title, subject: "笔记", pageCount: doc.pages.count,
                                 page: { i in
                                     guard doc.pages.indices.contains(i) else { return (nil, "") }
                                     let p = doc.pages[i]
                                     let t = p.items.compactMap { $0.kind == "text" ? $0.text : nil }.joined(separator: "\n")
                                     return (NoteRender.background(id, p, width: 1400), t)
                                 },
                                 pdf: { ImpPDF.from(images: doc.pages.map { NoteRender.background(id, $0, width: 1400) }) },
                                 startPage: pageIndex, onDone: { nid in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { newPaper = nid } })
                }
            }
        }
        .navigationDestination(item: $newPaper) { nid in ImportPaperView(id: nid) }
        .sheet(isPresented: $showPages) { NavigationStack { NotePagesSheet(id: id, current: $current) } }
        .sheet(item: $editing) { it in NavigationStack { NoteTextEditor(docID: id, item: it) } }
        .sheet(item: $share) { s in ActivitySheet(url: s.url) }
        .sheet(isPresented: $camera) { CameraPicker { im in camera = false; if let im { insert(im) } }.ignoresSafeArea() }
        .importPickers(source: $imgSource, photos: $imgPhotos) { d, _ in
            guard let d else { return }
            for i in 0..<min(d.pageCount, 10) { if let im = ImpPDF.pageImage(d, i, width: 1600) { insert(im) } }
        }
        .alert("重命名", isPresented: $rename) {
            TextField("名称", text: $field)
            Button("取消", role: .cancel) {}
            Button("好") { if !field.isEmpty { store.update(id) { $0.title = field }; Task { await SyncManager.shared.sync() } } }
        }
    }

    // MARK: pages layout (unscaled points; ZoomScroll scales natively)

    private static let gap: CGFloat = 18, caption: CGFloat = 0, pad: CGFloat = 12
    private func blockH(_ p: NotePage, _ base: CGFloat) -> CGFloat { base * CGFloat(p.aspect) + Self.caption }
    private func contentHeight(_ doc: NoteDoc, _ base: CGFloat) -> CGFloat {
        var h = Self.pad * 2
        for (i, p) in doc.pages.enumerated() { h += blockH(p, base) + (i > 0 ? Self.gap : 0) }
        return h
    }
    private func offset(_ doc: NoteDoc, _ base: CGFloat, _ pid: String) -> CGFloat {
        var y = Self.pad
        for p in doc.pages { if p.id == pid { return max(0, y - 8) }; y += blockH(p, base) + Self.gap }
        return 0
    }
    private func pageAt(_ doc: NoteDoc, _ base: CGFloat, _ y: CGFloat) {
        var top = Self.pad
        for p in doc.pages {
            let end = top + blockH(p, base) + Self.gap
            if y < end { if current != p.id { current = p.id }; return }
            top = end
        }
    }
    private func pagesStack(_ doc: NoteDoc, _ base: CGFloat) -> some View {
        let ci = doc.pages.firstIndex { $0.id == current } ?? 0
        return VStack(spacing: Self.gap) {
            ForEach(Array(doc.pages.enumerated()), id: \.element.id) { i, p in
                NotePageView(docID: id, page: p, tool: tool, showTools: showTools, selected: $selected, editing: $editing, zoom: abs(i - ci) <= 1 ? zoom : 1)
                    .frame(width: base, height: base * CGFloat(p.aspect))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, Self.pad)
        .frame(width: base + 32, alignment: .top)
    }
    @ViewBuilder private var zoomBadge: some View {
        if abs(zoom - 1) > 0.01 {
            Button { zoom = 1 } label: { Text("\(Int(zoom * 100))%").font(.caption.monospacedDigit()) }
                .glassButton().padding(12)
        }
    }

    // MARK: DeepSeek context

    private var attachedPages: [NotePage] {
        guard let doc else { return [] }
        if scope == "page" { return doc.pages.indices.contains(pageIndex) ? [doc.pages[pageIndex]] : [] }
        // Annotated pages, current page first, at most 4.
        var ps = doc.pages.filter { NoteRender.annotated($0, id) }
        if let c = ps.firstIndex(where: { $0.id == current }) { ps.insert(ps.remove(at: c), at: 0) }
        return Array(ps.prefix(4))
    }

    @ViewBuilder private func contextBar(_ doc: NoteDoc) -> some View {
        let n = attachedPages.count
        let pages = scope == "page" ? "第 \(pageIndex + 1) 页" : "全文 \(doc.pages.count) 页"
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            Text("DeepSeek 会看到：\(pages)文字" + (n > 0 ? " + \(n) 张页面图" : "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Picker("", selection: $scope) { Text("全文").tag("all"); Text("本页").tag("page") }
                .pickerStyle(.segmented).frame(width: 130).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func makeContext() -> DSContext? {
        guard let doc else { return nil }
        var text = ""
        let list: [(Int, NotePage)] = scope == "page" ? (doc.pages.indices.contains(pageIndex) ? [(pageIndex, doc.pages[pageIndex])] : []) : Array(doc.pages.enumerated())
        for (i, p) in list {
            let t = NoteRender.pageText(id, p)
            if !t.isEmpty { text += "【第 \(i + 1) 页】\n" + t + "\n\n" }
        }
        if text.isEmpty { text = "（这份笔记没有文字层或文本框，内容见附图。）" }
        let imgs = attachedPages.map { NoteRender.flat(id, $0, width: 1000) }
        let pages = scope == "page" ? "第 \(pageIndex + 1) 页" : "全文 \(doc.pages.count) 页"
        let note = "会看到：" + pages + "文字" + (imgs.isEmpty ? "" : " + \(imgs.count) 张页面图")
        var c = DSContext(key: "note-" + id + (scope == "page" ? "-" + (current ?? "") : ""), subject: "笔记", title: doc.title + (scope == "page" ? " · 第 \(pageIndex + 1) 页" : ""),
                         page: DSStudy.cut(text, 20000), images: imgs)
        c.scopeNote = note
        c.doc = "note-" + id
        return c
    }

    // MARK: actions

    private func insert(_ im: UIImage) {
        guard let doc, doc.pages.indices.contains(pageIndex), let f = store.addImage(id, im) else { return }
        let w = 0.5, h = w * Double(im.size.height / max(1, im.size.width))
        let p = doc.pages[pageIndex]
        let item = NoteItem(kind: "image", x: 0.25, y: min(0.2, max(0, p.aspect - h)), w: w, h: h, file: f)
        store.update(id) { $0.pages[pageIndex].items.append(item) }
        showTools = false; selected = item.id
    }
    private func addText() {
        guard let doc, doc.pages.indices.contains(pageIndex) else { return }
        let item = NoteItem(kind: "text", x: 0.1, y: 0.15, w: 0.6, h: 0.15, text: "")
        store.update(id) { $0.pages[pageIndex].items.append(item) }
        showTools = false; selected = item.id; editing = item
    }
    private func addPage(style: String? = nil) {
        guard let doc else { return }
        let base = doc.pages.indices.contains(pageIndex) ? doc.pages[pageIndex] : nil
        let p = NotePage(style: style ?? (base?.src == nil ? base?.style ?? "lined" : "lined"), size: base?.size ?? [595, 842])
        store.update(id) { $0.pages.insert(p, at: min(pageIndex + 1, $0.pages.count)) }
        current = p.id
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            PadButton()
            Button { showTools.toggle() } label: {
                Label(showTools ? "隐藏笔盘" : "笔盘", systemImage: showTools ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
            }
            Menu {
                Button { addText() } label: { Label("文本框", systemImage: "textformat") }
                Button { imgSource = .photos } label: { Label("照片", systemImage: "photo") }
                Button { imgSource = .files } label: { Label("文件里的图片 / PDF", systemImage: "folder") }
                if UIImagePickerController.isSourceTypeAvailable(.camera) { Button { camera = true } label: { Label("拍照", systemImage: "camera") } }
                Divider()
                Menu {
                    ForEach(NotePaper.allCases) { s in Button(s.name) { addPage(style: s.rawValue) } }
                } label: { Label("在后面加一页", systemImage: "plus.rectangle.on.rectangle") }
            } label: { Image(systemName: "plus.circle") }
            Button { showQuiz = true } label: { Image(systemName: "sparkles.rectangle.stack") }.accessibilityLabel("根据此 PDF 出题")
            Button { showPages = true } label: { Image(systemName: "square.grid.2x2") }.accessibilityLabel("页面")
            Menu {
                Button { field = doc?.title ?? ""; rename = true } label: { Label("重命名", systemImage: "pencil") }
                Section("导出") {
                    Button { share = NoteExport.flattened(id).map { ShareItem(url: $0) } } label: { Label("PDF（含手写、图片和文本框）", systemImage: "doc.richtext") }
                    Button { share = NoteExport.original(id).map { ShareItem(url: $0) } } label: { Label("原始 PDF", systemImage: "doc") }
                    Button { share = NoteExport.bundle(id).map { ShareItem(url: $0) } } label: { Label("完整导出包（可再导入）", systemImage: "shippingbox") }
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }
}

// MARK: - One page

struct NotePageView: View {
    let docID: String
    let page: NotePage
    let tool: NoteTool
    let showTools: Bool
    @Binding var selected: String?
    @Binding var editing: NoteItem?
    var zoom: CGFloat = 1
    @State private var bg: UIImage?
    /// Background pixels = view width × screen scale × zoom (re-rendered in steps so zooming stays sharp).
    private func bgWidth(_ W: CGFloat) -> CGFloat {
        let z = max(1, pow(2, ceil(log2(max(1, zoom)))))
        return min(4000, W * UIScreen.main.scale * z)
    }

    var body: some View {
        GeometryReader { g in
            let W = g.size.width
            ZStack(alignment: .topLeading) {
                if let bg { Image(uiImage: bg).resizable() } else { Color.white }
                ForEach(page.items) { it in
                    NoteItemView(docID: docID, pageID: page.id, item: it, W: W, active: tool == .select, selected: $selected, editing: $editing)
                }
                NoteCanvas(key: NoteStore.inkKey(docID, page.id), title: NoteStore.shared.docs[docID]?.title ?? "", enabled: tool == .pen, tools: showTools)
                    .id(Int(W))
                    .allowsHitTesting(tool == .pen)
            }
            .onTapGesture { if tool == .select { selected = nil } }
            .task(id: "\(Int(W))|\(Int(bgWidth(W)))") { if W > 10 { bg = NoteRender.cachedBackground(docID, page, width: bgWidth(W)) } }
        }
        .aspectRatio(CGFloat(1 / page.aspect), contentMode: .fit)
        .clipShape(Rectangle())
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

struct NoteItemView: View {
    let docID: String
    let pageID: String
    let item: NoteItem
    let W: CGFloat
    let active: Bool
    @Binding var selected: String?
    @Binding var editing: NoteItem?
    @State private var drag: CGSize = .zero
    @State private var grow: CGSize = .zero

    private var isSel: Bool { active && selected == item.id }

    var body: some View {
        let w = max(30, item.w * W + grow.width), h = max(24, item.h * W + grow.height)
        content
            .frame(width: w, height: h, alignment: .topLeading)
            .clipped()
            .overlay { if isSel { Rectangle().stroke(Color.accentColor, lineWidth: 2) } }
            .overlay(alignment: .bottomTrailing) {
                if isSel {
                    Circle().fill(Color.accentColor).frame(width: 22, height: 22).offset(x: 11, y: 11)
                        .gesture(DragGesture().onChanged { v in
                            if item.kind == "image" { let r = item.h / max(0.001, item.w); grow = CGSize(width: v.translation.width, height: v.translation.width * r) }
                            else { grow = v.translation }
                        }.onEnded { _ in commit { $0.w = Double(w / W); $0.h = Double(h / W) }; grow = .zero })
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSel {
                    HStack(spacing: 6) {
                        if item.kind == "text" { Button { editing = item } label: { Image(systemName: "pencil") } }
                        Button(role: .destructive) { delete() } label: { Image(systemName: "trash") }
                    }
                    .font(.callout).padding(6).background(.regularMaterial, in: Capsule()).offset(y: -36)
                }
            }
            .offset(x: item.x * W + drag.width, y: item.y * W + drag.height)
            .gesture(active ? DragGesture(minimumDistance: 4).onChanged { v in selected = item.id; drag = v.translation }
                .onEnded { v in
                    commit { $0.x = max(-0.2, min(0.95, $0.x + Double(v.translation.width / W))); $0.y = max(-0.2, $0.y + Double(v.translation.height / W)) }
                    drag = .zero
                } : nil)
            .onTapGesture(count: 2) { if active && item.kind == "text" { editing = item } }
            .onTapGesture { if active { selected = item.id } }
            .allowsHitTesting(active)
    }

    @ViewBuilder private var content: some View {
        if item.kind == "image" {
            if let im = NoteStore.shared.image(docID, item.file) { Image(uiImage: im).resizable() } else { Color.gray.opacity(0.2) }
        } else {
            let t = item.text ?? ""
            Group {
                if t.isEmpty { Text("文本框").foregroundStyle(.secondary).font(.system(size: max(9, W / 42))) }
                else { MathText(text: t, size: max(9, W / 42), color: .black) }
            }
            .padding(4)
            .background(Color.white.opacity(isSel ? 0.9 : 0.001))
        }
    }

    private func commit(_ f: (inout NoteItem) -> Void) {
        NoteStore.shared.update(docID) { d in
            guard let p = d.pages.firstIndex(where: { $0.id == pageID }), let i = d.pages[p].items.firstIndex(where: { $0.id == item.id }) else { return }
            f(&d.pages[p].items[i])
        }
    }
    private func delete() {
        NoteStore.shared.update(docID) { d in
            guard let p = d.pages.firstIndex(where: { $0.id == pageID }) else { return }
            d.pages[p].items.removeAll { $0.id == item.id }
        }
        selected = nil
    }
}

struct NoteTextEditor: View {
    let docID: String
    let item: NoteItem
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.body.monospaced()).scrollContentBackground(.hidden)
                .padding(10).frame(minHeight: 160)
                .background(Color.secondary.opacity(0.08))
            Divider()
            ScrollView { MathText(text: text.isEmpty ? "预览：支持 **粗体**、列表和 $LaTeX$" : text, size: 17).padding() }
        }
        .navigationTitle("文本框").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    NoteStore.shared.update(docID) { d in
                        for p in d.pages.indices { if let i = d.pages[p].items.firstIndex(where: { $0.id == item.id }) { d.pages[p].items[i].text = text } }
                    }
                    dismiss()
                }.bold()
            }
        }
        .onAppear { text = item.text ?? "" }
    }
}

/// Ink for one note page, stored at a fixed logical width so it survives resizing.
struct NoteCanvas: UIViewRepresentable {
    let key: String
    let title: String
    let enabled: Bool
    let tools: Bool

    func makeCoordinator() -> Coord { Coord(self) }
    func makeUIView(context: Context) -> PKCanvasView {
        let v = QuietCanvas()
        v.backgroundColor = .clear; v.isOpaque = false
        v.overrideUserInterfaceStyle = .light   // white paper: ink colours stay true in dark mode
        v.drawingPolicy = .default
        v.isScrollEnabled = false
        v.delegate = context.coordinator
        context.coordinator.canvas = v
        let picker = CanvasRep.sharedPicker
        picker.addObserver(v)
        v.tool = picker.selectedTool
        context.coordinator.picker = picker
        DispatchQueue.main.async { context.coordinator.load() }
        let link = PadLink("note:" + key, canvas: v)
        link.host = { [weak v] in v?.layer }
        link.k = { [weak v] in (v?.bounds.width ?? NoteRender.logicalWidth) / NoteRender.logicalWidth }
        context.coordinator.link = link
        // 笔盘 on at open: show it without waiting for a first stroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak v, weak c = context.coordinator] in
            guard let v, let c, v.window != nil, c.parent.enabled, c.parent.tools else { return }
            if !NoteCanvas.anyActive { c.picker?.setVisible(true, forFirstResponder: v); v.becomeFirstResponder(); c.lastTouched = true }
        }
        return v
    }
    /// True when some note canvas already owns the 笔盘.
    static var anyActive: Bool {
        guard let w = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.keyWindow else { return false }
        func find(_ v: UIView) -> Bool { (v is PKCanvasView && v.isFirstResponder) || v.subviews.contains(where: find) }
        return find(w)
    }
    func updateUIView(_ v: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        v.isUserInteractionEnabled = enabled
        if v.bounds.width > 10 && context.coordinator.loadedWidth != v.bounds.width { context.coordinator.load() }
        if v.window != nil {
            if enabled && tools { context.coordinator.picker?.colorUserInterfaceStyle = .light; context.coordinator.picker?.overrideUserInterfaceStyle = .light }
            context.coordinator.picker?.setVisible(enabled && tools, forFirstResponder: v)
            if !enabled && v.isFirstResponder { v.resignFirstResponder() }
        }
    }
    static func dismantleUIView(_ v: PKCanvasView, coordinator: Coord) {
        coordinator.link?.tearDown(); coordinator.link = nil
        coordinator.save()
        coordinator.picker?.removeObserver(v)
        coordinator.picker?.colorUserInterfaceStyle = .unspecified
        coordinator.picker?.overrideUserInterfaceStyle = .unspecified
    }

    final class Coord: NSObject, PKCanvasViewDelegate {
        var parent: NoteCanvas
        weak var canvas: PKCanvasView?
        var picker: PKToolPicker?
        var loadedWidth: CGFloat = 0
        var loading = false
        private var pending: DispatchWorkItem?
        init(_ p: NoteCanvas) {
            parent = p
            super.init()
            NotificationCenter.default.addObserver(forName: .noteInkFlush, object: nil, queue: nil) { [weak self] _ in self?.save() }
            PickerRestore.observe(self) { [weak self] in
                guard let self, self.parent.enabled, self.parent.tools, let v = self.canvas, v.window != nil, self.lastTouched, !DSInput.holding else { return }
                self.picker?.setVisible(true, forFirstResponder: v); v.becomeFirstResponder()
            }
        }
        var lastTouched = false
        var link: PadLink?

        func load() {
            guard let v = canvas, v.bounds.width > 10 else { return }
            loading = true
            loadedWidth = v.bounds.width
            let k = v.bounds.width / NoteRender.logicalWidth
            v.drawing = (PDFInk.load(parent.key, 0) ?? PKDrawing()).transformed(using: CGAffineTransform(scaleX: k, y: k))
            loading = false
        }
        func save() {
            guard let v = canvas, loadedWidth > 10 else { return }
            let k = NoteRender.logicalWidth / loadedWidth
            PDFInk.save(parent.key, 0, v.drawing.transformed(using: CGAffineTransform(scaleX: k, y: k)), title: parent.title, width: NoteRender.logicalWidth)
            if v.drawing.strokes.isEmpty { try? FileManager.default.removeItem(at: PDFInk.dir(parent.key).appendingPathComponent("0.w")) }
        }
        func canvasViewDrawingDidChange(_ v: PKCanvasView) {
            guard !loading else { return }
            link?.changed(v.drawing)
            pending?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.save() }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
        }
        func canvasViewDidBeginUsingTool(_ v: PKCanvasView) {
            lastTouched = true
            if parent.tools && !DSInput.holding { picker?.setVisible(true, forFirstResponder: v); v.becomeFirstResponder() }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void
    func makeCoordinator() -> Coord { Coord(done) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let v = UIImagePickerController(); v.sourceType = .camera; v.delegate = context.coordinator; return v
    }
    func updateUIViewController(_ v: UIImagePickerController, context: Context) {}
    final class Coord: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(_ d: @escaping (UIImage?) -> Void) { done = d }
        func imagePickerController(_ p: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { done(info[.originalImage] as? UIImage) }
        func imagePickerControllerDidCancel(_ p: UIImagePickerController) { done(nil) }
    }
}

// MARK: - Pages sheet (thumbnails, reorder, delete, add)

struct NotePagesSheet: View {
    let id: String
    @Binding var current: String?
    @State private var store = NoteStore.shared
    @State private var confirm: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let pages = store.docs[id]?.pages ?? []
        List {
            ForEach(Array(pages.enumerated()), id: \.element.id) { i, p in
                Button { current = p.id; dismiss() } label: {
                    HStack(spacing: 14) {
                        NoteThumb(id: id, page: p).frame(width: 70, height: 70 * p.aspect)
                        VStack(alignment: .leading) {
                            Text("第 \(i + 1) 页").font(.headline)
                            Text(p.src != nil ? "导入的页面" : (NotePaper(rawValue: p.style)?.name ?? "") + "纸").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if p.id == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions { if pages.count > 1 { Button("删除", role: .destructive) { confirm = p.id } } }
            }
            .onMove { from, to in store.update(id) { $0.pages.move(fromOffsets: from, toOffset: to) } }
            .listRowBackground(Color.cardBackground)
            Section {
                Menu {
                    ForEach(NotePaper.allCases) { s in
                        Button(s.name) {
                            let p = NotePage(style: s.rawValue, size: pages.last?.size ?? [595, 842])
                            store.update(id) { $0.pages.append(p) }
                        }
                    }
                } label: { Label("在最后加一页", systemImage: "plus") }
            }
            .listRowBackground(Color.cardBackground)
        }
        .appList()
        .environment(\.editMode, .constant(.active))
        .navigationTitle("页面（\(pages.count)）").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.bold() } }
        .confirmationDialog("删除这一页？上面的手写、图片和文本框也会删除。", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let c = confirm { store.deletePage(id, c); if current == c { current = nil } }; confirm = nil }
        }
    }
}

// MARK: - Export

enum NoteExport {
    private static func url(_ id: String, _ suffix: String, _ ext: String) -> URL {
        let n = (NoteStore.shared.docs[id]?.title ?? "note").replacingOccurrences(of: "/", with: "-")
        return ImpExport.out.appendingPathComponent(n + suffix + "." + ext)
    }
    private static func render(_ id: String, overlay: Bool, to u: URL) -> URL? {
        NotificationCenter.default.post(name: .noteInkFlush, object: nil)   // save ink still waiting on the debounce
        guard let d = NoteStore.shared.docs[id] else { return nil }
        let r = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        do {
            try r.writePDF(to: u) { ctx in
                for p in d.pages {
                    let rect = CGRect(x: 0, y: 0, width: p.size[0], height: p.size[1])
                    ctx.beginPage(withBounds: rect, pageInfo: [:])
                    let cg = ctx.cgContext
                    if let s = p.src, let pg = NoteStore.shared.base(id)?.page(at: s) {
                        let b = pg.bounds(for: .mediaBox)
                        cg.saveGState(); cg.translateBy(x: 0, y: rect.height); cg.scaleBy(x: rect.width / max(1, b.width), y: -rect.height / max(1, b.height))
                        pg.draw(with: .mediaBox, to: cg); cg.restoreGState()
                    } else {
                        NoteRender.drawPaper(p.style, in: rect, cg)
                    }
                    if overlay { NoteRender.overlay(id, p, in: rect) }
                }
            }
        } catch { return nil }
        return u
    }
    static func flattened(_ id: String) -> URL? { render(id, overlay: true, to: url(id, "", "pdf")) }
    static func original(_ id: String) -> URL? {
        guard let d = NoteStore.shared.docs[id] else { return nil }
        if d.hasBase {
            let u = url(id, "（原始）", "pdf")
            try? FileManager.default.removeItem(at: u)
            try? FileManager.default.copyItem(at: NoteStore.baseURL(id), to: u)
            return u
        }
        return render(id, overlay: false, to: url(id, "（原始）", "pdf"))
    }
    static func bundle(_ id: String) -> URL? {
        guard let d = NoteBundle.make(id) else { return nil }
        let u = url(id, "", "prismpaper")
        try? d.write(to: u, options: .atomic)
        return u
    }
}

/// Full note export in the same `.prismpaper` file type (kind "note"); re-import from 笔记 or 导入的试卷 › 文件.
enum NoteBundle {
    struct B: Codable { var kind = "note"; var v = 1; var doc: NoteDoc; var base: Data?; var images: [String: Data]; var ink: [String: Data] }

    static func make(_ id: String) -> Data? {
        guard let d = NoteStore.shared.docs[id] else { return nil }
        var images: [String: Data] = [:], ink: [String: Data] = [:]
        for p in d.pages {
            for it in p.items { if let f = it.file, let x = try? Data(contentsOf: NoteStore.imgURL(id, f)) { images[f] = x } }
            if let x = try? Data(contentsOf: PDFInk.dir(NoteStore.inkKey(id, p.id)).appendingPathComponent("0.drawing")) { ink[p.id] = x }
        }
        return try? JSONEncoder().encode(B(doc: d, base: d.hasBase ? try? Data(contentsOf: NoteStore.baseURL(id)) : nil, images: images, ink: ink))
    }

    @discardableResult
    static func restore(_ data: Data) -> String? {
        guard var b = try? JSONDecoder().decode(B.self, from: data), b.kind == "note" else { return nil }
        if NoteStore.shared.docs[b.doc.id] != nil { b.doc.id = UUID().uuidString; b.doc.title += "（导入）" }
        let id = b.doc.id
        try? FileManager.default.createDirectory(at: NoteStore.dir(id).appendingPathComponent("img"), withIntermediateDirectories: true)
        if let x = b.base { try? x.write(to: NoteStore.baseURL(id)) }
        for (f, x) in b.images { try? x.write(to: NoteStore.imgURL(id, f)) }
        for (pid, x) in b.ink {
            let k = NoteStore.inkKey(id, pid)
            if let dr = try? PKDrawing(data: x) { PDFInk.save(k, 0, dr, title: b.doc.title, width: NoteRender.logicalWidth) }
        }
        NoteStore.shared.save(b.doc, touch: false)
        Task { await SyncManager.shared.sync() }
        return id
    }
}

// MARK: - Storage

struct NotesStorageSection: View {
    @State private var store = NoteStore.shared
    @State private var confirmAll = false
    var body: some View {
        Section {
            if store.docs.isEmpty { Text("没有笔记").foregroundStyle(.secondary) }
            ForEach(store.sorted) { n in
                LabeledContent(n.title, value: ByteCountFormatter.string(fromByteCount: Int64(store.size(n.id)), countStyle: .file))
                    .swipeActions { Button("删除", role: .destructive) { store.delete(n.id) } }
            }
            if !store.docs.isEmpty { Button("全部删除", role: .destructive) { confirmAll = true } }
        } header: { Text("笔记") } footer: { Text("笔记的页面、手写、图片和文本框只存在这台设备，不会自动删除。标题和文件夹会同步。") }
        .listRowBackground(Color.cardBackground)
        .confirmationDialog("删除所有笔记？", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("全部删除", role: .destructive) { store.docs.keys.forEach { store.delete($0) } }
        }
    }
}

extension Notification.Name { static let noteInkFlush = Notification.Name("noteInkFlush") }
