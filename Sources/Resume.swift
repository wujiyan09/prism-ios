import SwiftUI
import Observation

// MARK: - Autosave of in-progress practice + 「最近使用」

/// One practice the student opened: what it is, how far, where to go back to.
struct Activity: Codable, Identifiable, Hashable {
    var id: String              // same key as the saved snapshot
    var title: String
    var subject: String         // ict / math / chem / zh / daily / notes / pdf
    var target: RecentTarget?
    var ictKeys: [String]? = nil   // ICT sessions: reopen from these
    var answered = 0
    var total = 0
    var status = 0              // 0 进行中, 1 已交卷, 2 已结算 / 完成
    var time = Date().timeIntervalSince1970
}

@Observable
final class ResumeStore {
    static let shared = ResumeStore()
    private(set) var activities: [String: Activity] = [:]
    @ObservationIgnored private var snaps: [String: Data] = [:]
    @ObservationIgnored private var pending: DispatchWorkItem?

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("resume", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var snapURL: URL { dir.appendingPathComponent("snapshots.json") }
    private static var actURL: URL { dir.appendingPathComponent("recent.json") }

    init() {
        if let d = try? Data(contentsOf: Self.snapURL), let s = try? JSONDecoder().decode([String: Data].self, from: d) { snaps = s }
        if let d = try? Data(contentsOf: Self.actURL), let a = try? JSONDecoder().decode([String: Activity].self, from: d) { activities = a }
        for n in [UIApplication.didEnterBackgroundNotification, UIApplication.willResignActiveNotification, UIApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                NotificationCenter.default.post(name: .resumeFlush, object: nil)
                self?.flush()
            }
        }
    }

    func snapshot<T: Decodable>(_ key: String, as: T.Type) -> T? { snaps[key].flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    func save<T: Encodable>(_ key: String, _ value: T) {
        snaps[key] = try? JSONEncoder().encode(value)
        schedule()
    }
    func clear(_ key: String) { snaps[key] = nil; schedule() }

    func touch(_ a: Activity) {
        var a = a
        a.time = Date().timeIntervalSince1970
        activities[a.id] = a
        schedule()
    }
    func update(_ id: String, answered: Int? = nil, total: Int? = nil, status: Int? = nil) {
        guard var a = activities[id] else { return }
        if let answered { a.answered = answered }
        if let total { a.total = total }
        if let status { a.status = status }
        a.time = Date().timeIntervalSince1970
        if a != activities[id] { activities[id] = a; schedule() }
    }
    func remove(_ id: String) { activities[id] = nil; schedule() }

    private func schedule() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flush() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }
    func flush() {
        pending?.cancel(); pending = nil
        // Keep the newest 200 activities.
        if activities.count > 200 {
            let keep = activities.values.sorted { $0.time > $1.time }.prefix(200).map(\.id)
            activities = activities.filter { keep.contains($0.key) }
        }
        try? JSONEncoder().encode(snaps).write(to: Self.snapURL, options: .atomic)
        try? JSONEncoder().encode(activities).write(to: Self.actURL, options: .atomic)
    }
}

extension Notification.Name {
    /// App going to the background: save anything still waiting on a debounce.
    static let resumeFlush = Notification.Name("resumeFlush")
}

/// Banner shown when a practice was restored: 已恢复上次进度 · 重新开始.
struct ResumedBanner: View {
    let restart: () -> Void
    @Binding var shown: Bool
    var body: some View {
        if shown {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                Text("已恢复上次进度").font(.subheadline)
                Spacer(minLength: 8)
                Button("重新开始") { restart(); shown = false }.font(.subheadline.bold())
                Button { shown = false } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassBackground(Capsule())
            .padding(.horizontal, 16).padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task { try? await Task.sleep(for: .seconds(8)); withAnimation { shown = false } }
        }
    }
}

// MARK: 最近使用

struct RecentActivityView: View {
    @State private var store = ResumeStore.shared
    @Environment(SceneModel.self) private var scene
    @State private var result: RunRecord?
    @AppStorage("recent.view") private var viewMode = "list"
    @AppStorage("recent.group") private var grouped = true

    private var groups: [(String, [Activity])] {
        let cal = Calendar.current
        let all = store.activities.values.sorted { $0.time > $1.time }
        var today: [Activity] = [], yesterday: [Activity] = [], older: [Activity] = []
        for a in all {
            let d = Date(timeIntervalSince1970: a.time)
            if cal.isDateInToday(d) { today.append(a) } else if cal.isDateInYesterday(d) { yesterday.append(a) } else { older.append(a) }
        }
        if !grouped { return all.isEmpty ? [] : [("", all)] }
        return [("今天", today), ("昨天", yesterday), ("更早", older)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        Group { if viewMode == "grid" { grid } else { list } }
        .tint(AppSection.recent.tint)
        .navigationTitle("最近使用")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                FileViewOptions(mode: $viewMode, sort: .constant("date"), grouped: $grouped)
            }
        }
        .sheet(item: $result) { r in NavigationStack { RunDetailView(run: r).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { result = nil } } } } }
    }

    private var grid: some View {
        ScrollView {
            if store.activities.isEmpty {
                ContentUnavailableView("还没有最近使用", systemImage: "clock", description: Text("打开过的笔记和文件会出现在这里。")).padding(.top, 60)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                ForEach(groups, id: \.0) { g in
                    Section {
                        ForEach(g.1) { a in
                            Button { open(a) } label: {
                                FileGridCell(title: a.title, subtitle: Date(timeIntervalSince1970: a.time).formatted(.relative(presentation: .named))) { gridThumb(a) }
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("移除", role: .destructive) { store.remove(a.id) } }
                        }
                    } header: {
                        if !g.0.isEmpty { Text(g.0).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                    }
                }
            }
            .padding(20)
        }
        .background(Color.appBackground)
    }
    @ViewBuilder private func gridThumb(_ a: Activity) -> some View {
        if case .note(let id)? = a.target, let d = NoteStore.shared.docs[id] {
            NoteThumb(doc: d)
        } else {
            Image(systemName: icon(a.subject)).font(.system(size: 44, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 110, height: 140)
                .background(tint(a.subject).gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var list: some View {
        List {
            if store.activities.isEmpty {
                ContentUnavailableView("还没有最近使用", systemImage: "clock",
                                       description: Text("做过的测验、每日练习、试卷、PDF 和笔记会出现在这里。"))
                    .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.0) { g in
                Section(g.0.isEmpty ? "最近" : g.0) {
                    ForEach(g.1) { a in
                        Button { open(a) } label: { row(a) }
                            .buttonStyle(.plain)
                            .swipeActions { Button("移除", role: .destructive) { store.remove(a.id) } }
                            .contextMenu {
                                if let r = ProgressStore.shared.runs.first(where: { $0.title == a.title }) {
                                    Button { result = r } label: { Label("看成绩", systemImage: "checklist") }
                                }
                            }
                        if a.status >= 1, let r = ProgressStore.shared.runs.first(where: { $0.title == a.title }) {
                            Button { result = r } label: {
                                Label("成绩 \(r.got)/\(r.tot) · 看每题对错", systemImage: "checklist").font(.caption)
                            }
                            .padding(.leading, 46)
                        }
                    }
                }
                .listRowBackground(Color.cardBackground)
            }
        }
        .listStyle(.insetGrouped)
        .appList()
    }

    private func row(_ a: Activity) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(a.subject))
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(tint(a.subject).gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    if a.total > 0 { Text("\(a.answered)/\(a.total)") }
                    if a.total > 0 {
                        Text(["进行中", "已交卷", "已完成"][min(max(0, a.status), 2)])
                            .foregroundStyle(a.status == 0 ? Color.orange : Color.secondary)
                        Text("·")
                    }
                    Text( Date(timeIntervalSince1970: a.time).formatted(.relative(presentation: .named)))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func icon(_ s: String) -> String {
        switch s {
        case "ict": return "desktopcomputer"
        case "math": return "function"
        case "chem": return "flask"
        case "zh": return "character.book.closed"
        case "daily": return "pencil.and.list.clipboard"
        case "notes": return "note.text"
        default: return "doc.text"
        }
    }
    private func tint(_ s: String) -> Color {
        switch s {
        case "ict": return .blue
        case "math": return .indigo
        case "chem": return .green
        case "zh": return .red
        case "daily": return .pink
        case "notes": return .yellow
        default: return .orange
        }
    }

    private func open(_ a: Activity) {
        if let keys = a.ictKeys {
            scene.start(a.title, keys)
            return
        }
        guard let t = a.target else { return }
        let r: Route?
        switch t {
        case .cards(let c, let i): r = .cards(c, i)
        case .chapter(let c): r = .chapter(c)
        case .practical(let k): r = .practical(k)
        case .year(let y): r = .year(y)
        case .paper2(let c): r = .paper2(c)
        case .pdf(let u, let tt): r = URL(string: u).map { .pdf($0, tt) }
        case .exam(let id): r = .exam(id)
        case .tool(let k): r = ToolKind(rawValue: k).map { .tool($0) }
        case .mathCards(let c, let i): r = .mathCards(c, i)
        case .mathItem(let i): r = .mathItem(i)
        case .mathQuiz(let q): r = .mathQuiz(q)
        case .daily(let d): r = .daily(d)
        case .ppSet(let s): r = .ppSet(s)
        case .note(let id): r = .note(id)
        case .imported(let id): r = .imported(id)
        case .mathPaper(let id): r = .mathPaper(id)
        case .session: r = nil
        }
        if let r {
            var p = NavigationPath()
            p.append(r)
            scene.paths[.recent] = p
        }
    }
}
