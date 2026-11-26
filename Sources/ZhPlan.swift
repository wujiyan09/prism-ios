import SwiftUI

// Revision plans for Chinese 範文 (content lives in MathLibrary with subject "zh").

extension Planner {
    static func zhChapters(_ e: Exam) -> [MChapter] {
        MathLibrary.shared.chapters(e.subject == "math" ? "math" : "zh").filter { e.chapters.contains($0.id) }
    }

    static func zhMastery(_ c: MChapter, _ prog: ProgressStore) -> Int {
        let s = prog.stat(c.sets.flatMap { $0.qids }.map { MathMC.key($0) })
        let n = c.nCards
        let read = n == 0 ? 0 : Double((0..<n).filter { prog.seen.contains("\(c.id)-\($0)") }.count) / Double(n)
        if s.done == 0 && read == 0 { return 1 }
        let acc = s.done == 0 ? 0 : Double(s.correct) / Double(s.done)
        let cover = s.total == 0 ? 0 : Double(s.done) / Double(s.total)
        return min(5, max(1, 1 + Int((acc * 2 + min(1, cover * 2) + read).rounded())))
    }

    static func zhPool(_ e: Exam) -> (main: [PlanTask], final: [PlanTask]) {
        var queues: [(w: Double, tasks: [PlanTask])] = []
        for c in zhChapters(e) {
            let m = DSPlan.mastery(e, c.id)
            let weak = 6 - m
            let qn = c.sets.reduce(0) { $0 + $1.n }
            var t: [PlanTask] = []
            let cardSessions = m >= 4 ? 1 : max(1, Int((Double(c.nCards) / 15).rounded(.up)))
            for i in 0..<cardSessions { t.append(PlanTask(id: "cards-\(c.id)-\(i)", kind: .cards, chapterID: c.id, topic: nil, minutes: 20)) }
            if qn > 0 {
                let n = min(max(1, weak + 1), max(1, qn / 10))
                for i in 0..<n { t.append(PlanTask(id: "practice-\(c.id)-\(i)", kind: .practice, chapterID: c.id, topic: nil, minutes: 15)) }
            }
            queues.append((Double(weak) * max(0.5, Double(c.nCards + qn) / 80), t))
        }
        queues.sort { $0.w > $1.w }
        var main: [PlanTask] = []
        var idx = Array(repeating: 0, count: queues.count)
        var left = true
        while left {
            left = false
            for q in queues.indices where idx[q] < queues[q].tasks.count {
                main.append(queues[q].tasks[idx[q]]); idx[q] += 1; left = true
            }
        }
        let n = days(until: e.date)
        let finalDays = n >= 6 ? 2 : (n >= 2 ? 1 : 0)
        let final = (0..<finalDays).flatMap { d in
            [PlanTask(id: "mock-\(d)", kind: .mock, chapterID: nil, topic: nil, minutes: 25),
             PlanTask(id: "redo-\(d)", kind: .redo, chapterID: nil, topic: nil, minutes: 10)]
        }
        return (main, final)
    }

    static func zhTitle(_ t: PlanTask) -> String {
        let c = t.chapterID.flatMap { MathLibrary.shared.chapter($0) }
        let ch = c.map { $0.isZh ? $0.t : $0.label } ?? ""
        switch t.kind {
        case .cards: return "读知识卡 · " + ch
        case .practice: return "练 10 道选择题 · " + ch
        case .mock: return "综合测验：20 题"
        case .redo: return "重做错题"
        default: return ch
        }
    }

    @MainActor
    static func zhStart(_ task: PlanTask, _ exam: Exam, _ scene: SceneModel, _ store: ExamStore, _ prog: ProgressStore) {
        let c = task.chapterID.flatMap { MathLibrary.shared.chapter($0) }
        switch task.kind {
        case .cards:
            if let c {
                let first = (0..<c.nCards).first { !prog.seen.contains("\(c.id)-\($0)") } ?? 0
                store.tick(exam.id, task.id)
                scene.open(.learn, .mathCards(c.id, first))
            }
        case .practice:
            if let c {
                store.tick(exam.id, task.id)
                scene.open(.quiz, .mathQuiz(.custom([c.id], 10, true)))
            }
        case .mock, .redo:
            let ids = zhChapters(exam).map(\.id)
            guard !ids.isEmpty else { return }
            store.tick(exam.id, task.id)
            scene.open(.quiz, .mathQuiz(.custom(ids, task.kind == .mock ? 20 : 15, true)))
        default: break
        }
    }
}

/// Editor sections for a Chinese plan: pick 範文, then rate each.
struct ZhExamSections: View {
    @Binding var exam: Exam
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    private let lib = MathLibrary.shared

    private func toggle(_ c: MChapter) -> some View {
        Toggle(isOn: Binding(get: { exam.chapters.contains(c.id) }, set: { on in
            exam.chapters.removeAll { $0 == c.id }
            if on { exam.chapters.append(c.id); if exam.mastery[c.id] == nil { exam.mastery[c.id] = Planner.zhMastery(c, prog) } }
        })) { Text(c.isZh ? c.t : c.label) }
    }

    var body: some View {
        let subj = exam.subject == "math" ? "math" : "zh"
        let books = lib.books(subj)
        Section {
            if books.isEmpty {
                Text(subj == "zh" ? "範文內容下載中，請稍後再試。" : "数学内容加载中，请稍后再试。").foregroundStyle(.secondary)
            }
            ForEach(books) { b in
                if subj == "zh" {
                    ForEach(b.chs) { c in toggle(c) }
                } else {
                    DisclosureGroup {
                        ForEach(b.chs) { c in toggle(c) }
                    } label: {
                        let n = b.chs.filter { exam.chapters.contains($0.id) }.count
                        HStack {
                            Text(T(b.name, b.nameZh))
                            Spacer()
                            if n > 0 { Text("\(n)/\(b.chs.count)").font(.callout.monospacedDigit()).foregroundStyle(Color.accentColor) }
                        }
                    }
                }
            }
        } header: {
            Text(subj == "zh" ? T("2 · Set texts", "2 · 选范文") : T("2 · Books and chapters", "2 · 选课本和章节"))
        }
        .listRowBackground(Color.cardBackground)

        let chs = Planner.zhChapters(exam)
        if !chs.isEmpty {
            Section {
                ForEach(chs) { c in
                    Picker(selection: Binding(get: { exam.mastery[c.id] ?? Planner.zhMastery(c, prog) }, set: { exam.mastery[c.id] = $0 })) {
                        ForEach(1...5, id: \.self) { v in Text(label(v)).tag(v) }
                    } label: { Text(c.isZh ? c.t : c.label) }
                }
                Button(T("Fill from my progress", "按我的进度填写")) {
                    for c in chs { exam.mastery[c.id] = Planner.zhMastery(c, prog) }
                }
            } header: {
                Text(T("How well do you know each text?", "每篇掌握程度"))
            } footer: {
                Text(T("Weaker texts get more time.", "越弱的范文分到越多时间。"))
            }
            .listRowBackground(Color.cardBackground)
        }
    }

    private func label(_ v: Int) -> String {
        switch v {
        case 1: return T("1 · New to me", "1 · 没学过")
        case 2: return T("2 · Shaky", "2 · 不熟")
        case 3: return T("3 · OK", "3 · 一般")
        case 4: return T("4 · Good", "4 · 熟练")
        default: return T("5 · Solid", "5 · 很稳")
        }
    }
}
