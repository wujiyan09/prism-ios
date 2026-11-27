import SwiftUI
import Observation
import PDFKit

// MARK: - DeepSeek records: chats, grading, mastery analyses, 错题诊断, plan adjustments.
// Saved on device and synced through the account sync as "ds/…" records. The API key is never stored here.

struct DSChat: Codable, Hashable { var title: String; var t: Double; var msgs: [DSMessage] }

struct DSRecord: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var kind: String        // grade | mastery | diag | adjust
    var t: Double = Date().timeIntervalSince1970
    var scope: String       // question key / chapter id / exam id
    var title: String
    var body: String        // JSON returned by DeepSeek (or summary text)
    var date: Date { Date(timeIntervalSince1970: t) }
}

struct DSExtra: Codable, Hashable, Identifiable {
    var id: String = "ds-" + UUID().uuidString.prefix(8).lowercased()
    var kind: String        // cards | questions | mc
    var chapterID: String
    var keys: [String] = []
    var card: Int? = nil
    var label: String
    var minutes: Int = 15
}

struct DSPlanState: Codable, Hashable {
    var extras: [DSExtra] = []
    var caps: [String: Int] = [:]       // yyyy-MM-dd → minutes (0 = rest day)
    var priority: [String: Int] = [:]   // chapter id → +1/+2 more, -1/-2 less
    var notes: [String] = []
    var isEmpty: Bool { extras.isEmpty && caps.isEmpty && priority.isEmpty }
}

@Observable
final class DSStore {
    static let shared = DSStore()
    var chats: [String: DSChat] = [:] { didSet { save() } }
    var records: [String: DSRecord] = [:] { didSet { save() } }
    var plans: [String: DSPlanState] = [:] { didSet { save() } }

    private struct Saved: Codable { var chats: [String: DSChat]; var records: [String: DSRecord]; var plans: [String: DSPlanState] }
    private static var file: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("deepseek-records.json")
    }
    private var loading = true
    init() {
        if let d = try? Data(contentsOf: Self.file), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            chats = s.chats; records = s.records; plans = s.plans
        }
        loading = false
    }
    private func save() {
        guard !loading else { return }
        if let d = try? JSONEncoder().encode(Saved(chats: chats, records: records, plans: plans)) { try? d.write(to: Self.file, options: .atomic) }
    }

    @discardableResult
    func add(_ kind: String, scope: String, title: String, body: String) -> DSRecord {
        let r = DSRecord(kind: kind, scope: scope, title: title, body: body)
        records[r.id] = r
        return r
    }
    func history(_ scope: String, _ kind: String? = nil) -> [DSRecord] {
        records.values.filter { $0.scope == scope && (kind == nil || $0.kind == kind) }.sorted { $0.t > $1.t }
    }
    func plan(_ id: UUID) -> DSPlanState { plans[id.uuidString] ?? DSPlanState() }
    func setPlan(_ id: UUID, _ p: DSPlanState) { plans[id.uuidString] = p }
    func clearChats() { chats = [:] }
    /// Auto-delete (设置 › DeepSeek): chats unused for N days; 0 = never.
    func prune() {
        let days = UserDefaults.standard.object(forKey: "ds.autoDelete") as? Int ?? 30
        guard days > 0 else { return }
        let cut = Date().timeIntervalSince1970 - Double(days) * 86400
        let old = chats.filter { $0.value.t < cut }.map(\.key)
        guard !old.isEmpty else { return }
        for k in old { chats[k] = nil }
    }

    // Sync
    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return e }()
    private static func j<T: Encodable>(_ x: T) -> String? { (try? enc.encode(x)).flatMap { String(data: $0, encoding: .utf8) } }
    func collect() -> [String: String] {
        var o: [String: String] = [:]
        for (k, v) in chats { o["ds/chat/" + k] = Self.j(v) }
        for (k, v) in records { o["ds/r/" + k] = Self.j(v) }
        for (k, v) in plans { o["ds/plan/" + k] = Self.j(v) }
        return o
    }
    /// `id` is everything after "ds/".
    func apply(_ recs: [(id: String, v: String?, d: Bool)]) {
        guard !recs.isEmpty else { return }
        var c = chats, r = records, p = plans
        for x in recs {
            guard let i = x.id.firstIndex(of: "/") else { continue }
            let kind = String(x.id[..<i]), k = String(x.id[x.id.index(after: i)...])
            let data = x.v?.data(using: .utf8)
            switch kind {
            case "chat": c[k] = x.d ? nil : data.flatMap { try? JSONDecoder().decode(DSChat.self, from: $0) }
            case "r": r[k] = x.d ? nil : data.flatMap { try? JSONDecoder().decode(DSRecord.self, from: $0) }
            case "plan": p[k] = x.d ? nil : data.flatMap { try? JSONDecoder().decode(DSPlanState.self, from: $0) }
            default: break
            }
        }
        chats = c; records = r; plans = p
    }
}

// MARK: - Planner hooks (rule-based planner stays in charge; these only add constraints and extra tasks)

enum DSPlan {
    static var preview: (UUID, DSPlanState)?
    static func state(_ e: Exam) -> DSPlanState {
        if let p = preview, p.0 == e.id { return p.1 }
        return DSStore.shared.plan(e.id)
    }
    static let dayFmt: DateFormatter = { let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()

    static func mastery(_ e: Exam, _ chapter: String) -> Int {
        let m = e.mastery[chapter] ?? 1
        return min(5, max(1, m - (state(e).priority[chapter] ?? 0)))
    }
    static func budget(_ e: Exam, _ day: Date, _ def: Int) -> Int {
        state(e).caps[dayFmt.string(from: day)] ?? def
    }
    static func extras(_ e: Exam) -> [PlanTask] {
        state(e).extras.map {
            PlanTask(id: $0.id, kind: $0.kind == "cards" ? .cards : .practice, chapterID: $0.chapterID, topic: nil, minutes: $0.minutes)
        }
    }
    static func title(_ t: PlanTask, _ e: Exam? = nil) -> String? {
        guard t.id.hasPrefix("ds-") else { return nil }
        for p in DSStore.shared.plans.values { if let x = p.extras.first(where: { $0.id == t.id }) { return "✦ " + x.label } }
        return nil
    }
    /// Starts a DeepSeek extra task. Returns false for normal tasks.
    static func start(_ t: PlanTask, _ e: Exam, _ scene: SceneModel, _ store: ExamStore, _ lib: Library) -> Bool {
        guard t.id.hasPrefix("ds-"), let x = state(e).extras.first(where: { $0.id == t.id }) else { return false }
        let ict = lib.chapter(x.chapterID) != nil
        switch x.kind {
        case "cards":
            store.tick(e.id, t.id)
            scene.open(.learn, ict ? .cards(x.chapterID, x.card ?? 0) : .mathCards(x.chapterID, x.card ?? 0))
        default:
            let ictKeys = x.keys.filter { lib.items[$0] != nil }
            if !ictKeys.isEmpty {
                scene.start(x.label, ictKeys, planTask: (e.id, t.id))
            } else if let first = x.keys.first(where: { MathLibrary.shared.item($0) != nil }) {
                store.tick(e.id, t.id)
                scene.open(.learn, .mathItem(first))
            } else {
                store.tick(e.id, t.id)
                scene.open(.quiz, .mathQuiz(.custom([x.chapterID], 10, true)))
            }
        }
        return true
    }
    static func add(_ extras: [DSExtra], to e: Exam) {
        var p = DSStore.shared.plan(e.id)
        p.extras += extras
        DSStore.shared.setPlan(e.id, p)
    }
}

// MARK: - Gathering results for prompts

enum DSStudy {
    struct Q { let key: String; let chapter: String; let sec: String; let text: String; let ok: Bool?; let tries: Int }

    static func cut(_ s: String, _ n: Int = 260) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    static func mcText(_ qid: String) -> String {
        MathMC.shared.sets.lazy.flatMap { $0.qs }.first { $0.id == qid }?.v.first?.st ?? ""
    }

    /// Questions with a result in one chapter (ICT or maths/中文).
    static func questions(_ chapterID: String) -> [Q] {
        let prog = ProgressStore.shared
        var out: [Q] = []
        if let c = Library.shared.chapter(chapterID) {
            for k in c.mc + c.sq {
                let ok = prog.mark(k) ?? prog.lastResult(k)
                let tries = prog.hist[k]?.r.count ?? 0
                guard ok != nil || tries > 0, let it = Library.shared.items[k] else { continue }
                out.append(Q(key: k, chapter: c.id, sec: it.sec, text: cut(DSContext.plain(it.q)), ok: ok, tries: tries))
            }
        } else if let c = MathLibrary.shared.chapter(chapterID) {
            for it in c.items {
                let k = MathItemKey.key(c, it)
                guard let ok = prog.mark(k) else { continue }
                out.append(Q(key: it.id, chapter: c.id, sec: [it.sec, it.st].compactMap { $0 }.joined(separator: " "), text: cut((it.l) + " " + (it.qt ?? "（题目为图片）")), ok: ok, tries: 1))
            }
            for s in c.sets {
                for qid in s.qids {
                    let k = MathMC.key(qid)
                    let ok = prog.mark(k) ?? prog.lastResult(k)
                    let tries = prog.hist[k]?.r.count ?? 0
                    guard ok != nil || tries > 0 else { continue }
                    out.append(Q(key: k, chapter: c.id, sec: s.l, text: cut(mcText(qid)), ok: ok, tries: tries))
                }
            }
        }
        return out
    }

    static func cardList(_ chapterID: String, limit: Int = 80) -> String {
        if let c = Library.shared.chapter(chapterID) {
            return c.cards.prefix(limit).enumerated().map { "card \($0.offset): \($0.element.t)" }.joined(separator: "\n")
        }
        if let c = MathLibrary.shared.chapter(chapterID) {
            return c.cards.prefix(limit).enumerated().map { "card \($0.offset): \(cut($0.element.t ?? "", 80))" }.joined(separator: "\n")
        }
        return ""
    }

    static func chapterTitle(_ id: String) -> String {
        Library.shared.chapter(id)?.name ?? MathLibrary.shared.chapter(id)?.label ?? id
    }

    static func cardsRead(_ id: String) -> (Int, Int) {
        let n = Library.shared.chapter(id)?.nCards ?? MathLibrary.shared.chapter(id)?.nCards ?? 0
        let r = (0..<n).filter { ProgressStore.shared.seen.contains("\(id)-\($0)") }.count
        return (r, n)
    }

    static func qLine(_ q: Q) -> String {
        let r = q.ok == true ? "✓" : (q.ok == false ? "✗" : "-")
        return "[\(q.key)] \(r) 做过\(q.tries)次 · \(q.sec) · \(q.text)"
    }

    /// Exams whose scope includes the chapter and haven't happened yet.
    static func exams(for chapterID: String) -> [Exam] {
        ExamStore.shared.exams.filter { e in
            Planner.days(until: e.date) > 0 &&
            (e.chapters.contains(chapterID) || Planner.scopeChapters(e, Library.shared).contains { $0.id == chapterID })
        }
    }

    static func scopeChapterIDs(_ e: Exam) -> [String] {
        e.usesMathLib ? Planner.zhChapters(e).map(\.id) : Planner.scopeChapters(e, Library.shared).map(\.id)
    }

    static func extras(chapter: String, cards: [Int], questions: [String], label: String) -> [DSExtra] {
        var x: [DSExtra] = []
        for i in cards.prefix(4) { x.append(DSExtra(kind: "cards", chapterID: chapter, card: i, label: "复习知识卡 \(i + 1) · " + label, minutes: 10)) }
        if !questions.isEmpty { x.append(DSExtra(kind: "questions", chapterID: chapter, keys: questions, label: "针对练习 \(questions.count) 题 · " + label, minutes: min(30, max(10, questions.count * 3)))) }
        return x
    }
}

// MARK: - 掌握程度分析 (chapter page)

struct DSMastery: Codable, Hashable {
    struct Sub: Codable, Hashable { var name: String; var level: Int; var note: String }
    var level: Int
    var summary: String
    var subtopics: [Sub]
    var misconceptions: [String]
    var cards: [Int]
    var questions: [String]

    static func parse(_ s: String) -> DSMastery? {
        guard let o = dsJSON(s) else { return nil }
        func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? Int(v as? String ?? "") ?? 0 }
        let subs = (o["subtopics"] as? [[String: Any]] ?? []).map { Sub(name: $0["name"] as? String ?? "", level: min(5, max(1, int($0["level"]))), note: $0["note"] as? String ?? "") }
        return DSMastery(level: min(5, max(1, int(o["level"]))), summary: o["summary"] as? String ?? "", subtopics: subs,
                         misconceptions: o["misconceptions"] as? [String] ?? [],
                         cards: (o["cards"] as? [Any] ?? []).map { int($0) - 0 },
                         questions: (o["questions"] as? [Any] ?? []).compactMap { $0 as? String })
    }
}

func dsJSON(_ s: String) -> [String: Any]? {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}") { t = String(t[a...b]) }
    return DSJSON.object(t)
}

func dsErr(_ e: Error) -> String { (e as? DSError)?.errorDescription ?? e.localizedDescription }

struct DSMasterySection: View {
    let chapterID: String
    var autoRun = false
    @State private var store = DSStore.shared
    @State private var busy = false
    @State private var error: String?
    @State private var showAll = false

    var body: some View {
        let hist = store.history(chapterID, "mastery")
        Section {
            if let r = hist.first, let m = DSMastery.parse(r.body) {
                DSMasteryCard(chapterID: chapterID, record: r, m: m)
            }
            Button { run() } label: {
                HStack {
                    Label(hist.isEmpty ? "分析掌握程度" : "重新分析", systemImage: "sparkles")
                    Spacer()
                    if busy { ProgressView() }
                }
            }
            .disabled(busy)
            if let e = error { Text(e).font(.footnote).foregroundStyle(.red) }
            if hist.count > 1 {
                DisclosureGroup("历史（\(hist.count - 1)）", isExpanded: $showAll) {
                    ForEach(hist.dropFirst()) { r in
                        if let m = DSMastery.parse(r.body) {
                            NavigationLink {
                                ScrollView { DSMasteryCard(chapterID: chapterID, record: r, m: m).padding() }
                                    .navigationTitle(r.date.formatted(date: .abbreviated, time: .shortened))
                            } label: {
                                HStack {
                                    Text(r.date.formatted(date: .abbreviated, time: .shortened))
                                    Spacer()
                                    Text("掌握度 \(m.level)/5").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        } header: { Text("掌握程度分析 · DeepSeek") } footer: {
            Text("根据本章每题的 ✓/✗、选择题记录、读卡进度和最近一次交卷的草稿纸分析；结果保存在本机并同步。")
        }
        .listRowBackground(Color.cardBackground)
        .onAppear { if autoRun && !busy { run() } }
    }

    private func run() {
        guard DSKey.has else { error = DSError.noKey.errorDescription; return }
        let qs = DSStudy.questions(chapterID)
        guard !qs.isEmpty else { error = "本章还没有做题记录，先做一些练习再分析。"; return }
        busy = true; error = nil
        let read = DSStudy.cardsRead(chapterID)
        let title = DSStudy.chapterTitle(chapterID)
        let prompt = """
        分析学生对这一章的掌握程度。
        章节：\(title)
        知识卡已读 \(read.0)/\(read.1)。
        【知识卡列表（编号从 0 开始）】
        \(DSStudy.cardList(chapterID))

        【做题记录】格式：[题目 id] ✓/✗ 次数 · 小节 · 题目
        \(qs.prefix(120).map(DSStudy.qLine).joined(separator: "\n"))

        只输出 JSON：
        {"level":1到5的整数(1=很弱,5=熟练),"summary":"两三句总评","subtopics":[{"name":"小节/子题","level":1到5,"note":"强项或弱点，具体"}],"misconceptions":["具体的错误理解，例如“分不清排列和组合”"],"cards":[建议复习的卡编号],"questions":["建议重做或接下来练的题目 id，必须来自上面的列表"]}
        """
        let m = DSModel.current
        let snap = DSSnap.image(chapterID)
        let text = prompt + (snap != nil && m.vision ? "\n附图：学生最近一次交卷时的草稿纸（含做错的题），可以从中找出具体错因。" : "")
        Task {
            do {
                let s = try await DSClient.complete([["role": "system", "content": DSClient.systemPrompt], DSClient.message("user", DSPart(text: text, images: [snap].compactMap { $0 }), vision: m.vision)], model: m, json: true)
                if DSMastery.parse(s) != nil { store.add("mastery", scope: chapterID, title: title, body: s) }
                else { error = "分析结果无法解析，再试一次。" }
            } catch { self.error = dsErr(error) }
            busy = false
        }
    }
}

struct DSMasteryCard: View {
    let chapterID: String
    let record: DSRecord
    let m: DSMastery
    @Environment(SceneModel.self) private var scene
    @State private var added: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("掌握度").font(.subheadline.bold())
                HStack(spacing: 2) { ForEach(1...5, id: \.self) { i in Image(systemName: i <= m.level ? "circle.fill" : "circle").font(.caption2) } }
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            if !m.summary.isEmpty { MathText(text: m.summary, size: 15) }
            ForEach(m.subtopics, id: \.self) { s in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: s.level >= 4 ? "checkmark.circle.fill" : (s.level <= 2 ? "exclamationmark.circle.fill" : "circle.lefthalf.filled"))
                        .foregroundStyle(s.level >= 4 ? Color.green : (s.level <= 2 ? Color.red : Color.orange))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).font(.subheadline.bold())
                        if !s.note.isEmpty { MathText(text: s.note, size: 14, color: .secondary) }
                    }
                }
            }
            if !m.misconceptions.isEmpty {
                Text("常见误解").font(.subheadline.bold())
                ForEach(m.misconceptions, id: \.self) { MathText(text: "• " + $0, size: 14) }
            }
            if !m.cards.isEmpty || !m.questions.isEmpty {
                Text("建议：复习 \(m.cards.count) 张卡、练 \(m.questions.count) 题").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button { practise() } label: { Label("练这些题", systemImage: "pencil") }.glassButton(prominent: true)
                    Button { addToPlan() } label: { Label("加入备考计划", systemImage: "calendar.badge.plus") }.glassButton()
                }
                .controlSize(.small)
            }
            if let a = added { Text(a).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }

    private func practise() {
        let lib = Library.shared
        let ict = m.questions.filter { lib.items[$0] != nil }
        if !ict.isEmpty { scene.start("推荐练习 · " + record.title, ict); return }
        if let first = m.questions.first(where: { MathLibrary.shared.item($0) != nil }) { scene.open(.learn, .mathItem(first)); return }
        if let c = m.cards.first { scene.open(.learn, lib.chapter(chapterID) != nil ? .cards(chapterID, c) : .mathCards(chapterID, c)); return }
        scene.open(.quiz, .mathQuiz(.custom([chapterID], 10, true)))
    }

    private func addToPlan() {
        let ex = DSStudy.exams(for: chapterID)
        guard !ex.isEmpty else { added = "没有包含本章、还没考的备考计划。先在 备考计划 里加一个。"; return }
        for e in ex {
            DSPlan.add(DSStudy.extras(chapter: chapterID, cards: m.cards, questions: m.questions, label: record.title), to: e)
            var x = e
            x.mastery[chapterID] = m.level
            ExamStore.shared.update(x)
        }
        added = "已加入 \(ex.map { $0.name.isEmpty ? "考试" : $0.name }.joined(separator: "、"))，掌握度设为 \(m.level)/5（可在编辑里改）。"
    }
}

// MARK: - 备考计划: 弱点分析 + 一句话调计划

struct DSDiag: Codable, Hashable {
    struct Point: Codable, Hashable { var title: String; var detail: String; var chapter: String; var cards: [Int]; var questions: [String] }
    var points: [Point]
    static func parse(_ s: String) -> DSDiag? {
        guard let o = dsJSON(s) else { return nil }
        let pts = (o["points"] as? [[String: Any]] ?? []).map {
            Point(title: $0["title"] as? String ?? "", detail: $0["detail"] as? String ?? "", chapter: $0["chapter"] as? String ?? "",
                  cards: ($0["cards"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue },
                  questions: ($0["questions"] as? [Any] ?? []).compactMap { $0 as? String })
        }
        return DSDiag(points: pts)
    }
}

struct DSAdjust: Codable, Hashable {
    var caps: [String: Int]
    var priority: [String: Int]
    var summary: String
    static func parse(_ s: String) -> DSAdjust? {
        guard let o = dsJSON(s) else { return nil }
        var caps: [String: Int] = [:]
        for (k, v) in o["caps"] as? [String: Any] ?? [:] { if let n = (v as? NSNumber)?.intValue { caps[k] = max(0, n) } }
        for d in o["skip"] as? [String] ?? [] { caps[d] = 0 }
        var pr: [String: Int] = [:]
        for (k, v) in o["priority"] as? [String: Any] ?? [:] { if let n = (v as? NSNumber)?.intValue { pr[k] = min(2, max(-2, n)) } }
        return DSAdjust(caps: caps.filter { DSPlan.dayFmt.date(from: $0.key) != nil }, priority: pr, summary: o["summary"] as? String ?? "")
    }
}

struct DSPlanSection: View {
    let exam: Exam
    @State private var store = DSStore.shared
    @State private var busy = false
    @State private var error: String?
    @State private var text = ""
    @State private var pending: DSAdjust?
    @State private var showLog = false

    var body: some View {
        let diag = store.history(exam.id.uuidString, "diag")
        let state = store.plan(exam.id)
        Section {
            if let r = diag.first, let d = DSDiag.parse(r.body) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("弱点分析").font(.subheadline.bold())
                        Spacer()
                        Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    if d.points.isEmpty { Text("没有发现明显弱点。").font(.footnote).foregroundStyle(.secondary) }
                }
                ForEach(Array(d.points.enumerated()), id: \.offset) { i, p in
                    DSDiagRow(exam: exam, point: p, recordID: r.id + "-\(i)")
                }
            }
            Button { diagnose() } label: {
                HStack { Label(diag.isEmpty ? "错题诊断" : "重新诊断错题", systemImage: "stethoscope"); Spacer(); if busy && pending == nil { ProgressView() } }
            }
            .disabled(busy)

            VStack(alignment: .leading, spacing: 8) {
                TextField("一句话调计划，例如：周一要交CSD，这两天少排点", text: $text, axis: .vertical)
                    .lineLimit(1...3)
                HStack {
                    Spacer()
                    Button("生成调整") { adjust() }.glassButton().controlSize(.small)
                        .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let a = pending { preview(a) }
            if !state.caps.isEmpty || !state.priority.isEmpty || !state.extras.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已生效的调整").font(.footnote.bold())
                    ForEach(state.caps.sorted { $0.key < $1.key }, id: \.key) { k, v in
                        Text("\(k)：\(v == 0 ? "休息" : "最多 \(v) 分钟")").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(state.priority.sorted { $0.key < $1.key }, id: \.key) { k, v in
                        Text("\(DSStudy.chapterTitle(k))：\(v > 0 ? "多排" : "少排")").font(.caption).foregroundStyle(.secondary)
                    }
                    if !state.extras.isEmpty { Text("额外任务 \(state.extras.count) 个（✦）").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("清除时间调整") { var p = state; p.caps = [:]; p.priority = [:]; store.setPlan(exam.id, p) }
                        Button("清除额外任务") { var p = state; p.extras = []; store.setPlan(exam.id, p) }
                    }
                    .font(.caption).buttonStyle(.borderless)
                }
            }
            if let e = error { Text(e).font(.footnote).foregroundStyle(.red) }
            let log = store.history(exam.id.uuidString).filter { $0.kind == "adjust" || $0.kind == "diag" }
            if !log.isEmpty {
                DisclosureGroup("历史（\(log.count)）", isExpanded: $showLog) {
                    ForEach(log) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text((r.kind == "diag" ? "错题诊断 · " : "调计划 · ") + r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption.bold())
                            Text(r.kind == "diag" ? (DSDiag.parse(r.body)?.points.map(\.title).joined(separator: "；") ?? "") : r.title)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: { Text("DeepSeek") } footer: {
            Text("排期仍按规则计算；DeepSeek 只找弱点和把你的话变成限制条件，应用前会先给你看改动。")
        }
        .listRowBackground(Color.cardBackground)
    }

    private func preview(_ a: DSAdjust) -> some View {
        var next = store.plan(exam.id)
        for (k, v) in a.caps { next.caps[k] = v }
        for (k, v) in a.priority { next.priority[k] = v }
        let lib = Library.shared
        let before = Planner.plan(exam, lib)
        DSPlan.preview = (exam.id, next)
        let after = Planner.plan(exam, lib)
        DSPlan.preview = nil
        func mins(_ p: [(day: Date, tasks: [PlanTask])]) -> [Date: Int] {
            Dictionary(p.map { ($0.day, $0.tasks.reduce(0) { $0 + $1.minutes }) }, uniquingKeysWith: +)
        }
        let b = mins(before), f = mins(after)
        let days = Set(b.keys).union(f.keys).sorted().filter { b[$0] != f[$0] }
        return VStack(alignment: .leading, spacing: 6) {
            Text("预览改动").font(.subheadline.bold())
            if !a.summary.isEmpty { Text(a.summary).font(.footnote) }
            ForEach(days, id: \.self) { d in
                HStack {
                    Text(d.formatted(.dateTime.month().day().weekday(.abbreviated)))
                    Spacer()
                    Text("\(b[d] ?? 0) → \(f[d] ?? 0) 分钟").monospacedDigit()
                        .foregroundStyle((f[d] ?? 0) < (b[d] ?? 0) ? Color.green : Color.orange)
                }
                .font(.caption)
            }
            ForEach(a.priority.sorted { $0.key < $1.key }, id: \.key) { k, v in
                Text("\(DSStudy.chapterTitle(k))：\(v > 0 ? "提高优先级" : "降低优先级")").font(.caption)
            }
            if days.isEmpty && a.priority.isEmpty { Text("这个调整不会改变排期。").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("应用") {
                    store.setPlan(exam.id, next)
                    store.add("adjust", scope: exam.id.uuidString, title: text + (a.summary.isEmpty ? "" : " → " + a.summary), body: (try? String(data: JSONEncoder().encode(a), encoding: .utf8)) ?? "")
                    pending = nil; text = ""
                }
                .glassButton(prominent: true)
                Button("取消", role: .cancel) { pending = nil }.glassButton()
            }
            .controlSize(.small)
        }
    }

    private func diagnose() {
        guard DSKey.has else { error = DSError.noKey.errorDescription; return }
        let chs = DSStudy.scopeChapterIDs(exam)
        var wrong: [DSStudy.Q] = []
        for c in chs { wrong += DSStudy.questions(c).filter { $0.ok == false } }
        if !exam.usesMathLib {
            let lib = Library.shared
            let tps = Set(Planner.scopeTopics(exam, lib))
            for k in lib.dseMC where ProgressStore.shared.lastResult(k) == false {
                if let it = lib.items[k], tps.contains(it.topic ?? "") {
                    wrong.append(.init(key: k, chapter: it.chapterID ?? "", sec: "DSE " + (it.year ?? ""), text: DSStudy.cut(DSContext.plain(it.q)), ok: false, tries: ProgressStore.shared.hist[k]?.r.count ?? 1))
                }
            }
        }
        guard !wrong.isEmpty else { error = "这次考试范围里还没有标 ✗ 的题。"; return }
        busy = true; error = nil
        let cards = chs.prefix(8).map { "== 章节 \($0)（\(DSStudy.chapterTitle($0))）\n" + DSStudy.cardList($0, limit: 40) }.joined(separator: "\n")
        let prompt = """
        这是学生在「\(exam.name)」考试范围内做错的题。找出具体的弱点（不要泛泛而谈，例如“分不清有没有顺序”），每个弱点对应到章节 id、知识卡编号和题目 id。
        【错题】格式：[题目 id] ✗ 次数 · 小节 · 题目
        \(wrong.prefix(60).map { DSStudy.qLine($0) + "（章节 \($0.chapter)）" }.joined(separator: "\n"))

        【各章知识卡（编号从 0 开始）】
        \(cards)

        只输出 JSON：
        {"points":[{"title":"弱点，一句话","detail":"为什么这么判断、怎么补","chapter":"章节 id","cards":[卡编号],"questions":["题目 id，来自上面的错题"]}]}
        最多 6 个弱点，按严重程度排序。
        """
        let m = DSModel.current
        let snaps = chs.compactMap { DSSnap.image($0) }.prefix(3)
        let text = prompt + (!snaps.isEmpty && m.vision ? "\n附图：最近几次交卷时的草稿纸（含做错的题）。" : "")
        Task {
            do {
                let s = try await DSClient.complete([["role": "system", "content": DSClient.systemPrompt], DSClient.message("user", DSPart(text: text, images: Array(snaps)), vision: m.vision)], model: m, json: true)
                if DSDiag.parse(s) != nil { store.add("diag", scope: exam.id.uuidString, title: exam.name, body: s) }
                else { error = "诊断结果无法解析，再试一次。" }
            } catch { self.error = dsErr(error) }
            busy = false
        }
    }

    private func adjust() {
        guard DSKey.has else { error = DSError.noKey.errorDescription; return }
        let req = text.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; error = nil; pending = nil
        let plan = Planner.plan(exam, Library.shared)
        let f = DSPlan.dayFmt
        let wd: DateFormatter = { let x = DateFormatter(); x.locale = Locale(identifier: "zh_CN"); x.dateFormat = "EEEE"; return x }()
        let days = plan.map { "\(f.string(from: $0.day))（\(wd.string(from: $0.day))）：\($0.tasks.reduce(0) { $0 + $1.minutes }) 分钟" }.joined(separator: "\n")
        let chs = DSStudy.scopeChapterIDs(exam).map { "\($0)：\(DSStudy.chapterTitle($0))，掌握度 \(exam.mastery[$0] ?? 1)/5" }.joined(separator: "\n")
        let prompt = """
        把学生的一句话变成对备考计划的限制条件。不要自己排计划，只输出限制。
        今天：\(f.string(from: Date()))（\(wd.string(from: Date()))）
        考试「\(exam.name)」日期：\(f.string(from: exam.date))，平时每天 \(exam.minutes) 分钟。
        【当前每天安排】
        \(days)
        【章节】
        \(chs)
        学生说：\(req)

        只输出 JSON：
        {"caps":{"yyyy-MM-dd":每天最多分钟数},"skip":["完全不排的日期 yyyy-MM-dd"],"priority":{"章节 id":1或2表示多排,-1或-2表示少排},"summary":"一句话说明你理解的调整"}
        没提到的就不要放。
        """
        let m = DSModel.current
        Task {
            do {
                let s = try await DSClient.complete([["role": "system", "content": "你把学生的要求转成结构化 JSON 限制条件。"], ["role": "user", "content": prompt]], model: m, json: true)
                if let a = DSAdjust.parse(s) { pending = a } else { error = "没看懂返回的调整，换个说法再试。" }
            } catch { self.error = dsErr(error) }
            busy = false
        }
    }
}

struct DSDiagRow: View {
    let exam: Exam
    let point: DSDiag.Point
    let recordID: String
    @State private var store = DSStore.shared
    var body: some View {
        let added = store.plan(exam.id).notes.contains(recordID)
        VStack(alignment: .leading, spacing: 4) {
            MathText(text: point.title, size: 15, weight: .semibold)
            if !point.detail.isEmpty { MathText(text: point.detail, size: 13, color: .secondary) }
            HStack {
                Text("\(DSStudy.chapterTitle(point.chapter)) · \(point.cards.count) 张卡 · \(point.questions.count) 题").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(added ? "已加入" : "加入计划") {
                    var p = store.plan(exam.id)
                    p.extras += DSStudy.extras(chapter: point.chapter, cards: point.cards, questions: point.questions, label: point.title)
                    p.notes.append(recordID)
                    store.setPlan(exam.id, p)
                }
                .glassButton().controlSize(.small).disabled(added || point.chapter.isEmpty)
            }
        }
    }
}

// MARK: - History in the panel

struct DSHistoryView: View {
    let scope: String
    @State private var store = DSStore.shared
    @State private var selecting = false
    @State private var picked = Set<String>()
    @State private var confirmDel = false
    var body: some View {
        let grades = store.history(scope, "grade")
        let chats = store.chats.sorted { $0.value.t > $1.value.t }
        List {
            if !grades.isEmpty {
                Section("这题的批改") {
                    ForEach(grades) { r in
                        if let g = DSGradeResult.parse(r.body, max: 0) {
                            NavigationLink {
                                ScrollView { DSGradeCard(result: g, spec: nil).padding() }.navigationTitle(r.date.formatted(date: .abbreviated, time: .shortened))
                            } label: {
                                HStack { Text(r.date.formatted(date: .abbreviated, time: .shortened)); Spacer(); Text("\(g.score)/\(g.max)").monospacedDigit() }
                            }
                        }
                    }
                }
            }
            Section("所有对话") {
                if chats.isEmpty { Text("还没有对话。").foregroundStyle(.secondary) }
                ForEach(chats, id: \.key) { k, c in
                    if selecting {
                        Button { if picked.contains(k) { picked.remove(k) } else { picked.insert(k) } } label: {
                            HStack {
                                Image(systemName: picked.contains(k) ? "checkmark.circle.fill" : "circle").foregroundStyle(picked.contains(k) ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title).lineLimit(1)
                                    Text(Date(timeIntervalSince1970: c.t).formatted(date: .abbreviated, time: .shortened) + " · \(c.msgs.count) 条").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.foregroundStyle(.primary)
                    } else {
                    NavigationLink {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) { ForEach(c.msgs) { DSBubble(msg: $0) } }.padding()
                        }
                        .navigationTitle(c.title)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).lineLimit(1).fontWeight(k == scope ? .bold : .regular)
                            Text(Date(timeIntervalSince1970: c.t).formatted(date: .abbreviated, time: .shortened) + " · \(c.msgs.count) 条")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                    }
                }
                .onDelete { idx in for i in idx { store.chats[chats[i].key] = nil } }
            }
        }
        .navigationTitle(selecting ? "已选 \(picked.count)" : "历史")
        .onAppear { store.prune() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selecting {
                    Button(picked.count == chats.count && !chats.isEmpty ? "全不选" : "全选") {
                        picked = picked.count == chats.count ? [] : Set(chats.map(\.key))
                    }
                    Button("删除", role: .destructive) { confirmDel = true }.disabled(picked.isEmpty)
                }
                Button(selecting ? "完成" : "选择") { selecting.toggle(); picked = [] }.disabled(chats.isEmpty && !selecting)
            }
        }
        .confirmationDialog("删除 \(picked.count) 个对话？", isPresented: $confirmDel, titleVisibility: .visible) {
            Button("删除", role: .destructive) { for k in picked { store.chats[k] = nil }; picked = []; selecting = false }
        }
    }
}

// MARK: - Scratch snapshots kept at 完成 (local only, never synced)

enum DSSnap {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ds-snap", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func url(_ chapter: String) -> URL {
        dir.appendingPathComponent(chapter.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression) + ".jpg")
    }
    /// Saves a downscaled copy of the set's scratch sheet if the chapter has questions marked ✗.
    static func capture(sheet: String, chapter: String) {
        guard DSStudy.questions(chapter).contains(where: { $0.ok == false }),
              let img = DSContext.scratchImage(sheet) else { return }
        let k = min(1, 1100 / max(img.size.width, img.size.height, 1))
        let sz = CGSize(width: img.size.width * k, height: img.size.height * k)
        let small = UIGraphicsImageRenderer(size: sz).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: sz)); img.draw(in: CGRect(origin: .zero, size: sz))
        }
        try? small.jpegData(compressionQuality: 0.6)?.write(to: url(chapter), options: .atomic)
    }
    static func image(_ chapter: String) -> UIImage? { UIImage(contentsOfFile: url(chapter).path) }
}

// MARK: - Offer analysis after 完成 / 交卷 (never calls the API by itself)

struct DSChapterID: Identifiable { let id: String }

struct DSAnalysisSheet: View {
    let chapterID: String
    var close: () -> Void
    var body: some View {
        NavigationStack {
            List { DSMasterySection(chapterID: chapterID, autoRun: true) }
                .listStyle(.insetGrouped)
                .appList()
                .navigationTitle(DSStudy.chapterTitle(chapterID))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { close() } } }
        }
    }
}

struct DSOffer: ViewModifier {
    @Binding var chapter: String?
    @State private var sheet: DSChapterID?
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let c = chapter {
                    HStack(spacing: 10) {
                        Button { sheet = DSChapterID(id: c); chapter = nil } label: {
                            Label("用 DeepSeek 分析本章掌握程度", systemImage: "sparkles").font(.subheadline.bold())
                        }
                        Button { withAnimation { chapter = nil } } label: { Image(systemName: "xmark").font(.caption.bold()) }
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 80)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .sheet(item: $sheet) { x in DSAnalysisSheet(chapterID: x.id) { sheet = nil } }
    }
}

extension View {
    func dsAnalysisOffer(_ chapter: Binding<String?>) -> some View { modifier(DSOffer(chapter: chapter)) }
}

/// Rows on result screens: one button per chapter in the run.
struct DSAnalyseChapters: View {
    let chapters: [String]
    @State private var sheet: DSChapterID?
    var body: some View {
        if !chapters.isEmpty {
            Section {
                ForEach(chapters, id: \.self) { c in
                    Button { sheet = DSChapterID(id: c) } label: {
                        Label(DSStudy.chapterTitle(c), systemImage: "sparkles")
                    }
                }
            } header: { Text("用 DeepSeek 分析掌握程度") } footer: { Text("点了才会发送。") }
            .listRowBackground(Color.cardBackground)
            .sheet(item: $sheet) { x in DSAnalysisSheet(chapterID: x.id) { sheet = nil } }
        }
    }
}

// MARK: - Contexts for result / past-paper screens

extension DSContext {
    /// ICT quiz after 交卷: every question with the student's answer and the key (all revealed).
    static func ictResult(_ s: Session, _ lib: Library) -> DSContext {
        let L = ["A", "B", "C", "D", "E", "F"]
        var page = "", rev = ""
        for (i, k) in s.keys.enumerated() {
            guard let it = lib.items[k] else { continue }
            page += "\nQ\(i + 1). " + DSStudy.cut(plain(it.q), 500)
            if !it.o.isEmpty { page += "\n" + it.o.enumerated().map { "\(L[min($0.offset, 5)]). " + DSStudy.cut(plain($0.element), 160) }.joined(separator: "\n") }
            switch it.type {
            case .mc:
                let a = s.mc[i].map { L[min($0, 5)] } ?? "未作答"
                rev += "\nQ\(i + 1)：学生 \(a)，答案 \(it.a >= 0 ? L[min(it.a, 5)] : "?")" + (it.e.isEmpty ? "" : "。" + DSStudy.cut(plain(it.ez.isEmpty ? it.e : it.ez), 300))
            case .sq, .lq:
                for (j, p) in it.parts.enumerated() {
                    page += "\n(\(p.l ?? "\(j + 1)")) " + DSStudy.cut(plain(p.q ?? ""), 300)
                    rev += "\nQ\(i + 1)(\(p.l ?? "\(j + 1)"))：学生答「\(s.text[i]?[j] ?? "")」；评分要点：" + DSStudy.cut(plain(p.ms ?? ""), 400)
                }
            default: break
            }
            if page.count > 14000 { page += "\n…"; break }
        }
        return DSContext(key: "ict-result-" + s.title, subject: "ict", title: s.title + " · 结果", page: page, revealed: rev)
    }

    static func dseYear(_ y: PaperYear, _ st: SheetState) -> DSContext {
        var page = "HKDSE ICT \(y.label) Paper 1。卷一 A 共 \(y.key.count) 题选择题。"
        var rev: String?
        if st.done {
            let wrong = y.key.enumerated().filter { i, k in k != "*" && st.a[i + 1] != k }
            rev = "学生得分 \(st.score)/\(y.key.count)。错的题：" + wrong.map { i, k in "Q\(i + 1) 选 \(st.a[i + 1] ?? "-")，答案 \(k)" + (i < y.pct.count ? "（全港答对率 \(y.pct[i])）" : "") }.joined(separator: "；")
        } else {
            page += "学生还没提交答题纸。"
        }
        return DSContext(key: "dse-y-" + y.y, subject: "ict", title: y.label + " ICT Paper 1", page: page, revealed: rev)
    }

    /// Past-paper PDF: text and a picture of the page being viewed.
    static func pdfPage(_ doc: PDFDocument, _ i: Int, title: String, url: URL, subject: String = "ict", answer: String? = nil) -> DSContext {
        let idx = min(max(0, i), max(0, doc.pageCount - 1))
        let p = doc.page(at: idx)
        let text = DSStudy.cut(p?.string ?? "", 6000)
        let img = p?.thumbnail(of: CGSize(width: 1400, height: 1800), for: .mediaBox)
        let isMS = title.localizedCaseInsensitiveContains("marking")
        var c = DSContext(key: "pdf-" + url.lastPathComponent + "-\(idx)", subject: subject, title: "\(title) · 第 \(idx + 1) 页",
                         page: text.isEmpty ? "（这一页没有文字层，见附图）" : text, images: [img].compactMap { $0 },
                         revealed: isMS ? "（这一页本身就是评分标准）" : nil, answer: isMS ? nil : answer)
        c.doc = "pdf-" + url.lastPathComponent
        return c
    }
}
