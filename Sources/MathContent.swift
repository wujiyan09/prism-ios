import SwiftUI
import Observation

/// Maths content is downloaded on first open (not bundled), cached offline, and updated incrementally.
@Observable
final class MathContent {
    static let shared = MathContent()
    static let base = URL(string: "https://prism-content.wujiyan2009.workers.dev/")!
    static let key = Secrets.contentKey

    enum State: Equatable { case idle, checking, downloading(Double), ready, failed(String) }
    var state: State = .idle

    let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("mathdata", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = d
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? v.setResourceValues(rv)
        return d
    }()

    struct Index: Codable { let v: Int; let files: [String: Entry]; struct Entry: Codable, Equatable { let h: String; let n: Int; let g: String? } }

    private func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: MathContent.base.appendingPathComponent(path))
        r.setValue(MathContent.key, forHTTPHeaderField: "x-prism-key")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.timeoutInterval = 60
        return r
    }

    func local(_ rel: String) -> URL? {
        let u = dir.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    // MARK: groups (meta = chapter lists; one group per chapter)

    private(set) var remote: Index?
    private var localIndex: Index? {
        get { (try? Data(contentsOf: dir.appendingPathComponent("index.json"))).flatMap { try? JSONDecoder().decode(Index.self, from: $0) } }
    }
    /// Per-file entries actually on disk (path → entry).
    private var have: [String: Index.Entry] {
        get { (UserDefaults.standard.data(forKey: "math.have")).flatMap { try? JSONDecoder().decode([String: Index.Entry].self, from: $0) } ?? [:] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "math.have") }
    }
    var pinned: Set<String> {
        get { return Set(pinnedRaw.split(separator: ",").map(String.init)) }
        set { pinnedRaw = newValue.sorted().joined(separator: ",") }
    }
    private var pinnedRaw: String = UserDefaults.standard.string(forKey: "math.pinned") ?? "" { didSet { UserDefaults.standard.set(pinnedRaw, forKey: "math.pinned") } }
    private var used: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: "math.used") as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "math.used") }
    }
    var capMB: Int {
        get { return capRaw }
        set { capRaw = newValue }
    }
    private var capRaw: Int = (UserDefaults.standard.object(forKey: "math.cap") as? Int) ?? 300 { didSet { UserDefaults.standard.set(capRaw, forKey: "math.cap") } }
    var loading: Set<String> = []
    var revision = 0

    /// Bytes on disk per group.
    func sizes() -> [String: Int] {
        _ = revision
        var out: [String: Int] = [:]
        for (_, e) in have { out[e.g ?? "meta", default: 0] += e.n }
        return out
    }
    func isDownloaded(_ g: String) -> Bool {
        _ = revision
        guard let r = remote ?? localIndex else { return false }
        let files = r.files.filter { $0.value.g == g }
        return !files.isEmpty && files.allSatisfy { have[$0.key] == $0.value && local($0.key) != nil }
    }

    private func fetchIndex() async throws -> Index {
        let (d, resp) = try await URLSession.shared.data(for: request("index.json"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let r = try JSONDecoder().decode(Index.self, from: d)
        try? d.write(to: dir.appendingPathComponent("index.json"), options: .atomic)
        return r
    }

    /// On launch: refresh the index and the small chapter list; refresh downloaded groups that changed.
    @MainActor
    /// Content update check: at most once every 3 hours (not on every window appear / return to the app).
    func sync() async {
        if hasMeta, Date().timeIntervalSince(mathLastSync) < 3 * 3600 { return }
        mathLastSync = Date()
        if state == .checking { return }
        if case .downloading = state { return }
        state = .checking
        do {
            let r = try await fetchIndex()
            remote = r
            try await download(group: "meta", index: r, progress: !hasMeta)
            MathLibrary.shared.reload()
            // keep already-downloaded chapters up to date
            let groups = Set(have.values.compactMap { $0.g }).subtracting(["meta"])
            for g in groups { try? await download(group: g, index: r, progress: false); MathLibrary.shared.reloadChapter(g); MathMC.shared.reloadChapter(g) }
            state = .ready
        } catch {
            remote = localIndex
            state = hasMeta ? .ready : .failed(error.localizedDescription)
        }
    }

    var hasMeta: Bool { local("math.json") != nil }
    func isOnDisk(_ g: String) -> Bool { (remote ?? localIndex)?.files.contains { $0.value.g == g && local($0.key) != nil } ?? false }

    /// Make sure a chapter's files are on disk (downloads on first open).
    @MainActor
    func ensure(_ g: String) async {
        used[g] = Date().timeIntervalSince1970
        if isDownloaded(g) && MathLibrary.shared.isLoaded(g) { return }
        // Already on disk (maybe an older version): show it right away, never a download screen; refresh quietly.
        let onDisk = (remote ?? localIndex)?.files.contains { $0.value.g == g && local($0.key) != nil } ?? false
        if onDisk {
            if !MathLibrary.shared.isLoaded(g) { MathLibrary.shared.reloadChapter(g); MathMC.shared.reloadChapter(g) }
            guard !loading.contains(g), let r = remote else { return }
            loading.insert(g)
            defer { loading.remove(g) }
            if (try? await download(group: g, index: r, progress: false)) != nil { MathLibrary.shared.reloadChapter(g); MathMC.shared.reloadChapter(g) }
            return
        }
        guard !loading.contains(g) else { return }
        loading.insert(g)
        defer { loading.remove(g) }
        do {
            let r: Index
            if let x = remote { r = x } else { r = try await fetchIndex(); remote = r }
            try await download(group: g, index: r, progress: true)
        } catch {
            if !isDownloaded(g) { state = .failed(error.localizedDescription); return }
        }
        MathLibrary.shared.reloadChapter(g)
        MathMC.shared.reloadChapter(g)
        evict()
    }

    @MainActor
    private func download(group g: String, index r: Index, progress: Bool) async throws {
        let cur = have
        let need = r.files.filter { $0.value.g == g && (cur[$0.key] != $0.value || local($0.key) == nil) }
        if need.isEmpty { return }
        let total = max(1, need.values.reduce(0) { $0 + $1.n })
        var done = 0
        if progress { state = .downloading(0) }
        try await withThrowingTaskGroup(of: (String, Index.Entry).self) { tg in
            var it = need.makeIterator()
            func add() -> Bool {
                guard let (k, e) = it.next() else { return false }
                tg.addTask {
                    let (data, resp) = try await URLSession.shared.data(for: self.request(k))
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    let u = self.dir.appendingPathComponent(k)
                    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: u, options: .atomic)
                    return (k, e)
                }
                return true
            }
            for _ in 0..<6 { if !add() { break } }
            var h = have
            while let (k, e) = try await tg.next() {
                h[k] = e
                done += e.n
                if progress { state = .downloading(Double(done) / Double(total)) }
                _ = add()
            }
            have = h
        }
        if progress { state = .ready }
        revision += 1
    }

    /// Delete a downloaded chapter (it downloads again when opened).
    @MainActor
    func remove(_ g: String) {
        var h = have
        for (k, e) in h where e.g == g {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(k))
            h[k] = nil
        }
        have = h
        var p = pinned; p.remove(g); pinned = p
        MathLibrary.shared.unloadChapter(g)
        MathMC.shared.unloadChapter(g)
        revision += 1
    }

    @MainActor
    func setPinned(_ g: String, _ on: Bool) {
        var p = pinned
        if on { p.insert(g) } else { p.remove(g) }
        pinned = p
        if on { Task { await ensure(g) } }
    }

    /// Least-recently-used unpinned chapters are removed when over the cap.
    @MainActor
    func evict() {
        var total = sizes().values.reduce(0, +)
        let cap = capMB * 1_000_000
        guard total > cap else { return }
        let u = used
        let candidates = sizes().keys.filter { $0 != "meta" && !pinned.contains($0) && !loading.contains($0) }
            .sorted { (u[$0] ?? 0) < (u[$1] ?? 0) }
        for g in candidates where total > cap {
            total -= sizes()[g] ?? 0
            remove(g)
        }
    }
}

/// Shown at the top of Maths lists while content downloads.
struct MathContentBanner: View {
    @State private var c = MathContent.shared
    @Environment(\.tr) private var T
    var body: some View {
        switch c.state {
        case .downloading(let p):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(T("Downloading content…", "正在下载内容…")).font(.subheadline)
                    ProgressView(value: p)
                    Text("\(Int(p * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.cardBackground)
            }
        case .failed(let m):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(T("Couldn't download content", "内容下载失败"), systemImage: "wifi.exclamationmark").font(.subheadline.bold())
                    Text(m).font(.caption).foregroundStyle(.secondary)
                    Button(T("Try again", "重试")) { Task { await c.sync() } }
                }
                .listRowBackground(Color.cardBackground)
            }
        case .checking where !c.hasMeta:
            Section { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.cardBackground) }
        default:
            EmptyView()
        }
    }
}

// MARK: - Settings → Storage

struct StorageView: View {
    @State private var c = MathContent.shared
    @Environment(\.tr) private var T
    @State private var confirm: String?
    private let lib = MathLibrary.shared

    var body: some View {
        let sizes = c.sizes()
        let total = sizes.values.reduce(0, +)
        Form {
            Section {
                NavigationLink { DriveBackupView() } label: {
                    LabeledContent {
                        Text(DriveBackup.shared.signedIn ? (DriveBackup.shared.lastBackup.map { $0.formatted(.relative(presentation: .named)) } ?? "已登录") : "未开启")
                    } label: { Label("Google 云端硬盘备份", systemImage: "externaldrive.badge.icloud") }
                }
            }
            if !RootView.notesOnly {
            Section {
                LabeledContent(T("Maths on this device", "数学（本机）"), value: fmt(total))
                Stepper(value: Binding(get: { c.capMB }, set: { c.capMB = $0; c.evict() }), in: 100...2000, step: 100) {
                    LabeledContent(T("Limit", "上限"), value: "\(c.capMB) MB")
                }
            } footer: {
                Text(T("Chapters download when you open them. Over the limit, the least recently opened ones are removed, except books kept offline.",
                       "章节在打开时下载。超过上限时，会先删最久没打开的章节；设为离线的课本不会被删。"))
            }
            }
            ImportStorageSection()
            NotesStorageSection()
            PDFInkSection()
            if !RootView.notesOnly {
            Section {
                ForEach(ict.books) { b in
                    let size = ict.bookSize(b.id)
                    let all = !b.chapters.contains { $0.isStub }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(b.id) \(b.name)").lineLimit(1)
                            Text(size > 0 ? fmt(size) + (all ? "" : " · " + T("partly", "部分")) : T("Not downloaded", "未下载"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if b.chapters.contains(where: { ict.loadingChapters.contains($0.id) }) { ProgressView() }
                        else if all { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        else {
                            Button { Task { await ict.ensureBook(b.id) } } label: { Image(systemName: "icloud.and.arrow.down") }
                                .buttonStyle(.borderless)
                        }
                    }
                    .swipeActions { if size > 0 { Button(T("Remove", "删除"), role: .destructive) { Task { await ict.removeBook(b.id) } } } }
                }
                LabeledContent(T("Past-paper images", "真题图片"), value: fmt(imgSize))
                Button(T("Clear images", "清除图片"), role: .destructive) { Library.clearImages(); imgSize = 0 }.disabled(imgSize == 0)
            } header: {
                Text("ICT")
            } footer: {
                Text(T("ICT chapters download when opened. Tap ↓ to keep a whole book offline; swipe to remove.", "ICT 章节在打开时下载。点 ↓ 把整本书下载以供离线使用；左滑删除。"))
            }
            Section(T("Daily Practice", "每日练习")) {
                LabeledContent(T("Cached papers", "已缓存试卷"), value: fmt(dailySize))
                Button(T("Clear cache", "清除缓存"), role: .destructive) {
                    try? FileManager.default.removeItem(at: dailyDir)
                    ScratchStore.shared.removeAll(prefix: "daily-")
                    try? FileManager.default.createDirectory(at: dailyDir.appendingPathComponent("figs"), withIntermediateDirectories: true)
                    dailySize = 0
                }
                .disabled(dailySize == 0)
            }
            ForEach(lib.books) { b in
                Section {
                    let ids = b.chs.map(\.id)
                    let pinnedAll = ids.allSatisfy { c.pinned.contains($0) }
                    Toggle(T("Download for offline use", "下载以供离线使用"), isOn: Binding(get: { pinnedAll }, set: { on in
                        for id in ids { c.setPinned(id, on) }
                    }))
                    ForEach(b.chs) { ch in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ch.label)
                                Text(c.isDownloaded(ch.id) ? fmt(sizes[ch.id] ?? 0) : T("Not downloaded", "未下载"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if c.loading.contains(ch.id) { ProgressView() }
                            else if c.pinned.contains(ch.id) { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                        }
                        .swipeActions {
                            if (sizes[ch.id] ?? 0) > 0 {
                                Button(T("Remove", "删除"), role: .destructive) { c.remove(ch.id) }
                            }
                        }
                    }
                    if ids.contains(where: { (sizes[$0] ?? 0) > 0 }) {
                        Button(T("Remove download", "删除下载"), role: .destructive) { for id in ids { c.remove(id) } }
                    }
                } header: {
                    Text("\(T(b.name, b.nameZh)) · \(fmt(b.chs.reduce(0) { $0 + (sizes[$1.id] ?? 0) }))")
                }
            }
            }
        }
        .navigationTitle(T("Storage", "存储"))
        .onAppear { dailySize = Self.folderSize(dailyDir); imgSize = Library.imageCacheSize }
    }

    @State private var dailySize = 0
    @State private var imgSize = 0
    @Environment(Library.self) private var ict
    private var dailyDir: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("daily", isDirectory: true) }
    static func folderSize(_ u: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var n = 0
        for case let f as URL in e { n += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return n
    }

    private func fmt(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}

// MARK: - Progress (Maths)

struct MathStatsView: View {
    var subj = "math"
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    private let lib = MathLibrary.shared

    var body: some View {
        let chs = lib.chapters(subj)
        let allQ = chs.flatMap { $0.sets.flatMap { $0.qids } }.map { MathMC.key($0) }
        let s = prog.stat(allQ)
        let learned = chs.filter { prog.learned.contains($0.id) }.count
        let cardsRead = chs.reduce(0) { acc, c in acc + (0..<c.nCards).filter { prog.seen.contains("\(c.id)-\($0)") }.count }
        let cardsTotal = chs.reduce(0) { $0 + $1.nCards }
        List {
            Section {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { pills(s, learned, cardsRead) }
                    VStack(alignment: .leading, spacing: 8) { pills(s, learned, cardsRead) }
                }
                ProgressView(value: Double(learned), total: Double(max(lib.chapters(subj).count, 1))) {
                    Text(T("Chapters learned", "已学章节")).font(.caption)
                }.tint(.green)
                ProgressView(value: Double(cardsRead), total: Double(max(cardsTotal, 1))) {
                    Text(T("Cards read", "已读卡")).font(.caption)
                }
            }
            .listRowBackground(Color.cardBackground)
            ForEach(lib.books(subj)) { b in
                Section(T(b.name, b.nameZh)) {
                    ForEach(b.chs) { c in
                        let st = prog.stat(c.sets.flatMap { $0.qids }.map { MathMC.key($0) })
                        let read = (0..<c.nCards).filter { prog.seen.contains("\(c.id)-\($0)") }.count
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(c.label)
                                Spacer()
                                if prog.learned.contains(c.id) { Image(systemName: "checkmark").foregroundStyle(.green) }
                            }
                            Text(T("Cards \(read)/\(c.nCards) · MC \(st.done)/\(st.total)", "卡 \(read)/\(c.nCards) · 选择题 \(st.done)/\(st.total)") + (st.done > 0 ? " · \(Int((Double(st.correct) / Double(st.done) * 100).rounded()))%" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: Double(st.done), total: Double(max(st.total, 1)))
                        }
                    }
                }
                .listRowBackground(Color.cardBackground)
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(MathLibrary.title(subj, T) + T(" Progress", " 进度"))
    }

    @ViewBuilder private func pills(_ s: (done: Int, correct: Int, total: Int), _ learned: Int, _ read: Int) -> some View {
        StatPill(value: "\(learned)/\(lib.chapters(subj).count)", label: T("chapters learned", "已学章节"))
        StatPill(value: "\(s.done)", label: T("MC done", "已做选择题"))
        StatPill(value: s.done > 0 ? "\(Int((Double(s.correct) / Double(s.done) * 100).rounded()))%" : "—", label: T("accuracy", "正确率"))
        StatPill(value: "\(read)", label: T("cards read", "已读卡"))
    }
}

nonisolated(unsafe) private var mathLastSync: Date {
    get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "math.lastSync")) }
    set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "math.lastSync") }
}
