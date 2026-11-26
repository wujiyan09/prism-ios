import Foundation
import Observation

/// All study content. Loaded from the bundled copy, then refreshed from the ict-portal GitHub repo.
@Observable
final class Library {
    static let shared = Library()

    /// The active subject. Switching subjects reloads content from its own source and cache.
    static var subject: Subject = Subject.find(UserDefaults.standard.string(forKey: "subject") ?? "ict")
    static var raw: String { subject.base }

    var books: [Book] = []
    var items: [String: Item] = [:]
    var years: [PaperYear] = []
    var dseMC: [String] = []
    var dseLQ: [String] = []
    var paper2: [Paper2] = []
    var loaded = false
    var version = 0
    var updating = false
    var lastError: String?
    var needsDownload = false
    var downloadDone = 0
    var downloadTotal = 0
    var downloadFailed = false
    var images: Set<String> = []

    var chapters: [Chapter] { books.flatMap { $0.chapters } }
    func chapter(_ id: String) -> Chapter? { chapters.first { $0.id == id } }
    func year(_ y: String) -> PaperYear? { years.first { $0.y == y } }
    func item(_ k: String) -> Item? { items[k] }

    var totals: (cards: Int, mc: Int, sq: Int, pr: Int) {
        let c = chapters
        return (c.reduce(0) { $0 + $1.cards.count }, c.reduce(0) { $0 + $1.mc.count },
                c.reduce(0) { $0 + $1.sq.count }, c.reduce(0) { $0 + $1.pr.count })
    }

    // MARK: Loading

    private static var cacheDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent(subject.cacheName, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func bundled(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "data")
            ?? Bundle.main.url(forResource: name, withExtension: "json")
    }

    private static func manifest(at url: URL?) -> Manifest? {
        guard let url, let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: d)
    }

    func load() async {
        let hasCache = Self.manifest(at: Self.cacheDir.appendingPathComponent("manifest.json")) != nil
        if hasCache {
            let result = await Task.detached(priority: .userInitiated) { Self.build(fromCache: true) }.value
            apply(result)
            await refresh()
        } else {
            await firstDownload()
        }
    }

    /// First launch: download all content and images, with progress.
    func firstDownload() async {
        downloadFailed = false
        needsDownload = true
        await refresh(force: true)
        if version == 0 { downloadFailed = true; return }
        needsDownload = false
    }

    static func imageFile(_ rel: String) -> URL {
        cacheDir.appendingPathComponent("img", isDirectory: true).appendingPathComponent(rel)
    }

    func fetchImages(missingOnly: Bool) async {
        let todo = images.filter { !missingOnly || !FileManager.default.fileExists(atPath: Self.imageFile($0).path) }.sorted()
        guard !todo.isEmpty else { return }
        downloadDone = 0
        downloadTotal = todo.count
        var idx = 0
        await withTaskGroup(of: Void.self) { g in
            while idx < min(6, todo.count) { let r = todo[idx]; idx += 1; g.addTask { await Self.getImage(r) } }
            while await g.next() != nil {
                downloadDone += 1
                if idx < todo.count { let r = todo[idx]; idx += 1; g.addTask { await Self.getImage(r) } }
            }
        }
    }

    /// Download one image when it's first shown.
    static func fetchImage(_ file: URL) async {
        let root = cacheDir.appendingPathComponent("img", isDirectory: true).path + "/"
        guard file.path.hasPrefix(root) else { return }
        await getImage(String(file.path.dropFirst(root.count)))
    }

    private static func getImage(_ rel: String) async {
        guard let enc = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let u = URL(string: raw + enc),
              let (d, r) = try? await URLSession.shared.data(from: u),
              (r as? HTTPURLResponse)?.statusCode == 200 else { return }
        let f = imageFile(rel)
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: f, options: .atomic)
    }

    /// Checks GitHub for newer content and swaps it in.
    func refresh(force: Bool = false) async {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        do {
            let mURL = URL(string: Self.raw + "data/manifest.json?t=\(Int(Date().timeIntervalSince1970))")!
            var req = URLRequest(url: mURL); req.cachePolicy = .reloadIgnoringLocalCacheData
            let (md, _) = try await URLSession.shared.data(for: req)
            let m = try JSONDecoder().decode(Manifest.self, from: md)
            guard force || m.v > version else { return }
            let dir = Self.cacheDir
            // Catalogue (chapter lists) + past-paper text are small; chapters come on demand.
            var names = m.years.map { "dse-\($0)" }
            names.append("catalog")
            downloadTotal = names.count; downloadDone = 0
            try await withThrowingTaskGroup(of: (String, Data?).self) { g in
                for n in names {
                    g.addTask {
                        let u = URL(string: Self.raw + "data/\(n).json?v=\(m.v)")!
                        let (d, r) = try await URLSession.shared.data(from: u)
                        if let h = r as? HTTPURLResponse, h.statusCode != 200 {
                            if n == "catalog" { return (n, nil) }
                            throw URLError(.badServerResponse)
                        }
                        return (n, d)
                    }
                }
                for try await (n, d) in g {
                    downloadDone += 1
                    if let d { try d.write(to: dir.appendingPathComponent("\(n).json"), options: .atomic) }
                }
            }
            // Keep downloaded chapters current.
            let cat = (try? Data(contentsOf: dir.appendingPathComponent("catalog.json"))).flatMap { try? JSONDecoder().decode(Catalog.self, from: $0) }
            if let cat {
                for b in cat.books { for c in b.chs where Self.chapterHash(c.id) != nil && Self.chapterHash(c.id) != c.h {
                    try? await Self.downloadChapter(c.id, book: b.id, catalog: cat, manifestV: m.v)
                } }
            }
            try md.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
            let result = await Task.detached(priority: .utility) { Self.build(fromCache: true) }.value
            if !result.books.isEmpty { apply(result) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private struct BuildResult {
        var books: [Book] = []
        var items: [String: Item] = [:]
        var years: [PaperYear] = []
        var dseMC: [String] = []
        var dseLQ: [String] = []
        var paper2: [Paper2] = []
        var version = 0
        var images: Set<String> = []
    }

    private func apply(_ r: BuildResult) {
        books = r.books; items = r.items; years = r.years; images = r.images
        dseMC = r.dseMC; dseLQ = r.dseLQ; version = r.version; paper2 = r.paper2
        loaded = true
    }

    private static func data(_ name: String, cache: Bool) -> Data? {
        if cache, let d = try? Data(contentsOf: cacheDir.appendingPathComponent("\(name).json")) { return d }
        if name == "meta", let u = bundled(name) { return try? Data(contentsOf: u) }
        return nil
    }

    private static func build(fromCache: Bool) -> BuildResult {
        var r = BuildResult()
        let dec = JSONDecoder()
        let man = (data("manifest", cache: fromCache)).flatMap { try? dec.decode(Manifest.self, from: $0) }
        r.version = man?.v ?? 0
        let bookIDs = man?.books ?? ["A1", "A2", "B", "C1", "C2", "D2", "E", "EA", "EB", "EC"]
        let yearIDs = man?.years ?? []

        // Books
        let order = ["A1", "A2", "B", "C1", "C2", "D1", "D2", "E", "EA", "EB", "EC"]
        var books: [Book] = []
        let catalog = data("catalog", cache: fromCache).flatMap { try? dec.decode(Catalog.self, from: $0) }
        for cb in catalog?.books ?? [] {
            let elective = cb.elective ?? (["EA", "EB", "EC"].contains(cb.id))
            var chs: [Chapter] = []
            for cc in cb.chs {
                if let d = try? Data(contentsOf: chapterFile(cc.id)), let c = try? dec.decode(RawChapter.self, from: Scrub.data(d)) {
                    chs.append(Self.makeChapter(c, bookID: cb.id, elective: elective, into: &r))
                } else {
                    var ch = Chapter(id: cc.id, n: cc.n, t: cc.t, tz: cc.tz ?? "", sections: cc.sec ?? [], bookID: cb.id,
                                     elective: elective, cards: [], mc: [], sq: [], pr: [])
                    ch.counts = (cc.nc, cc.nm, cc.ns, cc.np)
                    chs.append(ch)
                }
            }
            books.append(Book(id: cb.id, name: cb.name, elective: elective, chapters: chs))
        }
        for id in (catalog == nil ? bookIDs : []) {
            guard let d = data("book-\(id)", cache: fromCache),
                  let b = try? dec.decode(RawBook.self, from: Scrub.data(d)) else { continue }
            let elective = b.elective ?? (["EA", "EB", "EC"].contains(b.id))
            var chs: [Chapter] = []
            for c in b.chs { chs.append(Self.makeChapter(c, bookID: b.id, elective: elective, into: &r)) }
            books.append(Book(id: b.id, name: b.name, elective: elective, chapters: chs))
        }
        books.sort { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
        r.books = books

        // Past papers
        let meta = bundled("meta").flatMap { try? Data(contentsOf: $0) }.flatMap { try? dec.decode(Meta.self, from: $0) }
        var years: [PaperYear] = (meta?.years ?? []).map { y in
            PaperYear(y: y.y, label: y.y == "SP" ? "Sample Paper" : y.y == "PP" ? "Practice Paper" : "HKDSE \(y.y)",
                      note: y.note, paper: y.paper.flatMap(URL.init(string:)), ms: y.ms.flatMap(URL.init(string:)),
                      key: (meta?.keys[y.y] ?? "").map { String($0) }, pct: meta?.pct[y.y] ?? [])
        }
        for yid in yearIDs {
            guard let d = data("dse-\(yid)", cache: fromCache),
                  let p = try? dec.decode(RawDSE.self, from: Scrub.data(d)) else { continue }
            let y0 = p.year.value
            let Y = ["sp", "pp"].contains(y0.lowercased()) ? y0.uppercased() : y0
            let yl = y0.lowercased()
            let pct = meta?.pct[Y] ?? []
            var mcKeys: [String] = [], lqKeys: [String] = []
            for q in p.mc ?? [] {
                let k = "dse-\(Y)-\(q.n)"
                var it = Item(key: k, type: .mc)
                it.year = Y; it.n = q.n; it.q = q.q; it.st = q.st ?? []; it.o = q.o
                it.a = q.a.index; it.cancel = q.a.cancelled
                it.pct = q.pct ?? (q.n - 1 < pct.count ? pct[q.n - 1] : "")
                it.topic = q.topic; it.e = q.exp ?? ""; it.code = q.code ?? false
                for rel in q.figs ?? [] { r.images.insert(rel); it.figs.append(imageFile(rel)) }
                let figName = q.figs?.isEmpty == false ? nil : q.img ?? q.fig.flatMap { ["True", "False", ""].contains($0.value) ? nil : $0.value }
                if let img = figName {
                    let rel = img.contains("/") ? img : "figs/" + img
                    r.images.insert(rel); it.fig = imageFile(rel)
                } else if it.figs.isEmpty, q.fig?.value == "True", let pg = q.pg {
                    let rel = pageRel(yl, pg); r.images.insert(rel); it.fig = imageFile(rel)
                }
                it.isReal = true; it.src = "\(yearLabel(Y)) 1A Q\(q.n)"
                r.items[k] = it; r.dseMC.append(k); mcKeys.append(k)
            }
            for l in p.lq ?? [] {
                let k = "lq-\(Y)-\(l.n)"
                var it = Item(key: k, type: .lq)
                it.year = Y; it.n = l.n; it.topic = l.topic; it.q = l.stem ?? ""; it.parts = l.parts ?? []
                it.pages = (l.pg?.values ?? []).map { pg in
                    let rel = pageRel(yl, pg); r.images.insert(rel); return imageFile(rel)
                }
                for rel in l.figs ?? [] { r.images.insert(rel); it.figs.append(imageFile(rel)) }
                for p in it.parts { for rel in p.figs ?? [] { r.images.insert(rel) } }
                it.isReal = true; it.src = "\(yearLabel(Y)) 1B Q\(l.n)"
                r.items[k] = it; r.dseLQ.append(k); lqKeys.append(k)
            }
            if let ix = years.firstIndex(where: { $0.y == Y }) {
                years[ix].mc = mcKeys; years[ix].lq = lqKeys
            }
        }
        r.years = years
        for (y, papers) in meta?.p2 ?? [:] {
            for (c, p) in papers {
                guard let u = URL(string: p.paper) else { continue }
                r.paper2.append(Paper2(year: y, code: c, paper: u, ms: p.ms.flatMap(URL.init(string:))))
            }
        }
        r.paper2.sort { $0.year != $1.year ? $0.year > $1.year : $0.code < $1.code }
        return r
    }


    private static func makeChapter(_ c: RawChapter, bookID: String, elective: Bool, into r: inout BuildResult) -> Chapter {
                var mc: [String] = [], sq: [String] = [], pr: [String] = []
                for (i, m) in (c.mc ?? []).enumerated() {
                    let k = "\(c.id)-m\(i)"
                    var it = Item(key: k, type: .mc)
                    it.src = m.src ?? ""; it.q = m.q; it.o = m.o; it.a = m.a.index
                    it.e = m.e ?? ""; it.ez = m.ez ?? ""; it.sec = m.sec ?? ""
                    it.code = (m.code ?? false) || m.q.contains("\n")
                    it.chapterID = c.id; it.bookID = bookID; it.topic = Topics.bookTopic[bookID]
                    r.items[k] = it; mc.append(k)
                }
                for (i, s) in (c.sq ?? []).enumerated() {
                    let k = "\(c.id)-s\(i)"
                    var it = Item(key: k, type: .sq)
                    it.src = s.src ?? ""; it.q = s.q ?? ""; it.parts = s.parts ?? []; it.sec = s.sec ?? ""
                    it.chapterID = c.id; it.bookID = bookID; it.topic = Topics.bookTopic[bookID]
                    r.items[k] = it; sq.append(k)
                }
                for (i, p) in (c.pr ?? []).enumerated() {
                    let k = "\(c.id)-p\(i)"
                    var it = Item(key: k, type: .pr)
                    it.src = p.src ?? ""; it.q = p.task; it.practical = p; it.sec = p.sec ?? ""
                    it.chapterID = c.id; it.bookID = bookID; it.topic = Topics.bookTopic[bookID]
                    r.items[k] = it; pr.append(k)
                }
                return Chapter(id: c.id, n: c.n, t: c.t, tz: c.tz ?? "", sections: c.sec ?? [], bookID: bookID,
                                   elective: elective, cards: c.cards ?? [], mc: mc, sq: sq, pr: pr)
    }

    // MARK: On-demand chapters

    static func chapterFile(_ id: String) -> URL {
        let d = cacheDir.appendingPathComponent("ch", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("\(id).json")
    }
    static func chapterHash(_ id: String) -> String? { UserDefaults.standard.string(forKey: "ict.ch.\(id)") }

    /// Per-chapter file when the catalogue matches the book data; otherwise the whole book file, split locally.
    static func downloadChapter(_ id: String, book: String, catalog: Catalog, manifestV: Int) async throws {
        if catalog.v == manifestV, let cc = catalog.books.first(where: { $0.id == book })?.chs.first(where: { $0.id == id }) {
            let (d, r) = try await URLSession.shared.data(from: URL(string: raw + "data/ch/\(id).json?h=\(cc.h)")!)
            if (r as? HTTPURLResponse)?.statusCode == 200 {
                try d.write(to: chapterFile(id), options: .atomic)
                UserDefaults.standard.set(cc.h, forKey: "ict.ch.\(id)")
                return
            }
        }
        let (d, r) = try await URLSession.shared.data(from: URL(string: raw + "data/book-\(book).json?v=\(manifestV)")!)
        guard (r as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let chs = obj["chs"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        for c in chs {
            guard let cid = c["id"] as? String else { continue }
            if cid == id || chapterHash(cid) != nil {
                let cd = try JSONSerialization.data(withJSONObject: c)
                try cd.write(to: chapterFile(cid), options: .atomic)
                UserDefaults.standard.set(catalog.books.first(where: { $0.id == book })?.chs.first(where: { $0.id == cid })?.h ?? "v\(manifestV)", forKey: "ict.ch.\(cid)")
            }
        }
    }

    var loadingChapters: Set<String> = []

    /// Download a chapter the first time it's opened.
    @MainActor
    func ensureChapter(_ id: String) async {
        guard let c = chapter(id), c.isStub, !loadingChapters.contains(id) else { return }
        guard let cd = try? Data(contentsOf: Self.cacheDir.appendingPathComponent("catalog.json")),
              let cat = try? JSONDecoder().decode(Catalog.self, from: cd) else { return }
        loadingChapters.insert(id)
        defer { loadingChapters.remove(id) }
        do {
            try await Self.downloadChapter(id, book: c.bookID, catalog: cat, manifestV: version)
            let result = await Task.detached(priority: .userInitiated) { Self.build(fromCache: true) }.value
            apply(result)
        } catch { lastError = error.localizedDescription }
    }

    @MainActor
    func ensureBook(_ bookID: String) async {
        for c in books.first(where: { $0.id == bookID })?.chapters ?? [] where c.isStub { await ensureChapter(c.id) }
    }

    @MainActor
    func removeBook(_ bookID: String) async {
        for c in books.first(where: { $0.id == bookID })?.chapters ?? [] {
            try? FileManager.default.removeItem(at: Self.chapterFile(c.id))
            UserDefaults.standard.removeObject(forKey: "ict.ch.\(c.id)")
        }
        let result = await Task.detached(priority: .userInitiated) { Self.build(fromCache: true) }.value
        apply(result)
    }

    func bookSize(_ bookID: String) -> Int {
        (books.first(where: { $0.id == bookID })?.chapters ?? []).reduce(0) {
            $0 + ((try? Self.chapterFile($1.id).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
    static var imageCacheSize: Int { StorageView.folderSize(cacheDir.appendingPathComponent("img")) }
    static func clearImages() { try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("img")) }

    static func pageRel(_ yl: String, _ p: Int) -> String {
        "pages/\(yl)-p1-\(String(format: "%02d", p)).jpg"
    }
}

/// Removes any wording that labels content as machine-written (same rules as the website).
enum Scrub {
    private static let rules: [(NSRegularExpression, String)] = {
        let pats: [(String, String, NSRegularExpression.Options)] = [
            (#"\s*[(（][^()（）]*Quest[^()（）]*[)）]"#, "", []),
            (#"Quest[’']s\s+"#, "", []),
            (#"\bQuest\s*(original|原创|补充|自拟|编写|所写)[^。.;；<]*[。.;；]?"#, "", [.caseInsensitive]),
            (#"Suggested answer \(Quest\)"#, "Suggested answer", []),
        ]
        return pats.compactMap { p in
            (try? NSRegularExpression(pattern: p.0, options: p.2)).map { ($0, p.1) }
        }
    }()

    static func string(_ s: String) -> String {
        guard s.contains("Quest") || s.contains("quest") else { return s }
        var out = s
        for (re, rep) in rules {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: rep)
        }
        return out
    }

    private static func walk(_ v: Any) -> Any {
        if let s = v as? String { return string(s) }
        if let a = v as? [Any] { return a.map(walk) }
        if let d = v as? [String: Any] { return d.mapValues(walk) }
        return v
    }

    /// Scrubs every string value in a JSON document.
    static func data(_ d: Data) -> Data {
        guard let text = String(data: d, encoding: .utf8), text.range(of: "quest", options: .caseInsensitive) != nil,
              let obj = try? JSONSerialization.jsonObject(with: d),
              let out = try? JSONSerialization.data(withJSONObject: walk(obj)) else { return d }
        return out
    }
}
