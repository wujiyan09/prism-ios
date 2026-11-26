import SwiftUI
import Observation

// MARK: - Model

struct Exam: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var subject = "ict"
    var date = Calendar.current.date(byAdding: .day, value: 21, to: Calendar.current.startOfDay(for: Date()))!
    var chapters: [String] = []
    var topics: [String] = []
    var mastery: [String: Int] = [:]   // chapter id → 1…5
    var minutes = 45
    var done: [String: Double] = [:]   // task id → time completed
    var remind = true
    var remindAt = 19 * 60              // minutes after midnight
    var notes = ""
    var source: String? = nil           // "quest" when added remotely by Quest

    enum CodingKeys: String, CodingKey { case id, name, subject, date, chapters, topics, mastery, minutes, done, remind, remindAt, notes, source }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        subject = (try? c.decode(String.self, forKey: .subject)) ?? "ict"
        date = (try? c.decode(Date.self, forKey: .date)) ?? date
        chapters = (try? c.decode([String].self, forKey: .chapters)) ?? []
        topics = (try? c.decode([String].self, forKey: .topics)) ?? []
        mastery = (try? c.decode([String: Int].self, forKey: .mastery)) ?? [:]
        minutes = (try? c.decode(Int.self, forKey: .minutes)) ?? 45
        done = (try? c.decode([String: Double].self, forKey: .done)) ?? [:]
        remind = (try? c.decode(Bool.self, forKey: .remind)) ?? false
        remindAt = (try? c.decode(Int.self, forKey: .remindAt)) ?? 19 * 60
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        source = try? c.decode(String.self, forKey: .source)
    }
}

extension Exam {
    /// Maths and 中文 plans use chapters from MathLibrary.
    var usesMathLib: Bool { subject == "zh" || subject == "math" }
}

enum TaskKind: String, Codable {
    case cards, practice, structured, dse, mock, redo
    var icon: String {
        switch self {
        case .cards: return "rectangle.stack"
        case .practice: return "checklist"
        case .structured: return "square.and.pencil"
        case .dse: return "doc.text"
        case .mock: return "timer"
        case .redo: return "arrow.uturn.backward"
        }
    }
}

struct PlanTask: Identifiable, Hashable {
    let id: String
    let kind: TaskKind
    let chapterID: String?
    let topic: String?
    let minutes: Int
    var day: Date = .distantPast
}

@Observable
final class ExamStore {
    static let shared = ExamStore()
    var exams: [Exam] = [] { didSet { save() } }

    private static var file: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("exams.json")
    }
    init() {
        if let d = try? Data(contentsOf: Self.file), let e = try? JSONDecoder().decode([Exam].self, from: d) { exams = e }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(exams) { try? d.write(to: Self.file, options: .atomic) }
        Reminders.shared.reschedule()
    }
    func tick(_ exam: UUID, _ task: String) {
        guard let i = exams.firstIndex(where: { $0.id == exam }), exams[i].done[task] == nil else { return }
        exams[i].done[task] = Date().timeIntervalSince1970
    }
    func update(_ e: Exam) {
        if let i = exams.firstIndex(where: { $0.id == e.id }) { exams[i] = e } else { exams.append(e) }
        exams.sort { $0.date < $1.date }
    }
}

// MARK: - Planner

enum Planner {
    static func scopeChapters(_ e: Exam, _ lib: Library) -> [Chapter] {
        lib.chapters.filter { c in
            e.chapters.contains(c.id) || e.topics.contains(Topics.bookTopic[c.bookID] ?? c.bookID)
        }
    }

    static func scopeTopics(_ e: Exam, _ lib: Library) -> [String] {
        let t = Set(e.topics + scopeChapters(e, lib).map { Topics.bookTopic[$0.bookID] ?? $0.bookID })
        return Topics.order.filter { t.contains($0) }
    }

    /// Mastery guess from the app's own progress: practice accuracy and cards read.
    static func suggestedMastery(_ c: Chapter, _ prog: ProgressStore) -> Int {
        let s = prog.stat(c.mc)
        let read = c.nCards == 0 ? 0 : Double((0..<c.nCards).filter { prog.seen.contains("\(c.id)-\($0)") }.count) / Double(c.nCards)
        if s.done == 0 && read == 0 { return 1 }
        let acc = s.done == 0 ? 0 : Double(s.correct) / Double(s.done)
        let cover = s.total == 0 ? 0 : Double(s.done) / Double(s.total)
        return min(5, max(1, 1 + Int((acc * 2 + min(1, cover * 2) + read).rounded())))
    }

    static func days(until exam: Date, from: Date = Date()) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: from), to: cal.startOfDay(for: exam)).day ?? 0
    }

    /// All tasks for the exam, in study order, before scheduling.
    static func pool(_ e: Exam, _ lib: Library) -> (main: [PlanTask], final: [PlanTask]) {
        if e.usesMathLib { let z = zhPool(e); return (DSPlan.extras(e) + z.main, z.final) }
        let chs = scopeChapters(e, lib)
        var queues: [(w: Double, tasks: [PlanTask])] = []
        for c in chs {
            let m = DSPlan.mastery(e, c.id)
            let weak = 6 - m                                     // 1…5
            let size = Double(c.nCards + c.nMC) / 40   // bigger chapters weigh more
            var t: [PlanTask] = []
            let cardSessions = m >= 4 ? 1 : max(1, Int((Double(c.nCards) / 12).rounded(.up)))
            for i in 0..<cardSessions { t.append(PlanTask(id: "cards-\(c.id)-\(i)", kind: .cards, chapterID: c.id, topic: nil, minutes: 20)) }
            if !c.mc.isEmpty {
                let n = min(max(1, weak), max(1, c.nMC / 6))
                for i in 0..<n { t.append(PlanTask(id: "practice-\(c.id)-\(i)", kind: .practice, chapterID: c.id, topic: nil, minutes: 15)) }
            }
            if !c.sq.isEmpty && m <= 3 { t.append(PlanTask(id: "structured-\(c.id)-0", kind: .structured, chapterID: c.id, topic: nil, minutes: 20)) }
            if !c.elective, let tp = Topics.bookTopic[c.bookID], lib.dseMC.contains(where: { lib.items[$0]?.topic == tp }) {
                for i in 0..<max(1, weak / 2) { t.append(PlanTask(id: "dse-\(c.id)-\(i)", kind: .dse, chapterID: c.id, topic: tp, minutes: 15)) }
            }
            queues.append((Double(weak) * max(0.5, size), t))
        }
        // Weakest / largest chapters first, interleaved so each day mixes chapters.
        queues.sort { $0.w > $1.w }
        var main: [PlanTask] = []
        var idx = Array(repeating: 0, count: queues.count)
        var left = true
        while left {
            left = false
            for q in queues.indices where idx[q] < queues[q].tasks.count {
                main.append(queues[q].tasks[idx[q]]); idx[q] += 1; left = true
                // Heavier chapters get a second task in the same round.
                if queues[q].w >= 4, idx[q] < queues[q].tasks.count { main.append(queues[q].tasks[idx[q]]); idx[q] += 1 }
            }
        }
        main = DSPlan.extras(e) + main
        let n = days(until: e.date)
        let finalDays = n >= 10 ? 3 : (n >= 4 ? 2 : (n >= 2 ? 1 : 0))
        var final: [PlanTask] = []
        for d in 0..<finalDays {
            final.append(PlanTask(id: "mock-\(d)", kind: .mock, chapterID: nil, topic: nil, minutes: 30))
            final.append(PlanTask(id: "redo-\(d)", kind: .redo, chapterID: nil, topic: nil, minutes: 15))
        }
        return (main, final)
    }

    /// Schedules the remaining tasks from today, so missed days roll forward automatically.
    static func plan(_ e: Exam, _ lib: Library) -> [(day: Date, tasks: [PlanTask])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let total = days(until: e.date)
        guard total > 0 else { return [] }
        let p = pool(e, lib)
        let finalCount = p.final.count / 2
        let studyDays = max(1, total - finalCount)
        let budget = max(15, e.minutes)

        // Tasks already done keep the day they were ticked; the rest are spread from today.
        var doneByDay: [Date: [PlanTask]] = [:]
        var todo = p.main.filter { e.done[$0.id] == nil }
        for t in p.main + p.final {
            if let ts = e.done[t.id] {
                let d = max(today, cal.startOfDay(for: Date(timeIntervalSince1970: ts)))
                if d == today { doneByDay[d, default: []].append(t) }
            }
        }
        // If the budget can't fit everything, drop extra rounds from the strongest chapters.
        let capacity = studyDays * budget - (doneByDay[today]?.reduce(0) { $0 + $1.minutes } ?? 0)
        while todo.reduce(0, { $0 + $1.minutes }) > capacity, todo.count > 1 {
            let strongest = todo.enumerated()
                .filter { $0.element.kind != .cards || ($0.element.id.hasSuffix("-0") == false) }
                .max { (e.mastery[$0.element.chapterID ?? ""] ?? 1, $0.offset) < (e.mastery[$1.element.chapterID ?? ""] ?? 1, $1.offset) }
            guard let s = strongest else { break }
            todo.remove(at: s.offset)
        }

        var out: [(Date, [PlanTask])] = []
        var i = 0
        let perDay = Double(todo.count) / Double(studyDays)
        var carry = 0.0
        for d in 0..<studyDays {
            let day = cal.date(byAdding: .day, value: d, to: today)!
            var list = doneByDay[day] ?? []
            var used = list.reduce(0) { $0 + $1.minutes }
            carry += perDay
            let cap = DSPlan.budget(e, day, budget)
            if cap == 0 && d < studyDays - 1 { out.append((day, list)); continue }
            var take = Int(carry.rounded(.down))
            carry -= Double(take)
            if d == studyDays - 1 { take = todo.count - i }
            while i < todo.count, (take > 0 || d == studyDays - 1) {
                if used + todo[i].minutes > cap && !list.isEmpty && d < studyDays - 1 { break }
                var t = todo[i]; t.day = day; list.append(t); used += t.minutes; i += 1; take -= 1
            }
            out.append((day, list))
        }
        for k in 0..<finalCount {
            let day = cal.date(byAdding: .day, value: studyDays + k, to: today)!
            let items = p.final.filter { $0.id.hasSuffix("-\(k)") }.map { t -> PlanTask in var x = t; x.day = day; return x }
            out.append((day, (doneByDay[day] ?? []) + items))
        }
        return out.filter { !$0.1.isEmpty }
    }

    static func title(_ t: PlanTask, _ lib: Library, _ T: Tr) -> String {
        if let x = DSPlan.title(t) { return x }
        if let id = t.chapterID, lib.chapter(id) == nil, MathLibrary.shared.chapter(id) != nil { return zhTitle(t) }
        let c = t.chapterID.flatMap { lib.chapter($0) }
        let ch = c.map { "\($0.bookID) Ch\($0.n) \($0.t)" } ?? ""
        switch t.kind {
        case .cards: return T("Read cards · ", "读知识卡 · ") + ch
        case .practice: return T("Practice 10 MC · ", "练 10 道选择题 · ") + ch
        case .structured: return T("Structured questions · ", "结构题 · ") + ch
        case .dse: return T("10 real DSE MC · ", "10 道 DSE 真题 · ") + Topics.name(t.topic ?? "")
        case .mock: return T("Mixed mock: 25 questions", "综合模拟：25 题")
        case .redo: return T("Redo wrong questions", "重做错题")
        }
    }
}

// MARK: - Views

struct PlanListView: View {
    @Environment(ExamStore.self) private var store
    @Environment(Library.self) private var lib
    @Environment(\.tr) private var T
    @State private var editing: Exam?

    var body: some View {
        List {
            RecentSection(section: .plan)
            if store.exams.isEmpty {
                ContentUnavailableView {
                    Label(T("No exams yet", "还没有考试"), systemImage: "calendar.badge.plus")
                } description: {
                    Text(T("Add an exam and Prism builds a day-by-day revision plan up to the exam date.", "添加一场考试，Prism 会排出到考试当天的每日复习计划。"))
                } actions: {
                    Button(T("Add exam", "添加考试")) { editing = Exam() }.glassButton(prominent: true)
                }
                .listRowBackground(Color.clear)
            }
            ForEach(store.exams) { e in
                NavigationLink(value: Route.exam(e.id)) {
                    ExamRow(exam: e)
                }
                .listRowBackground(Color.cardBackground)
            }
            .onDelete { store.exams.remove(atOffsets: $0) }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(T("Exam Plan", "备考计划"))
        .refreshable { await SyncManager.shared.sync() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = Exam() } label: { Label(T("Add exam", "添加考试"), systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(item: $editing) { e in
            ExamEditor(exam: e).environment(\.tr, T)
        }
    }
}

struct ExamRow: View {
    let exam: Exam
    @Environment(Library.self) private var lib
    @Environment(\.tr) private var T
    var body: some View {
        let n = Planner.days(until: exam.date)
        let pool = Planner.pool(exam, lib)
        let all = pool.main.count + pool.final.count
        let done = (pool.main + pool.final).filter { exam.done[$0.id] != nil }.count
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(exam.name.isEmpty ? T("Exam", "考试") : exam.name).font(.headline)
                if exam.source == "quest" {
                    Text(T("from Quest", "来自 Quest")).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text(n > 0 ? T("\(n) days left", "还有 \(n) 天") : (n == 0 ? T("Today", "今天") : T("Finished", "已结束")))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(n <= 7 && n >= 0 ? Color.orange : .secondary)
            }
            Text(exam.date.formatted(date: .complete, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(done), total: Double(max(all, 1)))
        }
        .padding(.vertical, 4)
    }
}

struct ExamDetailView: View {
    let id: UUID
    @Environment(ExamStore.self) private var store
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(SceneModel.self) private var scene
    @Environment(\.tr) private var T
    @State private var editing: Exam?
    @State private var showDone = true

    var body: some View {
        if let e = store.exams.first(where: { $0.id == id }) {
            let plan = Planner.plan(e, lib)
            let n = Planner.days(until: e.date)
            let suggested = Planner.scopeChapters(e, lib).filter { Planner.suggestedMastery($0, prog) > (e.mastery[$0.id] ?? 1) }
            List {
                Section {
                    LabeledContent(T("Exam date", "考试日期"), value: e.date.formatted(date: .abbreviated, time: Calendar.current.component(.hour, from: e.date) == 0 && Calendar.current.component(.minute, from: e.date) == 0 ? .omitted : .shortened))
                    if !e.notes.isEmpty { DSMarkdown(text: e.notes) }
                    if e.source == "quest" { Text(T("Added by Quest", "来自 Quest")).font(.caption).foregroundStyle(.secondary) }
                    LabeledContent(T("Days left", "剩余天数"), value: "\(max(0, n))")
                    LabeledContent(T("Daily budget", "每日时间"), value: T("\(e.minutes) min", "\(e.minutes) 分钟"))
                    LabeledContent(T("Chapters", "章节"), value: "\(e.usesMathLib ? Planner.zhChapters(e).count : Planner.scopeChapters(e, lib).count)")
                    LabeledContent(T("Daily reminder", "每日提醒"),
                                   value: e.remind ? String(format: "%02d:%02d", e.remindAt / 60, e.remindAt % 60) : T("Off", "关"))
                    if !suggested.isEmpty {
                        Button {
                            var x = e
                            for c in suggested { x.mastery[c.id] = Planner.suggestedMastery(c, prog) }
                            store.update(x)
                        } label: {
                            Label(T("Your practice shows progress in \(suggested.count) chapters. Update mastery and re-plan", "你在 \(suggested.count) 章有进步，更新掌握度并重排计划"), systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                } footer: {
                    Text(T("The plan re-arranges itself every day: unfinished tasks move forward, and the last days are for mixed mocks and redoing wrong questions.", "计划每天自动重排：没完成的任务会顺延，最后几天留给综合模拟和重做错题。"))
                }
                .listRowBackground(Color.cardBackground)

                DSPlanSection(exam: e)

                if n <= 0 {
                    Text(T("This exam date has passed.", "考试日期已过。")).foregroundStyle(.secondary)
                }
                ForEach(plan, id: \.day) { day, tasks in
                    Section {
                        ForEach(tasks) { t in
                            TaskRow(exam: e, task: t)
                        }
                    } header: {
                        HStack {
                            Text(dayTitle(day))
                            Spacer()
                            Text(T("\(tasks.reduce(0) { $0 + $1.minutes }) min", "\(tasks.reduce(0) { $0 + $1.minutes }) 分钟")).monospacedDigit()
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
            .listStyle(.insetGrouped)
            .appList()
            .navigationTitle(e.name.isEmpty ? T("Exam", "考试") : e.name)
            .noteRecent(.exam(e.id), e.name.isEmpty ? T("Exam", "考试") : e.name,
                        plan.first.map { d in T("Today: ", "今天：") + (d.tasks.first { e.done[$0.id] == nil }.map { Planner.title($0, lib, T) } ?? T("all done", "已完成")) } ?? "")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(T("Edit", "编辑")) { editing = e }
                }
            }
            .sheet(item: $editing) { x in ExamEditor(exam: x).environment(\.tr, T) }
        } else {
            ContentUnavailableView(T("Not found", "找不到"), systemImage: "questionmark")
        }
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return T("Today", "今天") }
        if cal.isDateInTomorrow(d) { return T("Tomorrow", "明天") }
        return d.formatted(.dateTime.weekday(.wide).month().day())
    }
}

struct TaskRow: View {
    let exam: Exam
    let task: PlanTask
    @Environment(ExamStore.self) private var store
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(SceneModel.self) private var scene
    @Environment(\.tr) private var T

    var body: some View {
        let done = exam.done[task.id] != nil
        HStack(spacing: 12) {
            Button {
                var e = exam
                if done { e.done[task.id] = nil } else { e.done[task.id] = Date().timeIntervalSince1970 }
                store.update(e)
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? Color.good : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(done ? T("Mark not done", "标记为未完成") : T("Mark done", "标记为完成"))
            VStack(alignment: .leading, spacing: 2) {
                Text(Planner.title(task, lib, T)).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                Text(T("\(task.minutes) min", "\(task.minutes) 分钟")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { start() } label: {
                Image(systemName: task.kind.icon)
                    .frame(width: 34, height: 30)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
                .buttonStyle(.borderless)
                .accessibilityLabel(T("Start", "开始"))
        }
    }

    private func start() {
        if DSPlan.start(task, exam, scene, store, lib) { return }
        if exam.usesMathLib { Planner.zhStart(task, exam, scene, store, prog); return }
        let pt: (UUID, String) = (exam.id, task.id)
        let c = task.chapterID.flatMap { lib.chapter($0) }
        switch task.kind {
        case .cards:
            if let c {
                let first = (0..<c.nCards).first { !prog.seen.contains("\(c.id)-\($0)") } ?? 0
                scene.cardTask = (exam.id, task.id, c.id)
                scene.open(.learn, .cards(c.id, first))
            }
        case .practice:
            if let c { scene.start(c.name, Array(prog.prioritised(c.mc).prefix(10)), planTask: pt) }
        case .structured:
            if let c { scene.start(c.name + " · " + T("Structured", "结构题"), Array(prog.prioritised(c.sq).prefix(3)), planTask: pt) }
        case .dse:
            let k = lib.dseMC.filter { lib.items[$0]?.topic == task.topic }
            scene.start(Topics.name(task.topic ?? ""), Array(prog.prioritised(k).prefix(10)), planTask: pt)
        case .mock:
            let chs = Planner.scopeChapters(exam, lib)
            let tps = Set(Planner.scopeTopics(exam, lib))
            let orig = prog.prioritised(chs.flatMap { $0.mc }).prefix(12)
            let real = prog.prioritised(lib.dseMC.filter { tps.contains(lib.items[$0]?.topic ?? "") }).prefix(13)
            scene.start(T("Mock", "模拟"), (Array(orig) + Array(real)).shuffled(), planTask: pt)
        case .redo:
            let chs = Set(Planner.scopeChapters(exam, lib).map(\.id))
            let tps = Set(Planner.scopeTopics(exam, lib))
            let wrong = prog.wrongMC(in: lib).filter { k in
                guard let it = lib.items[k] else { return false }
                return chs.contains(it.chapterID ?? "") || tps.contains(it.topic ?? "")
            }
            if wrong.isEmpty { store.tick(exam.id, task.id) }
            scene.start(T("Redo wrong", "重做错题"), Array(wrong.shuffled().prefix(20)), planTask: pt)
        }
    }
}

struct ExamEditor: View {
    @State var exam: Exam
    @Environment(ExamStore.self) private var store
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let chs = Planner.scopeChapters(exam, lib)
        NavigationStack {
            Form {
                Section {
                    Picker(T("Subject", "科目"), selection: $exam.subject) {
                        ForEach(Subject.ordered) { Label(T($0.name, $0.nameZh), systemImage: $0.icon).tag($0.id) }
                    }
                } header: {
                    Text(T("1 · Subject", "1 · 选科目"))
                }
                .listRowBackground(Color.cardBackground)

                Section {
                    TextField(T("Name, e.g. ICT UT3", "名称，例如 ICT UT3"), text: $exam.name)
                    DatePicker(T("Exam date", "考试日期"), selection: $exam.date,
                               in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                    LabeledContent(T("Days left", "剩余天数"), value: "\(max(0, Planner.days(until: exam.date)))")
                    VStack(alignment: .leading) {
                        LabeledContent(T("Daily study time", "每日学习时间"), value: T("\(exam.minutes) min", "\(exam.minutes) 分钟"))
                        Slider(value: Binding(get: { Double(exam.minutes) }, set: { exam.minutes = Int($0) }), in: 15...180, step: 15) {
                            Text(T("Daily study time", "每日学习时间"))
                        } minimumValueLabel: { Text("15") } maximumValueLabel: { Text("180") }
                    }
                }
                .listRowBackground(Color.cardBackground)

                if exam.usesMathLib {
                    ZhExamSections(exam: $exam)
                } else {
                Section {
                    ForEach(lib.books) { bk in
                        NavigationLink {
                            ExamChapterPicker(exam: $exam, bookID: bk.id, onChange: prefill)
                        } label: {
                            let n = bk.chapters.filter { exam.chapters.contains($0.id) }.count
                            HStack(spacing: 12) {
                                Text(bk.id).font(.subheadline.monospaced().bold()).foregroundStyle(.white)
                                    .frame(width: 36, height: 30)
                                    .background((bk.elective ? Color.purple : Color.blue).gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(bk.name)
                                    Text(bk.elective ? T("Elective", "选修") : T("Compulsory", "必修")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(n == 0 ? "" : "\(n)/\(bk.chapters.count)").font(.callout.monospacedDigit()).foregroundStyle(n > 0 ? Color.accentColor : .secondary)
                            }
                        }
                    }
                } header: {
                    Text(T("2 · Textbooks and chapters", "2 · 选课本和章节"))
                } footer: {
                    Text(T("Open a textbook to pick its chapters. Electives A, B and C are included.", "点进课本再选章节，选修 A、B、C 也在这里。"))
                }
                .listRowBackground(Color.cardBackground)
                }

                Section {
                    Toggle(T("Daily reminder", "每日提醒"), isOn: $exam.remind)
                    if exam.remind {
                        DatePicker(T("Time", "时间"), selection: Binding(
                            get: { Calendar.current.date(bySettingHour: exam.remindAt / 60, minute: exam.remindAt % 60, second: 0, of: Date())! },
                            set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); exam.remindAt = (c.hour ?? 19) * 60 + (c.minute ?? 0) }),
                                   displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text(T("Reminders", "提醒"))
                } footer: {
                    Text(T("A system notification every day with that day's tasks, plus one the evening before the exam.", "每天按时发系统通知，告诉你当天的任务；考试前一晚也会提醒。"))
                }
                .listRowBackground(Color.cardBackground)

                if !chs.isEmpty {
                    Section {
                        ForEach(chs) { c in
                            Picker(selection: Binding(get: { exam.mastery[c.id] ?? Planner.suggestedMastery(c, prog) },
                                                      set: { exam.mastery[c.id] = $0 })) {
                                ForEach(1...5, id: \.self) { v in Text(masteryLabel(v)).tag(v) }
                            } label: {
                                Text("\(c.bookID) Ch\(c.n) \(c.t)")
                            }
                        }
                        Button(T("Fill from my progress", "按我的进度填写")) {
                            for c in chs { exam.mastery[c.id] = Planner.suggestedMastery(c, prog) }
                        }
                    } header: {
                        Text(T("How well do you know each chapter?", "每章掌握程度"))
                    } footer: {
                        Text(T("Pre-filled from your practice accuracy and cards read. Weaker chapters get more time.", "根据你的练习正确率和已读知识卡预填。越弱的章节分到越多时间。"))
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
            .appList()
            .onAppear(perform: migrateTopics)
            .navigationTitle(exam.name.isEmpty ? T("New exam", "新考试") : exam.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save", "保存")) {
                        prefill()
                        store.update(exam)
                        if exam.remind { Task { await Reminders.shared.requestPermission() } }
                        dismiss()
                    }
                    .disabled(exam.usesMathLib ? Planner.zhChapters(exam).isEmpty : chs.isEmpty)
                }
            }
        }
    }

    /// Older plans picked whole DSE topics; turn those into explicit chapters so the textbook picker shows them.
    private func migrateTopics() {
        guard !exam.topics.isEmpty else { return }
        for c in Planner.scopeChapters(exam, lib) where !exam.chapters.contains(c.id) { exam.chapters.append(c.id) }
        exam.topics = []
    }

    private func prefill() {
        for c in Planner.scopeChapters(exam, lib) where exam.mastery[c.id] == nil {
            exam.mastery[c.id] = Planner.suggestedMastery(c, prog)
        }
    }

    private func masteryLabel(_ v: Int) -> String {
        switch v {
        case 1: return T("1 · New to me", "1 · 没学过")
        case 2: return T("2 · Shaky", "2 · 不熟")
        case 3: return T("3 · OK", "3 · 一般")
        case 4: return T("4 · Good", "4 · 熟练")
        default: return T("5 · Solid", "5 · 很稳")
        }
    }
}

struct ExamChapterPicker: View {
    @Binding var exam: Exam
    let bookID: String
    var onChange: () -> Void
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    @State private var status: LearnedFilter = .all
    @State private var part: PartFilter = .all
    var body: some View {
        if let b = lib.books.first(where: { $0.id == bookID }) {
            let chs = b.chapters.filter { status.keep(prog.learned.contains($0.id)) }
            List {
                Section {
                    let all = b.chapters.allSatisfy { exam.chapters.contains($0.id) }
                    Button(all ? T("Deselect all", "全不选") : T("Select all \(b.chapters.count) chapters", "全选 \(b.chapters.count) 章")) {
                        for c in b.chapters {
                            exam.chapters.removeAll { $0 == c.id }
                            if !all { exam.chapters.append(c.id) }
                        }
                        onChange()
                    }
                }
                .listRowBackground(Color.cardBackground)
                Section {
                    ForEach(chs) { c in
                        Toggle(isOn: Binding(
                            get: { exam.chapters.contains(c.id) },
                            set: { on in
                                if on { exam.chapters.append(c.id) } else { exam.chapters.removeAll { $0 == c.id } }
                                onChange()
                            })) {
                            HStack {
                                Text("Ch\(c.n) \(c.t)")
                                if prog.learned.contains(c.id) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).imageScale(.small)
                                }
                            }
                        }
                    }
                }
                .listRowBackground(Color.cardBackground)
            }
            .listStyle(.insetGrouped)
            .appList()
            .navigationTitle("\(b.id) · \(b.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .primaryAction) { FilterMenu(part: $part, status: $status, showPart: false) } }
        }
    }
}
