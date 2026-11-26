import SwiftUI
import PDFKit
import PencilKit
import Observation

// MARK: - Data (bundled: Resources/math/math.json, vis/*.png, pdf/*.pdf)

struct MRegion: Codable, Hashable { let p: Int; let b: [Double] }
struct MPair: Codable, Hashable { let ex: String; let why: String }
struct MVisTable: Codable, Hashable { let head: String; let rows: [[String]] }
struct MVis: Codable, Hashable { let img: String?; let tab: MVisTable? }

struct MCard: Codable, Hashable, Identifiable {
    let id: String
    let sec: String?
    let st: String?
    let k: String?
    let t: String?
    let s: String?
    let ex: String?
    let rem: String?
    let wo: String?
    let nf: Bool?
    let lvl: String?
    let ki: String?
    let term: String?
    let pos: MPair?
    let neg: MPair?
    let vis: [MVis]?
}

struct MItem: Codable, Hashable, Identifiable {
    let id: String
    let ty: String          // example | drill | class
    let l: String
    let sec: String?
    let st: String?
    let lvl: String?
    let nf: Bool?
    let pg: String?
    let sk: String?
    let q: [MRegion]?
    let s: [MRegion]?
    let a: [MRegion]?
    let f: [MRegion]?
    let `as`: String?
    let qt: String?
    let stx: String?
    let at: String?
    let sx: String?
    let fi: [String]?
    var hasText: Bool { !(qt ?? "").isEmpty }
    var figImages: [UIImage] { (fi ?? []).compactMap { MathLibrary.resource($0, "fig").flatMap { UIImage(contentsOfFile: $0.path) } } }
    var isPractice: Bool { ty != "example" }
}

struct MKeyIdea: Codable, Hashable { let id: String; let t: String; let s: String }

struct MSetInfo: Codable, Hashable, Identifiable { let id: String; let kind: String; let l: String; let t: String; let n: Int; let qids: [String] }

struct MChapter: Codable, Hashable, Identifiable {
    let id: String
    let n: Int
    let t: String
    let book: String
    let pdf: String
    var notes = ""          // 中文: 範文 notes PDF, e.g. "zh/pdf/z-lunren.pdf" (download group "zhpdf-<id>")
    var ki: [MKeyIdea]
    var cards: [MCard]
    var items: [MItem]
    var nc: Int
    var ne: Int
    var np: Int
    var sets: [MSetInfo]
    var nCards: Int { cards.isEmpty ? nc : cards.count }
    var nExamples: Int { items.isEmpty ? ne : examples.count }
    var nPractice: Int { items.isEmpty ? np : practice.count }

    enum K: String, CodingKey { case id, n, t, book, pdf, notes, ki, cards, items, nc, ne, np, sets }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id); n = try c.decode(Int.self, forKey: .n)
        t = try c.decode(String.self, forKey: .t); book = try c.decode(String.self, forKey: .book)
        pdf = try c.decodeIfPresent(String.self, forKey: .pdf) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        ki = try c.decodeIfPresent([MKeyIdea].self, forKey: .ki) ?? []
        cards = try c.decodeIfPresent([MCard].self, forKey: .cards) ?? []
        items = try c.decodeIfPresent([MItem].self, forKey: .items) ?? []
        nc = try c.decodeIfPresent(Int.self, forKey: .nc) ?? 0
        ne = try c.decodeIfPresent(Int.self, forKey: .ne) ?? 0
        np = try c.decodeIfPresent(Int.self, forKey: .np) ?? 0
        sets = try c.decodeIfPresent([MSetInfo].self, forKey: .sets) ?? []
    }
    /// Chinese 範文 chapters have no chapter number in their title.
    var isZh: Bool { id.hasPrefix("z-") }
    var isChem: Bool { id.hasPrefix("c-") }
    /// Subject id for DeepSeek / recents ("math", "zh", "chem").
    var subjectID: String { isZh ? "zh" : (isChem ? "chem" : "math") }
    var label: String { isZh ? t : "Ch\(n) \(t)" }
    var examples: [MItem] { items.filter { !$0.isPractice } }
    var practice: [MItem] { items.filter { $0.isPractice } }
}

struct MBook: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let nameZh: String
    var chs: [MChapter]
    /// Subject this book belongs to ("math" when absent; "zh" for Chinese 範文).
    var subj: String? = nil
    var subject: String { subj ?? "math" }
}
private struct MChapterBody: Codable { let cards: [MCard]; let items: [MItem]; let ki: [MKeyIdea] }

private struct MFile: Codable { let v: Int; let books: [MBook] }

@Observable
final class MathLibrary {
    static let shared = MathLibrary()
    var books: [MBook] = []
    private var loaded: Set<String> = []
    init() { reload() }
    func reload() {
        if let u = MathContent.shared.local("math.json"), let d = try? Data(contentsOf: u), let f = try? JSONDecoder().decode(MFile.self, from: d) {
            var all = f.books
            // Chinese 範文 share the same content pipeline (zh.json + ch/z-*.json + mc/z-*.json).
            if let zu = MathContent.shared.local("zh.json"), let zd = try? Data(contentsOf: zu), let zf = try? JSONDecoder().decode(MFile.self, from: zd) {
                all += zf.books.map { var b = $0; b.subj = "zh"; return b }
            }
            // Chemistry uses the same pipeline (chem.json + ch/chem-*.json + mc/chem-*.json).
            if let cu = MathContent.shared.local("chem.json"), let cd = try? Data(contentsOf: cu), let cf = try? JSONDecoder().decode(MFile.self, from: cd) {
                all += cf.books.map { var b = $0; b.subj = "chem"; return b }
            }
            books = all
            let l = loaded; loaded = []
            for g in l { reloadChapter(g) }
        }
    }
    func isLoaded(_ id: String) -> Bool { loaded.contains(id) }
    func reloadChapter(_ id: String) {
        guard let u = MathContent.shared.local("ch/\(id).json"), let d = try? Data(contentsOf: u),
              let body = try? JSONDecoder().decode(MChapterBody.self, from: d) else { return }
        for bi in books.indices {
            if let ci = books[bi].chs.firstIndex(where: { $0.id == id }) {
                books[bi].chs[ci].cards = body.cards
                books[bi].chs[ci].items = body.items
                books[bi].chs[ci].ki = body.ki
            }
        }
        loaded.insert(id)
    }
    func unloadChapter(_ id: String) {
        for bi in books.indices {
            if let ci = books[bi].chs.firstIndex(where: { $0.id == id }) {
                books[bi].chs[ci].cards = []; books[bi].chs[ci].items = []; books[bi].chs[ci].ki = []
            }
        }
        loaded.remove(id)
    }
    var chapters: [MChapter] { books.flatMap { $0.chs } }
    static func title(_ subj: String, _ T: Tr) -> String {
        switch subj {
        case "zh": return T("Chinese", "中文")
        case "chem": return T("Chemistry", "化学")
        default: return T("Maths", "数学")
        }
    }
    func books(_ subject: String) -> [MBook] { books.filter { $0.subject == subject } }
    func chapters(_ subject: String) -> [MChapter] { books(subject).flatMap { $0.chs } }
    func chapter(_ id: String) -> MChapter? { chapters.first { $0.id == id } }
    func item(_ id: String) -> (MChapter, MItem)? {
        for c in chapters { if let i = c.items.first(where: { $0.id == id }) { return (c, i) } }
        return nil
    }
    static func resource(_ name: String, _ sub: String) -> URL? {
        MathContent.shared.local(sub.isEmpty ? name : sub + "/" + name)
    }
}

// MARK: - Book PDF regions (rendered on device with PDFKit)

enum PDFRegions {
    private static var docs: [String: PDFDocument] = [:]
    private static let cache = NSCache<NSString, UIImage>()

    static func doc(_ name: String) -> PDFDocument? {
        if let d = docs[name] { return d }
        guard !name.isEmpty, let u = MathLibrary.resource(name, "pdf"), let d = PDFDocument(url: u) else { return nil }
        docs[name] = d
        return d
    }

    /// Crops one region (normalized, top-left origin) from a page at the given scale.
    static func image(_ pdf: String, _ r: MRegion, scale: CGFloat = 3) -> UIImage? {
        let key = "\(pdf)|\(r.p)|\(r.b)|\(scale)" as NSString
        if let i = cache.object(forKey: key) { return i }
        guard r.b.count == 4, let d = doc(pdf), let page = d.page(at: r.p - 1) else { return nil }
        let box = page.bounds(for: .cropBox)
        let x0 = CGFloat(r.b[0]) * box.width, y0 = CGFloat(r.b[1]) * box.height
        let w = CGFloat(r.b[2] - r.b[0]) * box.width, h = CGFloat(r.b[3] - r.b[1]) * box.height
        guard w > 1, h > 1 else { return nil }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let cg = ctx.cgContext
            // PDF space is bottom-left; flip and move the region to the origin.
            cg.translateBy(x: -x0, y: box.height - y0)
            cg.scaleBy(x: 1, y: -1)
            cg.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .cropBox, to: cg)
        }
        cache.setObject(img, forKey: key)
        return img
    }
}

/// Stacked region crops on white "paper".
struct RegionStack: View {
    let pdf: String
    let regions: [MRegion]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(regions.enumerated()), id: \.offset) { _, r in
                if let img = PDFRegions.image(pdf, r) {
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(img.size, contentMode: .fit)
                }
            }
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Books / chapters

struct MathBookListView: View {
    var subj = "math"
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    private let lib = MathLibrary.shared
    var body: some View {
        List {
            MathContentBanner()
            RecentSection(section: .learn, subject: subj)
            Section {
                ForEach(lib.books(subj)) { b in
                    NavigationLink(value: Route.mathBook(b.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(T(b.name, b.nameZh)).font(.headline)
                            let n = b.chs.filter { prog.learned.contains($0.id) }.count
                            Text(subj == "zh" ? "\(b.chs.count) 篇 · 已學 \(n) 篇" : T("\(b.chs.count) chapters · \(n) learned", "\(b.chs.count) 章 · 已学 \(n) 章"))
                                .font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: Double(n), total: Double(max(b.chs.count, 1))).tint(.green)
                        }
                        .padding(.vertical, 3)
                    }
                    .listRowBackground(Color.cardBackground)
                }
            } footer: {
                if subj != "zh" { Text(T("More chapters will be added.", "之后会加入更多章节。")) }
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(MathLibrary.title(subj, T))
    }
}

struct MathBookView: View {
    let bookID: String
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    @State private var selecting = false
    private let lib = MathLibrary.shared
    var body: some View {
        if let b = lib.books.first(where: { $0.id == bookID }) {
            List {
                Section {
                    ForEach(b.chs) { c in
                        let learned = prog.learned.contains(c.id)
                        Group {
                            if selecting {
                                Button { withAnimation { prog.toggleLearned(c.id) } } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: learned ? "checkmark.circle.fill" : "circle")
                                            .font(.title2).foregroundStyle(learned ? Color.green : Color.secondary)
                                        row(c)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink(value: Route.mathChapter(c.id)) {
                                    HStack { row(c); Spacer(); if learned { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.green) } }
                                }
                                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in withAnimation { selecting = true } })
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                } footer: {
                    Text(selecting ? T("Tick the chapters you've learned, then tap Done.", "勾选已学的章节，然后点「完成」。")
                                   : T("Tap Select or long-press a chapter to mark chapters as learned.", "点「选择」或长按章节，可以标记已学。"))
                }
            }
            .listStyle(.insetGrouped)
            .appList()
            .navigationTitle(T(b.name, b.nameZh))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .confirmationAction) { Button(T("Done", "完成")) { withAnimation { selecting = false } }.bold() }
                } else {
                    ToolbarItem(placement: .primaryAction) { Button(T("Select", "选择")) { withAnimation { selecting = true } } }
                }
            }
        } else {
            ContentUnavailableView(T("Not found", "找不到"), systemImage: "questionmark")
        }
    }
    private func row(_ c: MChapter) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(c.label)
            Text(c.isZh ? "\(c.nCards) 張卡 · \(c.nPractice) 題練習 · \(c.sets.reduce(0) { $0 + $1.n }) 道選擇題" : "\(c.nCards) \(T("cards", "卡")) · \(c.nExamples) \(T("examples", "例题")) · \(c.nPractice) \(T("practice", "练习"))\(MathContent.shared.isDownloaded(c.id) ? "" : " · " + T("not downloaded", "未下载"))")
                .font(.caption).foregroundStyle(.secondary)
            let read = (0..<c.nCards).filter { prog.seen.contains("\(c.id)-\($0)") }.count
            if read > 0 { ProgressView(value: Double(read), total: Double(max(c.nCards, 1))) }
        }
    }
}

struct MathChapterView: View {
    let chapterID: String
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    @AppStorage("math.chapterTab") private var tab = 0
    @AppStorage("math.practice.wrongOnly") private var wrongOnly = false
    private let lib = MathLibrary.shared

    var body: some View {
        if let c = lib.chapter(chapterID) {
            List {
                Section {
                    Picker("", selection: $tab) {
                        Text(T("Cards", "知识卡")).tag(0)
                        Text(T("Practice", "练习")).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if tab == 0 { cards(c) } else { practice(c) }
                if c.isZh || c.isChem {
                    Section {
                        if c.isChem { ChemLongRows(chapterID: c.id) }
                        else {
                            NavigationLink { ZhLongSetView(chapterID: c.id) } label: {
                                Label(T("Long-answer questions", "長答題（短答 / 長答）"), systemImage: "text.alignleft")
                            }
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
                DSMasterySection(chapterID: c.id)
                Section {
                    Button {
                        prog.toggleLearned(c.id)
                    } label: {
                        Label(prog.learned.contains(c.id) ? T("Learned", "已学") : T("Mark as learned", "标记为已学"),
                              systemImage: prog.learned.contains(c.id) ? "checkmark.circle.fill" : "circle")
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
            .listStyle(.insetGrouped)
            .appList()
            .navigationTitle(c.label)
            .navigationBarTitleDisplayMode(.inline)
            .noteRecent(.chapter(c.id), c.label, c.isZh ? T("Chinese", "中文") : T("Maths", "数学"))
            .overlay { if MathContent.shared.loading.contains(c.id) { DownloadOverlay() } }
            .task { await MathContent.shared.ensure(c.id) }
        } else {
            ContentUnavailableView(T("Not found", "找不到"), systemImage: "questionmark")
        }
    }

    @ViewBuilder private func cards(_ c: MChapter) -> some View {
        let groups = sections(c.cards.map { ($0.sec ?? "", $0.st ?? "") })
        ForEach(groups, id: \.0) { g in
            Section {
                ForEach(Array(c.cards.enumerated()).filter { ($0.element.sec ?? "") == g.0 }, id: \.element.id) { j, k in
                    NavigationLink(value: Route.mathCards(c.id, j)) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(j + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
                            MathText(text: k.t ?? "", size: 16)
                            if prog.seen.contains("\(c.id)-\(j)") { Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            } header: { Text(g.1.isEmpty ? g.0 : "\(g.0) \(g.1)") }
        }
    }

    @ViewBuilder private func practice(_ c: MChapter) -> some View {
        if c.items.isEmpty {
            Section { Text(T("Practice for this chapter is coming soon.", "本章练习稍后加入。")).foregroundStyle(.secondary).listRowBackground(Color.cardBackground) }
        }
        let wrong = c.items.filter { prog.mark(MathItemKey.key(c, $0)) == false }
        if !c.items.isEmpty {
            Section {
                Toggle(isOn: $wrongOnly) {
                    Label(T("Only marked wrong (\(wrong.count))", "只看标错的（\(wrong.count)）"), systemImage: "xmark.circle")
                }
            }
            .listRowBackground(Color.cardBackground)
        }
        let shown = wrongOnly ? wrong : c.items
        let groups = sections(shown.map { ($0.sec ?? "", $0.st ?? "") })
        ForEach(groups, id: \.0) { g in
            Section {
                ForEach(shown.filter { ($0.sec ?? "") == g.0 }) { it in
                    NavigationLink(value: Route.mathItem(it.id)) {
                        HStack(spacing: 12) {
                            Image(systemName: it.isPractice ? (it.ty == "drill" ? "pencil.and.scribble" : "square.and.pencil") : "book")
                                .foregroundStyle(it.isPractice ? Color.accentColor : .secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label(it)).font(.body)
                                if let s = it.sk, !s.isEmpty { MathText(text: s, size: 13, color: .secondary) }
                            }
                            Spacer()
                            if let m = prog.mark(MathItemKey.key(c, it)) {
                                Image(systemName: m ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(m ? Color.good : Color.bad)
                            }
                            if ScratchStore.shared.has(it.id) { Image(systemName: "scribble").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            } header: { Text(g.1.isEmpty ? g.0 : "\(g.0) \(g.1)") }
        }
    }

    private func label(_ it: MItem) -> String {
        var s = it.l
        if let p = it.pg, !p.isEmpty { s += " · p.\(p)" }
        return s
    }

    private func sections(_ xs: [(String, String)]) -> [(String, String)] {
        var seen = Set<String>(); var out: [(String, String)] = []
        for x in xs where !seen.contains(x.0) { seen.insert(x.0); out.append(x) }
        return out
    }
}

// MARK: - Knowledge cards

struct MathCardPager: View {
    let chapterID: String
    let start: Int
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    @State private var index: Int?
    private let lib = MathLibrary.shared

    @AppStorage("zh.notesMode") private var mode = "pdf"

    var body: some View {
        if let c = lib.chapter(chapterID), !c.notes.isEmpty {
            Group {
                if mode == "pdf" { ZhNotesPDF(chapter: c) } else { cardsBody }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $mode) { Text("笔记 PDF").tag("pdf"); Text("知识卡").tag("cards") }
                        .pickerStyle(.segmented).frame(width: 200)
                }
            }
        } else {
            cardsBody
        }
    }

    @ViewBuilder private var cardsBody: some View {
        if let c = lib.chapter(chapterID), c.cards.isEmpty {
            DownloadOverlay().task { await MathContent.shared.ensure(c.id) }
        } else if let c = lib.chapter(chapterID), !c.cards.isEmpty {
            let i = min(max(index ?? start, 0), c.cards.count - 1)
            TabView(selection: Binding(get: { i }, set: { index = $0 })) {
                ForEach(Array(c.cards.enumerated()), id: \.offset) { j, k in
                    ScrollView {
                        MathCardContent(card: k, position: "\(j + 1)/\(c.cards.count)", idea: c.ki.first { $0.id == k.ki })
                            .frame(maxWidth: 760)
                            .padding(.vertical)
                            .readingMargin()
                            .frame(maxWidth: .infinity)
                    }
                    .softEdges()
                    .tag(j)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .appScreen()
            .navigationTitle(c.label)
            .navigationBarTitleDisplayMode(.inline)
            .pageNav {
                PageCluster(index: i, count: c.cards.count,
                            prev: i > 0 ? { index = i - 1 } : nil,
                            next: i < c.cards.count - 1 ? { index = i + 1 } : nil)
            }
            .onAppear { prog.seen.insert("\(c.id)-\(i)") }
            .onChange(of: i) { _, n in prog.seen.insert("\(c.id)-\(n)") }
            .deepSeek(DSContext.mathCard(c, i))
            .task { await MathContent.shared.ensure(c.id) }
            .noteRecent(.mathCards(c.id, i), c.label, T("Card \(i + 1) of \(c.cards.count)", "第 \(i + 1)/\(c.cards.count) 张"))
        } else {
            ContentUnavailableView(T("Not found", "找不到"), systemImage: "questionmark")
        }
    }
}

struct MathCardContent: View {
    let card: MCard
    let position: String
    let idea: MKeyIdea?
    @Environment(\.tr) private var T

    private var kindName: String {
        switch card.k ?? "" {
        case "definition": return T("Definition", "定义")
        case "property": return T("Property", "性质")
        case "method-idea": return T("Method", "方法")
        case "notation": return T("Notation", "记号")
        case "condition": return T("Condition", "条件")
        case "common-mistake": return T("Common mistake", "常见错误")
        case "wording": return T("Wording", "题目用语")
        case "graph-feature": return T("Graph feature", "图像特征")
        case "explanation": return T("Explanation", "解释")
        case "link": return T("Link", "联系")
        case "text": return "原文"
        case "gloss": return "字詞"
        case "point": return card.sec ?? "要點"
        default: return card.k ?? ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text([card.sec ?? "", kindName, position].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if card.nf == true { Image(systemName: "scissors").font(.caption).foregroundStyle(.orange) }
                    if card.lvl == "extra" { Text(T("Extra", "延伸")).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(.orange.opacity(0.2), in: Capsule()) }
                }
                MathText(text: card.t ?? "", size: 22, weight: .bold)
                if let i = idea { Text(i.t).font(.subheadline).foregroundStyle(.secondary) }
            }
            if let s = card.s, !s.isEmpty { MathText(text: s, size: 17) }
            ForEach(Array((card.vis ?? []).enumerated()), id: \.offset) { _, v in
                if let f = v.img, let u = MathLibrary.resource(f, "vis"), let img = UIImage(contentsOfFile: u.path) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 560)
                        .padding(8)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .frame(maxWidth: .infinity)
                } else if let t = v.tab {
                    MathTable(rows: t.rows, head: t.head).frame(maxWidth: .infinity)
                }
            }
            if let e = card.ex, !e.isEmpty { box(T("Example", "例子"), "lightbulb", .blue, e) }
            if let p = card.pos { box(T("Is", "是"), "checkmark.circle", .green, p.ex + (p.why.isEmpty ? "" : "\n\n" + p.why)) }
            if let n = card.neg { box(T("Is not", "不是"), "xmark.circle", .red, n.ex + (n.why.isEmpty ? "" : "\n\n" + n.why)) }
            if let r = card.rem, !r.isEmpty { box(T("Remember", "记住"), "bookmark", .purple, r) }
            if let w = card.wo, !w.isEmpty { box(T("Watch out", "注意"), "exclamationmark.triangle", .orange, w) }
        }
        .card()
    }

    private func box(_ title: String, _ icon: String, _ tint: Color, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.subheadline.bold()).foregroundStyle(tint)
            MathText(text: text, size: 16)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Practice item (example = question + solution; drill/class = split screen)

struct MathItemView: View {
    let itemID: String
    @Environment(\.tr) private var T
    @State private var current: String?
    @AppStorage("math.split.on") private var splitOn = true
    @AppStorage("math.practice.wrongOnly") private var wrongOnly = false
    @State private var dsOffer: String?
    private let lib = MathLibrary.shared

    var body: some View {
        if let (c, it) = lib.item(current ?? itemID) {
            let wrong = c.items.filter { ProgressStore.shared.mark(MathItemKey.key(c, $0)) == false || $0.id == it.id }
            let list = wrongOnly ? wrong : c.items
            let k = list.firstIndex(of: it) ?? 0
            let split = splitOn && !c.isZh
            WorkSplit(on: split, sheetID: "ch-" + c.id, figs: split ? figs(c, it) : [], ratio: 0.45) {
                Group {
                    if it.isPractice {
                        SplitPractice(chapter: c, item: it, splitOn: split)
                    } else {
                        ExampleView(chapter: c, item: it, splitOn: split)
                    }
                }
                .id(it.id)
            } bar: {
                PageCluster(index: k, count: list.count,
                            prev: k > 0 ? { current = list[k - 1].id } : nil,
                            next: k < list.count - 1 ? { current = list[k + 1].id } : nil)
            }
            .appScreen()
            .navigationTitle(it.l)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !c.isZh {
                ToolbarItem(placement: .primaryAction) {
                    Button { withAnimation { splitOn.toggle() } } label: {
                        Image(systemName: splitOn ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    }
                    .accessibilityLabel(T("Split", "分屏"))
                }
                }
            }
            .deepSeek(dsContext(c, it, split: split))
            .dsAnalysisOffer($dsOffer)
            .workingSession("ch-" + c.id)
            .onDisappear { ScratchStore.shared.clear("ch-" + c.id, force: true); ReviewStore.shared.finish("ch-" + c.id) }
            .noteRecent(.mathItem(it.id), (c.isZh ? c.t : "Ch\(c.n)") + " · \(it.l)", it.sk ?? "")
        } else if let c = lib.chapters.first(where: { itemID.hasPrefix(String($0.id.dropFirst(2)) + "-") }) {
            DownloadOverlay().task { await MathContent.shared.ensure(c.id) }
        } else {
            ContentUnavailableView(T("Not found", "找不到"), systemImage: "questionmark")
        }
    }

    private func figs(_ c: MChapter, _ it: MItem) -> [UIImage] {
        it.hasText ? it.figImages : (it.f ?? []).compactMap { PDFRegions.image(c.pdf, $0) }
    }

    private func dsContext(_ c: MChapter, _ it: MItem, split: Bool) -> DSContext {
        let review = it.isPractice
        var imgs = figs(c, it)
        if !it.hasText { imgs = (it.q ?? []).compactMap { PDFRegions.image(c.pdf, $0) } + imgs }
        let page = (it.sk.map { $0 + "\n" } ?? "") + (it.hasText ? (it.qt ?? "") : "（题目见附图）")
        var revealed: String?
        // Examples have a worked solution and no 交卷, so it's always sent; practice sends it as well (answers are shown per question).
        do {
            revealed = [it.at, it.sx].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n解析：")
            if revealed?.isEmpty == true { revealed = nil }
            if revealed == nil, !(it.a ?? []).isEmpty { imgs += (it.a ?? []).compactMap { PDFRegions.image(c.pdf, $0) }; revealed = "（答案见附图）" }
        }
        var ctx = DSContext(key: "m-item-" + it.id, subject: c.subjectID, title: (c.isZh ? c.t : "Ch\(c.n)") + " · " + it.l,
                            page: page, images: imgs, revealed: review ? nil : revealed, answer: review ? revealed : nil,
                            chapter: DSContext.mathChapter(c),
                            sheetID: split ? "ch-" + c.id : nil)
        if review, let r = revealed {
            let key = MathItemKey.key(c, it)
            ctx.grade = DSGradeSpec(question: page, scheme: r, maxMarks: 0, images: imgs) { s in
                ProgressStore.shared.setMark(key, s > 0 ? true : false)
            }
        }
        return ctx
    }
}

struct ExampleView: View {
    let chapter: MChapter
    let item: MItem
    var splitOn = false
    @Environment(\.tr) private var T
    @State private var show = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(item, T)
                if item.hasText {
                    MathText(text: item.qt ?? "", size: 18).card()
                    FigureStack(images: item.figImages)
                    if let s = item.stx, !s.isEmpty {
                        AnswerReveal(title: T("Solution", "解答")) {
                            MathText(text: s, size: 17)
                        }
                        .card()
                    }
                } else {
                    RegionStack(pdf: chapter.pdf, regions: item.q ?? [])
                    if !(item.s ?? []).isEmpty {
                        AnswerReveal(title: T("Solution", "解答")) {
                            RegionStack(pdf: chapter.pdf, regions: item.s ?? [])
                        }
                    }
                }
            }
            .frame(maxWidth: 820)
            .padding(.vertical)
            .readingMargin()
            .frame(maxWidth: .infinity)
        }
        .softEdges()
    }
}

@ViewBuilder func header(_ it: MItem, _ T: Tr) -> some View {
    HStack(spacing: 8) {
        if let s = it.sk, !s.isEmpty { MathText(text: s, size: 15, weight: .semibold, color: .secondary) }
        Spacer(minLength: 0)
        if it.nf == true { Image(systemName: "scissors").foregroundStyle(.orange) }
        if let l = it.lvl, !l.isEmpty, l != "null" { Text("Level \(l)").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3).background(Color.secondary.opacity(0.15), in: Capsule()) }
    }
}

struct SplitPractice: View {
    let chapter: MChapter
    let item: MItem
    var splitOn = false
    @Environment(\.tr) private var T

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(item, T)
                if item.hasText {
                    MathText(text: item.qt ?? "", size: 18)
                    FigureStack(images: item.figImages)
                } else {
                    RegionStack(pdf: chapter.pdf, regions: item.q ?? [])
                }
                AnswerReveal(title: T("Answer", "答案")) {
                    VStack(alignment: .leading, spacing: 12) {
                        if item.hasText, let a = item.at, !a.isEmpty {
                            MathText(text: a, size: 17)
                        } else if !item.hasText, !(item.a ?? []).isEmpty {
                            RegionStack(pdf: chapter.pdf, regions: item.a ?? [])
                        } else {
                            Text(T("No printed answer.", "书上没有印答案。")).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let x = item.sx, !x.isEmpty {
                            Divider()
                            Text(T("Worked solution", "解析")).font(.subheadline.bold()).foregroundStyle(.secondary)
                            MathText(text: x, size: 17)
                        }
                        let k = MathItemKey.key(chapter, item)
                        LongMarkCard(key: k, question: item.hasText ? (item.qt ?? "") : "（题目见附图）",
                                     scheme: [item.at, item.sx].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
                                     images: item.figImages, sheetID: "ch-" + chapter.id, max: nil,
                                     score: Binding(get: { ProgressStore.shared.scores[k] }, set: { ProgressStore.shared.setScore(k, $0, max: 2) }))
                            .padding(.top, 6)
                    }
                }
                .card()
            }
            .padding(.vertical)
            .readingMargin()
        }
        .softEdges()
    }
}

// MARK: - Scratch drafts: autosaved, last 3 visited questions kept

struct ScratchDraft: Codable {
    var drawing: Data
    var placed: [PlacedFig] = []
    var height: Double?
    struct PlacedFig: Codable, Hashable { var fig: Int; var x: Double; var y: Double; var w: Double; var png: Data? }
}

final class ScratchStore {
    static let shared = ScratchStore()
    /// One sheet per question set. Kept until 交卷+完成 (sets in review survive launches); others are wiped.
    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let kept = Set(ReviewStore.shared.pending.keys).union(UserDefaults.standard.stringArray(forKey: "scratch.keep") ?? [])
        let keep = Set(kept.map { $0.replacingOccurrences(of: "/", with: "_") + ".json" })
        for f in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] where !keep.contains(f) {
            try? FileManager.default.removeItem(at: d.appendingPathComponent(f))
        }
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("scratch"))
        return d
    }()
    private var current: String?
    /// Sheets the student chose to keep after 结算 (and every daily's sheet, until that daily is deleted).
    private var kept: [String] {
        get { UserDefaults.standard.stringArray(forKey: "scratch.keep") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "scratch.keep") }
    }
    func keep(_ k: String) { if !kept.contains(k) { kept.append(k) } }
    func removeAll(prefix: String) {
        for k in kept where k.hasPrefix(prefix) { clear(k, force: true) }
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }
    private func url(_ id: String) -> URL { dir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json") }

    /// Entering a different question set clears the previous sheet (unless it is waiting for self-marking).
    func session(_ key: String) {
        if current != key { if let c = current { clear(c) }; current = key }
    }
    /// Called when leaving a set or on 交卷 for auto-marked sets. Sheets in review are kept unless forced.
    func clear(_ key: String? = nil, force: Bool = false) {
        guard let k = key ?? current else { return }
        if !force && (ReviewStore.shared.inReview(k) || kept.contains(k)) { return }
        try? FileManager.default.removeItem(at: url(k))
        kept.removeAll { $0 == k }
        if current == k { current = nil }
    }
    func touch(_ id: String) {}
    func has(_ id: String) -> Bool { FileManager.default.fileExists(atPath: url(id).path) }
    func load(_ id: String) -> ScratchDraft? {
        guard let d = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONDecoder().decode(ScratchDraft.self, from: d)
    }
    func save(_ id: String, _ draft: ScratchDraft) {
        if let d = try? JSONEncoder().encode(draft) { try? d.write(to: url(id), options: .atomic) }
        NotificationCenter.default.post(name: .scratchSaved, object: id)
    }
}
extension Notification.Name { static let scratchSaved = Notification.Name("scratchSaved") }

extension View {
    /// Question-answering screens: hard top edge, and scratch drafts scoped to this session.
    func workingSession(_ key: String, clearOnLeave: Bool = true) -> some View {
        self.hardTopEdge()
            .onAppear { ScratchStore.shared.session(key) }
            .onDisappear { if clearOnLeave { ScratchStore.shared.clear(key) } }
    }
    /// Solid theme-coloured title/toolbar row across the full width (over the scratch column too).
    @ViewBuilder func hardTopEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.hard, for: .top)
                .toolbarBackground(Color.appBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            self.toolbarBackground(Color.appBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

enum PaperStyle: String, CaseIterable, Identifiable {
    case blank, lined, grid, graph
    var id: String { rawValue }
    func name(_ T: Tr) -> String {
        switch self {
        case .blank: return T("Blank", "空白")
        case .lined: return T("Lined", "横线")
        case .grid: return T("Grid", "方格")
        case .graph: return T("Graph", "坐标纸")
        }
    }
}

/// Lets the pane ask the canvas where the visible area is.
final class CanvasViewport {
    weak var canvas: PKCanvasView?
    var visibleOrigin: CGPoint {
        guard let c = canvas else { return CGPoint(x: 40, y: 40) }
        let z = max(c.zoomScale, 0.01)
        return CGPoint(x: c.contentOffset.x / z + 40, y: c.contentOffset.y / z + 40)
    }
}

/// One scratch sheet shared by every question in a set / chapter / quiz run / daily paper.
struct ScratchPane: View {
    let sheetID: String
    let figs: [UIImage]
    @Environment(\.tr) private var T
    @AppStorage("math.paper") private var paper: PaperStyle = .grid
    @AppStorage("math.tools") private var tools = true
    @State private var placed: [ScratchDraft.PlacedFig] = []
    @State private var pinned = true
    @State private var port = CanvasViewport()
    @State private var vctl = ViewCtl()

    private var figKey: String { figs.map { "\($0.hash)" }.joined(separator: ",") }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CanvasRep(itemID: sheetID, paper: paper, tools: tools, placed: $placed, port: port, ctl: vctl)
                .id(sheetID)
                .overlay(alignment: .topTrailing) { ViewHUD(ctl: vctl) }
            let right = figs.filter { FigPlacement.shared.mode(FigPlacement.key($0)) == 2 }
            if !right.isEmpty {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(Array(right.enumerated()), id: \.offset) { _, img in
                        VStack(alignment: .trailing, spacing: 6) {
                            Image(uiImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 300, maxHeight: 260)
                                .background(Color.white)
                            HStack {
                                Button { FigPlacement.shared.set(FigPlacement.key(img), 0) } label: { Label(T("Close", "关闭"), systemImage: "xmark") }
                                Spacer()
                                Button { place(img) } label: { Label(T("Place on scratch", "添加到草稿纸"), systemImage: "square.and.arrow.down.on.square") }
                            }
                            .font(.subheadline).buttonStyle(.borderless)
                        }
                        .padding(10)
                        .modifier(GlassCard())
                    }
                }
                .padding(10)
                .padding(.top, 50)
            }
        }
        .background(Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white }))
        .onAppear { autoPlace() }
        .onChange(of: figKey) { autoPlace() }
        .onReceive(NotificationCenter.default.publisher(for: .figToScratch)) { n in
            if let img = n.object as? UIImage { place(img) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                PadButton()
                Menu {
                    Picker(T("Paper", "纸张"), selection: $paper) {
                        ForEach(PaperStyle.allCases) { Text($0.name(T)).tag($0) }
                    }
                } label: { Label(T("Paper", "纸张"), systemImage: "squareshape.split.3x3") }
                Button { tools.toggle() } label: {
                    Label(T(tools ? "Hide tools" : "Tools", tools ? "隐藏笔盘" : "笔盘"),
                          systemImage: tools ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                }
            }
        }
    }

    /// Figures set to 添加到草稿纸 go onto this sheet once.
    private func autoPlace() {
        for img in figs where FigPlacement.shared.mode(FigPlacement.key(img)) == 1 {
            let k = "fig.on." + sheetID + "." + FigPlacement.key(img)
            if !UserDefaults.standard.bool(forKey: k) { place(img) }
        }
    }
    private func place(_ img: UIImage) {
        UserDefaults.standard.set(true, forKey: "fig.on." + sheetID + "." + FigPlacement.key(img))
        let o = port.visibleOrigin
        withAnimation {
            placed.append(.init(fig: -1, x: o.x, y: o.y + Double(placed.count % 4) * 24, w: min(360, Double(img.size.width)), png: img.pngData()))
        }
        pinned = false
    }
}

/// PencilKit canvas with paper lines and placed figures drawn underneath the ink. Grows as you write.
struct CanvasRep: UIViewRepresentable {
    let itemID: String
    let paper: PaperStyle
    let tools: Bool
    @Binding var placed: [ScratchDraft.PlacedFig]
    let port: CanvasViewport
    var ctl: ViewCtl? = nil

    static let width: CGFloat = 2400
    /// A4 pages (595×842) at the sheet width.
    static let pageH: CGFloat = 2400 * 842 / 595
    static func pages(for h: CGFloat) -> CGFloat { max(1, (h / pageH).rounded(.up)) * pageH }

    func makeCoordinator() -> Coord { Coord(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let v = QuietCanvas()
        v.drawingPolicy = .default
        v.backgroundColor = .clear
        v.isOpaque = false
        v.alwaysBounceVertical = true
        if #available(iOS 26.0, *) { v.topEdgeEffect.style = .hard }
        v.minimumZoomScale = 0.5
        v.maximumZoomScale = 4
        v.bouncesZoom = true
        var h: CGFloat = CanvasRep.pageH
        if let d = ScratchStore.shared.load(itemID) {
            v.drawing = (try? PKDrawing(data: d.drawing)) ?? PKDrawing()
            // Old free-height sheets land on as many A4 pages as their ink needs.
            let ink = v.drawing.strokes.isEmpty ? 0 : v.drawing.bounds.maxY + 1
            let figs = d.placed.map { CGFloat($0.y) + CGFloat($0.w) }.max() ?? 0
            h = CanvasRep.pages(for: max(ink, figs))
            DispatchQueue.main.async { placed = d.placed }
        }
        context.coordinator.height = h
        v.contentSize = CGSize(width: CanvasRep.width, height: h)
        let under = UIView(frame: CGRect(origin: .zero, size: v.contentSize))
        under.layer.anchorPoint = .zero
        under.layer.position = .zero
        under.isUserInteractionEnabled = false
        v.insertSubview(under, at: 0)
        context.coordinator.under = under
        let add: UIButton
        if #available(iOS 26.0, *) { add = UIButton(configuration: .glass()) } else { add = UIButton(configuration: .gray()) }
        add.configuration?.title = "加一页"
        add.configuration?.image = UIImage(systemName: "plus")
        add.configuration?.imagePadding = 6
        add.configuration?.cornerStyle = .capsule
        add.addAction(UIAction { [weak c = context.coordinator] _ in c?.addPage() }, for: .primaryActionTriggered)
        v.addSubview(add)
        context.coordinator.addButton = add
        v.delegate = context.coordinator
        context.coordinator.canvas = v
        port.canvas = v
        let dt = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coord.resetZoom(_:)))
        dt.numberOfTapsRequired = 2
        dt.numberOfTouchesRequired = 2
        v.addGestureRecognizer(dt)
        // Finger tap on an inserted image selects it (move / resize / delete).
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coord.tapSelect(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.cancelsTouchesInView = false
        v.addGestureRecognizer(tap)
        // One shared picker for every canvas, so the tool chosen is the tool used.
        let picker = CanvasRep.sharedPicker
        picker.colorUserInterfaceStyle = .unspecified   // scratch follows the theme (black paper in dark)
        picker.overrideUserInterfaceStyle = .unspecified
        picker.addObserver(v)
        picker.addObserver(context.coordinator)
        v.tool = picker.selectedTool
        context.coordinator.picker = picker
        context.coordinator.shown = tools
        picker.setVisible(tools, forFirstResponder: v)
        if tools { DispatchQueue.main.async { v.becomeFirstResponder() } }
        context.coordinator.redraw(paper: paper, placed: placed)
        context.coordinator.layoutAdd(v)
        let co = context.coordinator
        let link = PadLink("scratch:" + itemID, canvas: v)
        link.host = { [weak co] in co?.under?.layer }
        link.onScroll = { [weak v, weak co] y, w in
            guard let v else { return }
            co?.padDriven = true
            if w > 10, !(ctl?.locked ?? false) {
                let z = min(v.maximumZoomScale, max(v.minimumZoomScale, v.bounds.width / w))
                if abs(z - v.zoomScale) > 0.002 { v.zoomScale = z }
            }
            let maxY = max(0, v.contentSize.height - v.bounds.height)
            v.setContentOffset(CGPoint(x: v.contentOffset.x, y: min(maxY, max(0, y * v.zoomScale))), animated: false)
            co?.padDriven = false
        }
        co.link = link
        link.live.dark = { [weak v] in v?.traitCollection.userInterfaceStyle == .dark }
        PadHub.shared.activate(PadSources.scratch(itemID, height: h))
        if let ctl {
            ctl.view = v
            ctl.setZoom = { [weak v] z in v?.setZoomScale(z, animated: true) }
            ctl.goPage = { [weak v] i in
                guard let v else { return }
                let maxY = max(0, v.contentSize.height - v.bounds.height)
                v.setContentOffset(CGPoint(x: v.contentOffset.x, y: min(maxY, CGFloat(i) * CanvasRep.pageH * v.zoomScale)), animated: true)
            }
            ctl.applyLock = { [weak v] on in
                guard let v else { return }
                v.minimumZoomScale = on ? v.zoomScale : 0.5
                v.maximumZoomScale = on ? v.zoomScale : 4
            }
            ctl.bind(key: "scratch:" + itemID)
            ctl.report(page: 0, of: Int((h / CanvasRep.pageH).rounded()))
            co.cmd = CmdZoom.install(on: v, apply: { [weak v] k, p in v?.zoom(by: k, at: p) }, blocked: { [weak ctl] in ctl?.locked ?? false })
        }
        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        port.canvas = v
        if let p = context.coordinator.picker, context.coordinator.shown != tools {
            context.coordinator.shown = tools
            p.setVisible(tools, forFirstResponder: v)
            if tools { v.becomeFirstResponder() } else { v.resignFirstResponder() }
        }
        if context.coordinator.redraw(paper: paper, placed: placed) { context.coordinator.save() }
    }

    static func dismantleUIView(_ v: PKCanvasView, coordinator: Coord) {
        coordinator.link?.tearDown(); coordinator.link = nil
        PadHub.shared.deactivate("scratch:" + coordinator.parent.itemID)
        coordinator.picker?.setVisible(false, forFirstResponder: v)
        coordinator.picker?.removeObserver(v)
        coordinator.picker?.removeObserver(coordinator)
        v.resignFirstResponder()
    }

    static let sharedPicker = PKToolPicker()

    final class Coord: NSObject, PKCanvasViewDelegate, PKToolPickerObserver, UIContextMenuInteractionDelegate {
        var shown = true
        var parent: CanvasRep
        weak var canvas: PKCanvasView?
        var under: UIView?
        var picker: PKToolPicker?
        var height: CGFloat = 4000
        var lastKey = ""
        var addButton: UIButton?
        var link: PadLink?
        var padDriven = false
        var cmd: CmdZoom?
        func scrollViewDidScroll(_ sv: UIScrollView) {
            if let ctl = parent.ctl, sv.zoomScale > 0 {
                let y = (sv.contentOffset.y + sv.bounds.height / 2) / sv.zoomScale
                ctl.report(page: min(Int(height / CanvasRep.pageH) - 1, max(0, Int(y / CanvasRep.pageH))), of: Int((height / CanvasRep.pageH).rounded()))
            }
            guard !padDriven, let link, link.isOn, PadHub.shared.mainFollows, sv.zoomScale > 0 else { return }
            let y = max(0, sv.contentOffset.y) / sv.zoomScale
            let w = sv.bounds.width / sv.zoomScale
            if abs(PadHub.shared.scratchY - y) > 2 { PadHub.shared.scratchY = y }
            if abs(PadHub.shared.scratchW - w) > 2 { PadHub.shared.scratchW = w }
        }

        /// Content = pages + room for the 加一页 button under the last page.
        func layoutAdd(_ c: UIScrollView) {
            let z = c.zoomScale
            c.contentSize = CGSize(width: CanvasRep.width * z, height: height * z + 90)
            if let b = addButton {
                let s = CGSize(width: 130, height: 44)
                b.frame = CGRect(x: (CanvasRep.width * z - s.width) / 2, y: height * z + 23, width: s.width, height: s.height)
            }
            centre(c)
        }
        func setHeight(_ h: CGFloat) {
            guard let c = canvas else { return }
            height = h
            if let u = under {
                let z = c.zoomScale
                u.transform = .identity
                u.frame = CGRect(x: 0, y: 0, width: CanvasRep.width, height: height)
                u.layer.anchorPoint = .zero; u.layer.position = .zero
                u.transform = CGAffineTransform(scaleX: z, y: z)
            }
            lastKey = ""
            PadHub.shared.activate(PadSources.scratch(parent.itemID, height: h), force: true)
            redraw(paper: parent.paper, placed: parent.placed)
            layoutAdd(c)
        }
        func addPage() { setHeight(height + CanvasRep.pageH); save() }
        /// Narrower than the view when zoomed out: centre it and lock sideways sliding.
        func centre(_ sv: UIScrollView) {
            let ix = max(0, (sv.bounds.width - sv.contentSize.width) / 2)
            if abs(sv.contentInset.left - ix) > 0.5 { sv.contentInset.left = ix; sv.contentInset.right = ix }
            sv.alwaysBounceHorizontal = false
            if ix > 0 && abs(sv.contentOffset.x + ix) > 0.5 { sv.contentOffset.x = -ix }
        }
        init(_ p: CanvasRep) {
            parent = p
            super.init()
            PickerRestore.observe(self) { [weak self] in
                guard let self, self.shown, let v = self.canvas, v.window != nil else { return }
                self.picker?.setVisible(true, forFirstResponder: v); v.becomeFirstResponder()
            }
        }

        /// Belt and braces: apply the picked tool directly too.
        func toolPickerSelectedToolDidChange(_ p: PKToolPicker) { canvas?.tool = p.selectedTool }

        func canvasViewDrawingDidChange(_ c: PKCanvasView) {
            // Extend the sheet when writing near the bottom.
            if !c.drawing.strokes.isEmpty && c.drawing.bounds.maxY > height - 150 { setHeight(CanvasRep.pages(for: c.drawing.bounds.maxY + 200)) }
            link?.changed(c.drawing)
            save()
        }

        func scrollViewDidZoom(_ sv: UIScrollView) {
            guard let u = under else { return }
            u.transform = CGAffineTransform(scaleX: sv.zoomScale, y: sv.zoomScale)
            u.layer.position = .zero
            parent.ctl?.report(zoom: sv.zoomScale)
            scrollViewDidScroll(sv)
            layoutSelection()
            layoutAdd(sv)
        }

        // MARK: inserted-image selection
        var imageViews: [UIImageView] = []
        var selected: Int?
        private var selView: UIView?
        private var startFrame: CGRect = .zero

        private func rect(_ i: Int) -> CGRect? {
            guard parent.placed.indices.contains(i), i < imageViews.count else { return nil }
            return imageViews[i].frame
        }

        @objc func tapSelect(_ g: UITapGestureRecognizer) {
            guard let c = canvas else { return }
            let z = max(c.zoomScale, 0.01)
            let p = g.location(in: c)
            let pt = CGPoint(x: p.x / z, y: p.y / z)
            if let i = imageViews.indices.reversed().first(where: { imageViews[$0].frame.insetBy(dx: -6, dy: -6).contains(pt) }) {
                // Drop the dot a finger tap may have drawn.
                if let last = c.drawing.strokes.last, last.renderBounds.width < 14, last.renderBounds.height < 14,
                   last.renderBounds.insetBy(dx: -10, dy: -10).contains(pt) {
                    var d = c.drawing; d.strokes.removeLast(); c.drawing = d
                }
                select(i)
            } else {
                select(nil)
            }
        }

        func select(_ i: Int?) {
            selView?.removeFromSuperview(); selView = nil
            selected = i
            guard let i, let c = canvas, rect(i) != nil else { selected = nil; return }
            let v = UIView()
            v.layer.borderColor = UIColor.tintColor.cgColor
            v.layer.borderWidth = 2
            v.layer.cornerRadius = 4
            v.backgroundColor = UIColor.tintColor.withAlphaComponent(0.06)
            v.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(move(_:))))
            v.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
            v.addInteraction(UIContextMenuInteraction(delegate: self))
            let h = UIImageView(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right.circle.fill"))
            h.tintColor = .tintColor
            h.backgroundColor = .systemBackground
            h.layer.cornerRadius = 15
            h.clipsToBounds = true
            h.isUserInteractionEnabled = true
            h.tag = 7
            h.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resize(_:))))
            v.addSubview(h)
            c.addSubview(v)
            selView = v
            layoutSelection()
        }

        func layoutSelection() {
            guard let v = selView, let i = selected, let r = rect(i), let c = canvas else { return }
            let z = c.zoomScale
            v.frame = CGRect(x: r.minX * z, y: r.minY * z, width: r.width * z, height: r.height * z)
            if let h = v.viewWithTag(7) { h.frame = CGRect(x: v.bounds.width - 18, y: v.bounds.height - 18, width: 30, height: 30) }
        }

        private func setFrame(_ i: Int, _ f: CGRect) {
            imageViews[i].frame = f
            layoutSelection()
        }

        private func commit(_ i: Int) {
            guard parent.placed.indices.contains(i), i < imageViews.count else { return }
            let f = imageViews[i].frame
            var p = parent.placed
            p[i].x = Double(f.minX); p[i].y = Double(f.minY); p[i].w = Double(max(40, f.width))
            lastKey = "\(parent.paper.rawValue)|\(p)"   // views already match; skip rebuild
            parent.placed = p
            save()
        }

        @objc func move(_ g: UIPanGestureRecognizer) {
            guard let i = selected, let c = canvas, let r = rect(i) else { return }
            let z = max(c.zoomScale, 0.01)
            switch g.state {
            case .began: startFrame = r
            case .changed:
                let t = g.translation(in: c)
                setFrame(i, startFrame.offsetBy(dx: t.x / z, dy: t.y / z))
            case .ended, .cancelled: commit(i)
            default: break
            }
        }

        @objc func resize(_ g: UIPanGestureRecognizer) {
            guard let i = selected, let c = canvas, let r = rect(i) else { return }
            let z = max(c.zoomScale, 0.01)
            switch g.state {
            case .began: startFrame = r
            case .changed:
                let t = g.translation(in: c)
                let w = max(40, startFrame.width + t.x / z)
                setFrame(i, CGRect(x: startFrame.minX, y: startFrame.minY, width: w, height: w * startFrame.height / max(startFrame.width, 1)))
            case .ended, .cancelled: commit(i)
            default: break
            }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let i = selected, let r = rect(i) else { return }
            switch g.state {
            case .began: startFrame = r
            case .changed:
                let w = max(40, startFrame.width * g.scale), h = w * startFrame.height / max(startFrame.width, 1)
                setFrame(i, CGRect(x: startFrame.midX - w / 2, y: startFrame.midY - h / 2, width: w, height: h))
            case .ended, .cancelled: commit(i)
            default: break
            }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let i = selected else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(children: [
                    UIAction(title: "放大", image: UIImage(systemName: "plus.magnifyingglass")) { [weak self] _ in self?.scale(i, 1.25) },
                    UIAction(title: "缩小", image: UIImage(systemName: "minus.magnifyingglass")) { [weak self] _ in self?.scale(i, 0.8) },
                    UIAction(title: "删除图片", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.delete(i) },
                ])
            }
        }

        private func scale(_ i: Int, _ k: CGFloat) {
            guard let r = rect(i) else { return }
            let w = max(40, r.width * k)
            setFrame(i, CGRect(x: r.minX, y: r.minY, width: w, height: w * r.height / max(r.width, 1)))
            commit(i)
        }

        private func delete(_ i: Int) {
            select(nil)
            var p = parent.placed
            guard p.indices.contains(i) else { return }
            p.remove(at: i)
            parent.placed = p
        }

        @objc func resetZoom(_ g: UITapGestureRecognizer) {
            canvas?.setZoomScale(1, animated: true)
        }

        func save() {
            guard let c = canvas else { return }
            if c.drawing.strokes.isEmpty && parent.placed.isEmpty && !ScratchStore.shared.has(parent.itemID) { return }
            ScratchStore.shared.save(parent.itemID, ScratchDraft(drawing: c.drawing.dataRepresentation(), placed: parent.placed, height: Double(height)))
        }

        @discardableResult
        func redraw(paper: PaperStyle, placed: [ScratchDraft.PlacedFig]) -> Bool {
            guard let u = under else { return false }
            let key = "\(paper.rawValue)|\(placed)"
            if key == lastKey { return false }
            lastKey = key
            u.subviews.forEach { $0.removeFromSuperview() }
            let size = u.bounds.size
            // Paper as a tiled pattern (cheap for tall sheets).
            let step: CGFloat = paper == .graph ? 10 : 30
            let tileH: CGFloat = paper == .lined ? 34 : step * 5
            let tileW: CGFloat = paper == .lined ? 34 : step * 5
            if paper != .blank {
                let tile = UIGraphicsImageRenderer(size: CGSize(width: tileW, height: tileH)).image { ctx in
                    let cg = ctx.cgContext
                    func h(_ alpha: CGFloat, _ w: CGFloat) { cg.setStrokeColor(UIColor.systemBlue.withAlphaComponent(alpha).cgColor); cg.setLineWidth(w) }
                    if paper == .lined {
                        h(0.25, 1); cg.move(to: CGPoint(x: 0, y: 0.5)); cg.addLine(to: CGPoint(x: tileW, y: 0.5)); cg.strokePath()
                    } else {
                        for i in 0..<5 {
                            let major = paper == .graph && i == 0
                            h(major ? 0.35 : 0.15, major ? 1 : 0.6)
                            let o = CGFloat(i) * step + 0.3
                            cg.move(to: CGPoint(x: o, y: 0)); cg.addLine(to: CGPoint(x: o, y: tileH)); cg.strokePath()
                            cg.move(to: CGPoint(x: 0, y: o)); cg.addLine(to: CGPoint(x: tileW, y: o)); cg.strokePath()
                        }
                    }
                }
                let bg = UIView(frame: CGRect(origin: .zero, size: size))
                bg.backgroundColor = UIColor(patternImage: tile)
                u.addSubview(bg)
            }
            // A4 page edges + numbers.
            let pages = Int((size.height / CanvasRep.pageH).rounded())
            for i in 0..<max(1, pages) {
                let y = CGFloat(i) * CanvasRep.pageH
                if i > 0 {
                    let line = UIView(frame: CGRect(x: 0, y: y - 3, width: size.width, height: 6))
                    line.backgroundColor = UIColor.separator
                    u.addSubview(line)
                }
            }
            imageViews = []
            for p in placed {
                guard let d = p.png, let img = UIImage(data: d) else { imageViews.append(UIImageView()); continue }
                let w = CGFloat(p.w), hgt = w * img.size.height / max(img.size.width, 1)
                let iv = UIImageView(image: img)
                iv.frame = CGRect(x: p.x, y: p.y, width: w, height: hgt)
                iv.contentMode = .scaleAspectFit
                iv.layer.borderColor = UIColor.systemGray4.cgColor
                iv.layer.borderWidth = 0.5
                u.addSubview(iv)
                imageViews.append(iv)
            }
            if let s = selected, s >= placed.count { select(nil) } else { layoutSelection() }
            return true
        }
    }
}

/// Question column + one shared scratch sheet. In split mode the page bar sits under the question column only.
struct WorkSplit<Q: View, B: View>: View {
    let on: Bool
    let sheetID: String
    let figs: [UIImage]
    var ratio: Double = 0.5
    @ViewBuilder let question: () -> Q
    @ViewBuilder let bar: () -> B

    var body: some View {
        if on {
            SplitContainer(key: "math.split.ratio", defaultRatio: ratio) {
                question().frame(maxHeight: .infinity).pageNav { bar() }.hardTopEdge()
            } second: {
                ScratchPane(sheetID: sheetID, figs: figs).hardTopEdge()
            }
            .hardTopEdge()
        } else {
            question().pageNav { bar() }
        }
    }
}

// MARK: - Smooth split container

/// Question | scratch split. While dragging only frames change: the question content keeps
/// its last laid-out size (clipped), the canvas view is never rebuilt, and the ratio is saved on release.
struct SplitContainer<A: View, B: View>: View {
    let key: String
    @ViewBuilder let first: () -> A
    @ViewBuilder let second: () -> B
    @AppStorage private var ratio: Double
    @State private var live: Double?
    @State private var lastSnap: Double?

    init(key: String, defaultRatio: Double = 0.45, @ViewBuilder first: @escaping () -> A, @ViewBuilder second: @escaping () -> B) {
        self.key = key
        self.first = first
        self.second = second
        _ratio = AppStorage(wrappedValue: defaultRatio, key)
    }

    private static var snaps: [Double] { [1.0 / 3, 0.5, 2.0 / 3] }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let total = landscape ? geo.size.width : geo.size.height
            let committed = clamp(ratio, total) * total
            let current = clamp(live ?? ratio, total) * total
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first()
                    .frame(width: landscape ? committed : nil, height: landscape ? nil : committed, alignment: .topLeading)
                    .frame(width: landscape ? current : nil, height: landscape ? nil : current, alignment: .topLeading)
                    .clipped()
                handle(landscape: landscape, total: total)
                second()
            }
            .transaction { if live != nil { $0.animation = nil } }
        }
    }

    private func clamp(_ r: Double, _ total: CGFloat) -> Double {
        let lo = max(0.2, 220 / max(total, 1)), hi = min(0.8, 1 - 220 / max(total, 1))
        return min(hi, max(lo, r))
    }

    private func handle(landscape: Bool, total: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: landscape ? 1 : nil, height: landscape ? nil : 1)
            Capsule().fill(live == nil ? Color.secondary.opacity(0.6) : Color.accentColor)
                .frame(width: landscape ? 6 : 48, height: landscape ? 48 : 6)
        }
        .frame(width: landscape ? 28 : nil, height: landscape ? nil : 28)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                var r = ratio + Double((landscape ? v.translation.width : v.translation.height) / total)
                if let s = Self.snaps.first(where: { abs($0 - r) < 0.02 }) {
                    r = s
                    if lastSnap != s { UIImpactFeedbackGenerator(style: .light).impactOccurred(); lastSnap = s }
                } else { lastSnap = nil }
                live = r
            }
            .onEnded { _ in
                if let l = live { ratio = clamp(l, total) }
                live = nil
                lastSnap = nil
            })
        .hoverEffect(.highlight)
        .accessibilityLabel("Resize")
    }
}

struct FigureStack: View {
    let images: [UIImage]
    var body: some View {
        ForEach(Array(images.enumerated()), id: \.offset) { _, img in
            FigureInline(img: img)
        }
    }
}

/// A question figure in the question column, with 只在题目栏显示 / 添加到草稿纸 / 显示在右边.
struct FigureInline: View {
    let img: UIImage
    var maxWidth: CGFloat = 560
    @State private var fp = FigPlacement.shared
    var body: some View {
        let key = FigPlacement.key(img)
        let mode = fp.mode(key)
        Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
            .frame(maxWidth: min(img.size.width, maxWidth))
            .padding(8)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Menu { items(key, mode) } label: {
                    Image(systemName: "ellipsis").font(.subheadline.bold()).frame(width: 30, height: 30)
                }
                .glassButton()
                .padding(6)
            }
            .contextMenu { items(key, mode) }
            .frame(maxWidth: .infinity)
    }
    @ViewBuilder private func items(_ key: String, _ mode: Int) -> some View {
        Button { fp.set(key, 0) } label: { Label("只在题目栏显示", systemImage: mode == 0 ? "checkmark" : "text.below.photo") }
        Button { fp.set(key, 1); NotificationCenter.default.post(name: .figToScratch, object: img) } label: {
            Label("添加到草稿纸", systemImage: mode == 1 ? "checkmark" : "square.and.arrow.down.on.square")
        }
        Button { fp.set(key, 2) } label: { Label("显示在右边", systemImage: mode == 2 ? "checkmark" : "sidebar.right") }
    }
}

/// Where each question figure goes: 0 题目栏 (default), 1 草稿纸, 2 右边. Remembered per figure.
@Observable
final class FigPlacement {
    static let shared = FigPlacement()
    private var rev = 0
    func mode(_ k: String) -> Int { _ = rev; return UserDefaults.standard.integer(forKey: "fig.mode." + k) }
    func set(_ k: String, _ m: Int) { UserDefaults.standard.set(m, forKey: "fig.mode." + k); rev += 1 }
    private static var cache: [ObjectIdentifier: String] = [:]
    /// Stable across launches: FNV-1a over the image's pixels (sampled).
    static func key(_ img: UIImage) -> String {
        if let k = cache[ObjectIdentifier(img)] { return k }
        var h: UInt64 = 1469598103934665603
        if let cg = img.cgImage, let d = cg.dataProvider?.data, let p = CFDataGetBytePtr(d) {
            let n = CFDataGetLength(d), step = max(1, n / 4096)
            var i = 0
            while i < n { h = (h ^ UInt64(p[i])) &* 1099511628211; i += step }
            h = (h ^ UInt64(n)) &* 1099511628211
        }
        let k = String(h, radix: 36)
        cache[ObjectIdentifier(img)] = k
        return k
    }
}

extension Notification.Name { static let figToScratch = Notification.Name("figToScratch") }

private struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct DownloadOverlay: View {
    @Environment(\.tr) private var T
    var body: some View {
        VStack(spacing: 10) {
            if case .downloading(let p) = MathContent.shared.state {
                ProgressView(value: p).frame(width: 200)
                Text("\(Int(p * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else { ProgressView() }
            Text(T("Downloading…", "正在下载…")).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum MathItemKey {
    static func key(_ c: MChapter, _ it: MItem) -> String { "math:tb:" + c.id + ":" + it.id }
}
