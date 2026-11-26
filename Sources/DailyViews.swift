import SwiftUI
import Observation

// MARK: - 每日练习: the 17:00 daily practice paper, done in the app.
// Data: <ict-portal>/daily/index.json + daily/<date>.json + daily/figs/*.png (downloaded, cached offline).

struct DailyIndex: Codable { let v: Int; let days: [DailyDayMeta] }
struct DailyDayMeta: Codable, Hashable, Identifiable {
    let date: String; let subject: String; let title: String; let minutes: Int; let marks: Int; let count: Int
    var id: String { date }
}
struct DailyExample: Codable, Hashable { let title: String; let question: String; let solution: String }
struct DailyPart: Codable, Hashable { let label: String; let marks: Int; let text: String; let answer: String }
struct DailyQuestion: Codable, Hashable, Identifiable {
    let id: String; let n: String; let type: String; let marks: Int; let source: String?
    let stem: String; let figure: String?; let options: [String]?; let answer: String?
    let solution: String?; let parts: [DailyPart]?; let official: Bool?
    var isMC: Bool { type == "mc" }
}
struct DailySection: Codable, Hashable { let title: String; let note: String?; let questions: [DailyQuestion] }
struct DailyDay: Codable, Hashable {
    let date: String; let subject: String; let title: String; let scope: String?; let minutes: Int; let marks: Int
    let scratch: Bool?; let keyPoints: [String]; let examples: [DailyExample]; let sections: [DailySection]; let answerNote: String?
    var questions: [DailyQuestion] { sections.flatMap { $0.questions } }
}

/// Answers and self-marks for one day, saved on device.
struct DailyResult: Codable {
    var mc: [String: String] = [:]          // question id -> chosen letter
    var marks: [String: Int] = [:]          // "qid" or "qid#part" -> self-marked score
    var revealed: [String] = []             // question ids whose answers are shown
    var submitted = false
}

@Observable
final class DailyStore {
    static let shared = DailyStore()
    static let raw = "https://raw.githubusercontent.com/wujiyan09/ict-portal/main/daily/"

    var days: [DailyDayMeta] = []
    var loaded: [String: DailyDay] = [:]
    var results: [String: DailyResult] = [:] { didSet { saveResults() } }
    var loading = false
    var error: String?

    private let cache: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("daily", isDirectory: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent("figs"), withIntermediateDirectories: true)
        return d
    }()
    private let resultsURL: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("daily-results.json")
    }()

    init() {
        if let d = try? Data(contentsOf: resultsURL), let r = try? JSONDecoder().decode([String: DailyResult].self, from: d) { results = r }
        if let d = try? Data(contentsOf: cache.appendingPathComponent("index.json")), let i = try? JSONDecoder().decode(DailyIndex.self, from: d) { days = i.days }
    }

    private func saveResults() {
        if let d = try? JSONEncoder().encode(results) { try? d.write(to: resultsURL, options: .atomic) }
    }

    private func fetch(_ rel: String) async -> Data? {
        let enc = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel
        guard let u = URL(string: Self.raw + enc + "?t=\(Int(Date().timeIntervalSince1970) / 60)") else { return nil }
        var req = URLRequest(url: u); req.cachePolicy = .reloadIgnoringLocalCacheData; req.timeoutInterval = 20
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }

    @MainActor func refresh() async {
        loading = true; defer { loading = false }
        if let d = await fetch("index.json"), let i = try? JSONDecoder().decode(DailyIndex.self, from: d) {
            days = i.days; error = nil
            try? d.write(to: cache.appendingPathComponent("index.json"), options: .atomic)
        } else if days.isEmpty {
            error = "offline"
        }
    }

    @MainActor func day(_ date: String) async -> DailyDay? {
        if let d = loaded[date] { return d }
        let file = cache.appendingPathComponent(date + ".json")
        var data = await fetch(date + ".json")
        if let data { try? data.write(to: file, options: .atomic) } else { data = try? Data(contentsOf: file) }
        guard let data, let day = try? JSONDecoder().decode(DailyDay.self, from: data) else { return nil }
        for q in day.questions { if let f = q.figure { await figure(f) } }
        loaded[date] = day
        return day
    }

    @discardableResult func figure(_ name: String) async -> URL? {
        let u = cache.appendingPathComponent("figs").appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: u.path) { return u }
        guard let d = await fetch("figs/" + name) else { return nil }
        try? d.write(to: u, options: .atomic)
        return u
    }
    func image(_ name: String?) -> UIImage? {
        guard let name else { return nil }
        return UIImage(contentsOfFile: cache.appendingPathComponent("figs").appendingPathComponent(name).path)
    }

    /// nil = day not available; true = submitted and every written part has a score.
    func allMarked(_ date: String) -> Bool? {
        guard let r = results[date] else { return nil }
        var day = loaded[date]
        if day == nil, let data = try? Data(contentsOf: cache.appendingPathComponent(date + ".json")) { day = try? JSONDecoder().decode(DailyDay.self, from: data) }
        guard let day else { return nil }
        guard r.submitted else { return false }
        for q in day.questions where !q.isMC {
            if let ps = q.parts, !ps.isEmpty { if ps.contains(where: { r.marks[q.id + "#" + $0.label] == nil }) { return false } }
            else if r.marks[q.id] == nil { return false }
        }
        return true
    }

    func score(_ day: DailyDay) -> (got: Int, tot: Int, done: Bool) {
        let r = results[day.date] ?? DailyResult()
        var got = 0, skip = 0   // unmarked long questions are left out of the total, not scored 0
        for q in day.questions {
            if q.isMC { if r.mc[q.id] == q.answer { got += q.marks } }
            else if let ps = q.parts, !ps.isEmpty { for p in ps { if let v = r.marks[q.id + "#" + p.label] { got += v } else { skip += p.marks } } }
            else if let v = r.marks[q.id] { got += v } else { skip += q.marks }
        }
        return (got, day.marks - skip, r.submitted)
    }
}

enum DailySubject {
    static func icon(_ s: String) -> String {
        switch s {
        case "ICT": return "desktopcomputer"
        case "Physics": return "atom"
        case "Chemistry": return "flask"
        case "M2": return "sum"
        default: return "function"
        }
    }
    static func color(_ s: String) -> Color {
        switch s {
        case "ICT": return .indigo
        case "Physics": return .orange
        case "Chemistry": return .green
        case "M2": return .purple
        default: return .blue
        }
    }
    static func name(_ s: String, _ T: Tr) -> String {
        switch s {
        case "ICT": return "ICT"
        case "Physics": return T("Physics", "物理")
        case "Chemistry": return T("Chemistry", "化学")
        case "M2": return "M2"
        case "Maths Core", "Maths": return T("Maths Core", "数学")
        default: return s
        }
    }
    static func weekday(_ date: String, _ T: Tr) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "Asia/Hong_Kong")
        guard let d = f.date(from: date) else { return "" }
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Hong_Kong")!
        let w = c.component(.weekday, from: d) - 1
        return T(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][w], ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][w])
    }
}

/// Mixed text: ``` code blocks in monospace, everything else through MathText (LaTeX, tables, **bold**).
struct DailyText: View {
    let text: String
    var size: CGFloat = 17
    var color: Color = .primary
    var body: some View {
        let parts = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                if i % 2 == 1 {
                    let code = p.hasPrefix("\n") ? String(p.dropFirst()) : p
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code.trimmingCharacters(in: .newlines))
                            .font(.system(size: size - 2, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MathText(text: p.trimmingCharacters(in: .newlines), size: size, color: color)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - List of days

struct DailyListView: View {
    @Environment(\.tr) private var T
    @State private var store = DailyStore.shared

    var body: some View {
        List {
            RecentSection(section: .daily)
            if store.days.isEmpty {
                if store.loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    ContentUnavailableView(T("No papers yet", "还没有练习卷"), systemImage: "doc.text",
                                           description: Text(T("A new paper arrives every day at 17:00.", "每天 17:00 会有一份新卷。")))
                }
            } else {
                Section {
                    ForEach(store.days) { d in
                        NavigationLink(value: Route.daily(d.date)) { row(d) }
                    }
                } footer: {
                    Text(T("A new paper arrives every day at 17:00. The PDF is also saved in your Drive.", "每天 17:00 会有一份新卷，PDF 也会存一份在 Drive 里。"))
                }
                .listRowBackground(Color.cardBackground)
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(T("Daily Practice", "每日练习"))
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
    }

    private func row(_ d: DailyDayMeta) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: DailySubject.icon(d.subject), color: DailySubject.color(d.subject))
            VStack(alignment: .leading, spacing: 2) {
                Text(DailySubject.name(d.subject, T)).font(.headline)
                Text("\(d.date) \(DailySubject.weekday(d.date, T)) · \(T("~\(d.minutes) min", "约 \(d.minutes) 分钟")) · \(T("\(d.marks) marks", "共 \(d.marks) 分"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let r = store.results[d.date] {
                if r.submitted, let day = store.loaded[d.date] {
                    let s = store.score(day)
                    Text("\(s.got)/\(s.tot)").font(.subheadline.bold().monospacedDigit()).foregroundStyle(Color.accentColor)
                } else if r.submitted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.good)
                } else if !r.mc.isEmpty || !r.marks.isEmpty {
                    Text(T("In progress", "做到一半")).font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text(T("Not done", "未做")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - One day: key points, worked examples, start

struct DailyDayView: View {
    let date: String
    @Environment(\.tr) private var T
    @State private var store = DailyStore.shared
    @State private var day: DailyDay?
    @State private var failed = false
    @State private var showKeys = true
    @State private var openEx: Set<Int> = []

    var body: some View {
        Group {
            if let day {
                content(day)
            } else if failed {
                ContentUnavailableView(T("Couldn't load", "加载不了"), systemImage: "wifi.slash",
                                       description: Text(T("Check the connection and try again.", "检查网络后再试。")))
            } else {
                ProgressView()
            }
        }
        .appScreen()
        .navigationTitle("\(DailySubject.name(day?.subject ?? "", T)) · \(date)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if day == nil { day = await store.day(date); failed = day == nil }
        }
        .noteRecent(.daily(date), "\(DailySubject.name(day?.subject ?? "", T)) · \(date)", T("Daily practice", "每日练习"))
    }

    private func content(_ d: DailyDay) -> some View {
        let s = store.score(d)
        let r = store.results[d.date] ?? DailyResult()
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(DailySubject.name(d.subject, T), systemImage: DailySubject.icon(d.subject))
                        .font(.title2.bold()).foregroundStyle(DailySubject.color(d.subject))
                    Text("\(d.date) \(DailySubject.weekday(d.date, T)) · \(T("~\(d.minutes) min", "约 \(d.minutes) 分钟")) · \(T("\(d.marks) marks", "共 \(d.marks) 分")) · \(T("\(d.questions.count) questions", "\(d.questions.count) 题"))")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let sc = d.scope { Text(sc).font(.subheadline).foregroundStyle(.secondary) }
                }

                if s.done {
                    HStack {
                        Image(systemName: "checkmark.seal.fill").font(.title).foregroundStyle(Color.good)
                        VStack(alignment: .leading) {
                            Text("\(s.got) / \(s.tot)").font(.title2.bold().monospacedDigit())
                            Text(T("Submitted", "已交卷")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .card()
                }

                DisclosureGroup(isExpanded: $showKeys) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(d.keyPoints.enumerated()), id: \.offset) { _, k in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(.secondary)
                                DailyText(text: k, size: 16)
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: { Label(T("Key Points Today", "今日重点"), systemImage: "key").font(.headline) }
                .card()

                if !d.examples.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(T("Worked examples", "例题"), systemImage: "lightbulb").font(.headline)
                        ForEach(Array(d.examples.enumerated()), id: \.offset) { i, e in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(e.title).font(.subheadline.bold())
                                DailyText(text: e.question, size: 16)
                                DisclosureGroup(isExpanded: Binding(get: { openEx.contains(i) }, set: { v in if v { openEx.insert(i) } else { openEx.remove(i) } })) {
                                    DailyText(text: e.solution, size: 15).padding(.top, 6)
                                } label: { Text(T("Solution", "解答")).font(.subheadline) }
                            }
                            if i < d.examples.count - 1 { Divider() }
                        }
                    }
                    .card()
                }

                NavigationLink(value: Route.dailyRun(d.date)) {
                    Label(s.done ? T("Review answers", "回看答案") : (r.mc.isEmpty && r.marks.isEmpty ? T("Start", "开始做题") : T("Continue", "继续做题")),
                          systemImage: s.done ? "doc.text.magnifyingglass" : "pencil.and.outline")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .glassButton(prominent: true)

                if let n = d.answerNote { Text(n).font(.footnote).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: 820)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .softEdges()
    }
}

// MARK: - Doing the paper

struct DailyRunner: View {
    let date: String
    @Environment(\.tr) private var T
    @State private var store = DailyStore.shared
    @AppStorage("math.split.on") private var splitOn = true
    @State private var index = 0
    @State private var confirmSubmit = false

    var body: some View {
        Group {
            if let d = store.loaded[date] {
                let qs = d.questions
                if index >= qs.count {
                    summary(d)
                } else {
                    let q = qs[index]
                    let scratch = d.scratch ?? false
                    let on = scratch && splitOn
                    WorkSplit(on: on, sheetID: "daily-" + date, figs: on ? [store.image(q.figure)].compactMap { $0 } : []) {
                        question(d, q, inlineFigure: !on).id(q.id)
                    } bar: {
                        pageBar(d)
                    }
                }
            } else {
                ProgressView().task { _ = await store.day(date) }
            }
        }
        .appScreen()
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let d = store.loaded[date] {
                if d.scratch ?? false {
                    ToolbarItem(placement: .primaryAction) {
                        Button { withAnimation { splitOn.toggle() } } label: {
                            Image(systemName: splitOn ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                        }
                        .accessibilityLabel(T("Split", "分屏"))
                    }
                }
            }
        }
        .confirmationDialog(T("Submit this paper?", "确定交卷？"), isPresented: $confirmSubmit, titleVisibility: .visible) {
            Button(T("Submit", "交卷")) { submit() }
            Button(T("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(T("Questions you haven't self-marked count as 0.", "没有自评的题目按 0 分计。"))
        }
        .deepSeek(dsContext)
        .workingSession("daily-" + date)
    }

    @ViewBuilder private func pageBar(_ d: DailyDay) -> some View {
        PageCluster(index: index, count: d.questions.count,
                    prev: index > 0 ? { index -= 1 } : nil,
                    next: index < d.questions.count - 1 ? { index += 1 } : nil)
        if index == d.questions.count - 1 {
            Button { if (store.results[date] ?? DailyResult()).submitted { index += 1 } else { confirmSubmit = true } } label: {
                Label(T("Submit", "交卷"), systemImage: "flag.checkered")
            }
            .glassButton(prominent: true)
        }
    }

    private var dsContext: DSContext? {
        guard let d = store.loaded[date], index < d.questions.count else { return nil }
        let q = d.questions[index]
        let r = store.results[date] ?? DailyResult()
        let L = ["A", "B", "C", "D", "E", "F"]
        var page = "Q\(q.n)（\(q.marks) 分）\n" + q.stem
        if let o = q.options { page += "\n" + o.enumerated().map { "\(L[min($0.offset, 5)]). " + $0.element }.joined(separator: "\n") }
        for p in q.parts ?? [] { page += "\n(\(p.label)) " + p.text + "（\(p.marks) 分）" }
        var rev: String?
        var all = ""
        if let a = q.answer, !a.isEmpty { all += "答案：" + a + "\n" }
        if let c = r.mc[q.id] { all += "学生选了 " + c + "\n" }
        for p in q.parts ?? [] { all += "(\(p.label)) " + p.answer + "\n" }
        if let x = q.solution, !x.isEmpty { all += "解答：" + x }
        let shown = r.submitted || (q.isMC && r.mc[q.id] != nil)
        if shown { rev = all.isEmpty ? nil : all }
        let imgs = [store.image(q.figure)].compactMap { $0 }
        var ctx = DSContext(key: "daily-\(date)-\(q.id)", subject: d.subject, title: "\(DailySubject.name(d.subject, T)) \(date) · Q\(q.n)",
                            page: page, images: imgs, revealed: rev, answer: shown ? nil : (all.isEmpty ? nil : all),
                            chapter: d.keyPoints.isEmpty ? nil : (d.scope.map { $0 + "\n" } ?? "") + d.keyPoints.map { "- " + $0 }.joined(separator: "\n"),
                            sheetID: (d.scratch ?? false) ? "daily-" + date : nil)
        if r.submitted, !q.isMC, let s = rev {
            let date = date, qid = q.id, parts = q.parts ?? []
            ctx.grade = DSGradeSpec(question: page, scheme: s, maxMarks: q.marks, images: imgs) { score in
                var res = DailyStore.shared.results[date] ?? DailyResult()
                if parts.isEmpty { res.marks[qid] = score } else {
                    var left = score
                    for p in parts { let v = min(left, p.marks); res.marks[qid + "#" + p.label] = v; left -= v }
                }
                DailyStore.shared.results[date] = res
            }
        }
        return ctx
    }

    private var navTitle: String {
        guard let d = store.loaded[date] else { return T("Daily Practice", "每日练习") }
        return "\(DailySubject.name(d.subject, T)) · \(date)"
    }

    private func binding(_ f: @escaping (inout DailyResult) -> Void) {
        var r = store.results[date] ?? DailyResult()
        f(&r)
        store.results[date] = r
        if store.allMarked(date) == true { ReviewStore.shared.finish("daily-" + date) }
    }

    private func submit() {
        guard let d = store.loaded[date] else { return }
        binding { $0.submitted = true; $0.revealed = d.questions.map { $0.id } }
        if d.questions.contains(where: { !$0.isMC }) {
            ReviewStore.shared.handIn("daily-" + date, title: "\(T("Daily", "每日练习")) · \(DailySubject.name(d.subject, T)) \(date)", route: "daily:" + date)
        } else {
            ScratchStore.shared.clear()
        }
        let s = store.score(d)
        ProgressStore.shared.saveRun(RunRecord(t: Date().timeIntervalSince1970, title: "\(T("Daily", "每日练习")) · \(DailySubject.name(d.subject, T)) \(date)", got: s.got, tot: s.tot))
        index = d.questions.count
    }

    private func question(_ d: DailyDay, _ q: DailyQuestion, inlineFigure: Bool) -> some View {
        let r = store.results[date] ?? DailyResult()
        let revealed = r.submitted
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("Q\(q.n)").font(.headline)
                    Text(T("\(q.marks) marks", "\(q.marks) 分")).font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.secondary.opacity(0.15), in: Capsule())
                    Spacer()
                    if let s = q.source, !s.isEmpty {
                        Text(s).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
                DailyText(text: q.stem, size: 18)
                if inlineFigure, let img = store.image(q.figure) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 560)
                        .padding(6).background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                }
                if q.isMC { mc(q, r) } else { written(q, r, revealed) }
            }
            .padding()
            .textSelection(.enabled)
        }
        .softEdges()
    }

    private func choose(_ q: DailyQuestion, _ r: DailyResult, _ i: Int) {
        let letters = ["A", "B", "C", "D", "E", "F"]
        guard r.mc[q.id] == nil, !r.submitted, i < (q.options ?? []).count else { return }
        let L = letters[min(i, 5)]
        let isAns = L == (q.answer ?? "").trimmingCharacters(in: CharacterSet.letters.inverted).uppercased().prefix(1).description
        binding { $0.mc[q.id] = L }
        ProgressStore.shared.record("daily:" + q.id, ok: isAns)
        // Instant feedback here: only move on after a right answer, and only after 1 s.
        if isAns, UserDefaults.standard.bool(forKey: "autoNext"), let d = store.loaded[date], index < d.questions.count - 1 {
            let here = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { if index == here { withAnimation { index += 1 } } }
        }
    }

    @ViewBuilder private func mc(_ q: DailyQuestion, _ r: DailyResult) -> some View {
        let chosen = r.mc[q.id]
        let letters = ["A", "B", "C", "D", "E", "F"]
        ForEach(Array((q.options ?? []).enumerated()), id: \.offset) { i, opt in
            let L = letters[min(i, 5)]
            let isAns = L == (q.answer ?? "").trimmingCharacters(in: CharacterSet.letters.inverted).uppercased().prefix(1).description
            Button {
                choose(q, r, i)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    MCLetter(l: L, color: chosen == nil ? Color.accentColor : (isAns ? Color.good : (chosen == L ? Color.bad : .secondary)))
                    DailyText(text: opt, size: 17)
                    if chosen != nil && (isAns || chosen == L) {
                        Image(systemName: isAns ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(isAns ? Color.good : Color.bad)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mcGlass(chosen == nil ? .idle : (isAns ? .correct : (chosen == L ? .wrong : .idle)))
            }
            .buttonStyle(.plain)
        }
        Color.clear.frame(height: 0)
            .padMC("daily-" + q.id, count: r.submitted || chosen != nil ? 0 : (q.options ?? []).count,
                   selected: nil, pick: { i in choose(q, r, i) })
        if chosen != nil || r.submitted, let s = q.solution, !s.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(T("Solution", "解答") + " · " + (q.answer ?? ""), systemImage: "text.book.closed").font(.headline)
                DailyText(text: s, size: 16)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder private func written(_ q: DailyQuestion, _ r: DailyResult, _ revealed: Bool) -> some View {
        if let ps = q.parts, !ps.isEmpty {
            ForEach(ps, id: \.label) { p in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(p.label).font(.headline.monospaced())
                        DailyText(text: p.text, size: 17)
                        Text("(\(p.marks))").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if revealed { markBox(q, p.answer, key: q.id + "#" + p.label, max: p.marks, part: p.text, r) }
                }
                .padding(.vertical, 4)
            }
        } else if revealed, let a = q.answer ?? q.solution {
            markBox(q, a, key: q.id, max: q.marks, part: nil, r)
        }
        if !revealed {
            Text(T("Answers and self-marking open after 交卷.", "交卷后才能看答案和自评。")).font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
        }
    }

    /// Answer + 得分点 self-marking (+ DeepSeek on the scratch sheet). Unmarked stays nil = 未评分.
    private func markBox(_ q: DailyQuestion, _ text: String, key: String, max: Int, part: String?, _ r: DailyResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Label(T("Answer", "答案"), systemImage: "text.book.closed").font(.subheadline.bold())
                DailyText(text: text, size: 15)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            LongMarkCard(key: "daily:" + date + ":" + key, question: q.stem + (part.map { "\n" + $0 } ?? ""), scheme: text,
                         sheetID: "daily-" + date, max: max,
                         score: Binding(get: { (store.results[date] ?? DailyResult()).marks[key] },
                                        set: { v in binding { $0.marks[key] = v } }))
        }
    }

    private func answerBox(_ text: String, key: String, max: Int, _ r: DailyResult) -> some View {
        let got = r.marks[key]
        return VStack(alignment: .leading, spacing: 10) {
            Label(T("Answer", "答案"), systemImage: "text.book.closed").font(.subheadline.bold())
            DailyText(text: text, size: 15)
            HStack(spacing: 6) {
                Text(T("My score", "我的得分")).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                ForEach(0...max, id: \.self) { v in
                    Button { binding { $0.marks[key] = v } } label: {
                        Text("\(v)").font(.subheadline.monospacedDigit().bold())
                            .frame(minWidth: 34, minHeight: 30)
                            .background(got == v ? Color.accentColor : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .foregroundStyle(got == v ? Color.white : Color.primary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func summary(_ d: DailyDay) -> some View {
        let s = store.score(d)
        let r = store.results[date] ?? DailyResult()
        let mcs = d.questions.filter { $0.isMC }
        let mcGot = mcs.filter { r.mc[$0.id] == $0.answer }.count
        return ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(Color.accentColor)
                let open = d.questions.filter { unmarked($0, r) }.count
                Text("\(s.got) / \(s.tot)").font(.largeTitle.bold().monospacedDigit())
                if open > 0 {
                    Text(T("\(open) questions not marked yet (not counted)", "\(open) 题未评分（暂不计分）")).font(.subheadline.bold()).foregroundStyle(.orange)
                }
                if ReviewStore.shared.inReview("daily-" + date) {
                    Text(T("Open each written question, mark the points yourself or let DeepSeek mark your scratch, then tap Settle.", "逐题按得分点自评，或让 DeepSeek 按草稿纸批改，然后按「结算」。")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(T("Settle", "结算")) { ReviewStore.shared.finish("daily-" + date) }.glassButton(prominent: true)
                }
                if !mcs.isEmpty {
                    Text(T("MC \(mcGot)/\(mcs.count) correct", "选择题对 \(mcGot)/\(mcs.count) 题")).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(d.questions.enumerated()), id: \.offset) { i, q in
                        Button { index = i } label: {
                            HStack {
                                Text("Q\(q.n)").font(.body.monospaced())
                                Text(q.source ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                if unmarked(q, r) {
                                    Text(T("Not marked", "未评分")).font(.subheadline.bold()).foregroundStyle(.secondary)
                                } else {
                                    Text("\(got(q, r))/\(q.marks)").font(.body.monospacedDigit().bold())
                                        .foregroundStyle(got(q, r) == q.marks ? Color.good : (got(q, r) == 0 ? Color.bad : Color.orange))
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if i < d.questions.count - 1 { Divider() }
                    }
                }
                .card()
                .frame(maxWidth: 620)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .softEdges()
    }

    private func unmarked(_ q: DailyQuestion, _ r: DailyResult) -> Bool {
        if q.isMC { return false }
        if let ps = q.parts, !ps.isEmpty { return ps.contains { r.marks[q.id + "#" + $0.label] == nil } }
        return r.marks[q.id] == nil
    }

    private func got(_ q: DailyQuestion, _ r: DailyResult) -> Int {
        if q.isMC { return r.mc[q.id] == q.answer ? q.marks : 0 }
        if let ps = q.parts, !ps.isEmpty { return ps.reduce(0) { $0 + (r.marks[q.id + "#" + $1.label] ?? 0) } }
        return r.marks[q.id] ?? 0
    }
}
