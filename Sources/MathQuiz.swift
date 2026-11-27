import SwiftUI
import Observation

// MARK: - Online MC work sets (bundled: Resources/math/mc.json, mcfig/*.png)

struct MCChoice: Codable, Hashable { let t: String; let e: String }
struct MCVariant: Codable, Hashable {
    let st: String
    let c: [MCChoice]
    let a: Int
    let so: [String]
    let fig: String?
    /// true = explanation was derived (not official / teacher's).
    var sod: Bool? = nil
}
struct MCQ: Codable, Hashable, Identifiable {
    let id: String
    let lvl: String?
    let fo: String?
    let v: [MCVariant]
    var tg: [String]? = nil
    var asg: String? = nil
}
struct MCSet: Codable, Hashable, Identifiable {
    let id: String
    let ch: String
    let kind: String
    let l: String
    let t: String
    let `in`: String?
    let qs: [MCQ]
}
private struct MCFile: Codable { let v: Int; let sets: [MCSet] }

@Observable
final class MathMC {
    static let shared = MathMC()
    var byChapter: [String: [MCSet]] = [:]
    var sets: [MCSet] { byChapter.values.flatMap { $0 } }
    func reload() { for k in byChapter.keys { reloadChapter(k) } }
    func reloadChapter(_ id: String) {
        if let u = MathContent.shared.local("mc/\(id).json"), let d = try? Data(contentsOf: u), let f = try? JSONDecoder().decode(MCFile.self, from: d) {
            byChapter[id] = f.sets
        }
    }
    func unloadChapter(_ id: String) { byChapter[id] = nil }
    /// Set summaries from the chapter list (available before download).
    static var allInfo: [(String, MSetInfo)] { MathLibrary.shared.chapters.flatMap { c in c.sets.map { (c.id, $0) } } }
    static var totalQuestions: Int { allInfo.reduce(0) { $0 + $1.1.n } }
    func sets(_ chapter: String) -> [MCSet] { byChapter[chapter] ?? [] }
    /// Chapter a question belongs to (for DeepSeek 本章 context in mixed sets).
    func chapter(of qid: String) -> String? {
        byChapter.first { $0.value.contains { $0.qs.contains { $0.id == qid } } }?.key
    }
    /// "SETID|filter" = the set limited to a tag (@, #) or assignment (asg) — Chem Award Scheme chips.
    func set(_ id: String) -> MCSet? {
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        guard let s = sets.first(where: { $0.id == parts[0] }) else { return nil }
        guard parts.count == 2 else { return s }
        let f = parts[1]
        let qs = s.qs.filter { ($0.tg ?? []).contains(f) || $0.asg == f }
        return MCSet(id: id, ch: s.ch, kind: s.kind, l: s.l, t: ChemKind.chip(f), in: s.in, qs: qs)
    }
    static func key(_ q: MCQ) -> String { "math:" + q.id }
    static func key(_ id: String) -> String { "math:" + id }
}

/// What to practise: one set, or a custom range of chapters.
enum MathQuizSpec: Hashable, Codable {
    case set(String)
    case custom([String], Int, Bool)   // chapters, count, challenge sets included
}

// MARK: - Quiz home: book → chapter → sets, plus custom range

struct MathQuizHome: View {
    var subj = "math"
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    @AppStorage("math.quiz.chapters") private var picked = ""
    @AppStorage("math.quiz.n") private var n = 15
    @AppStorage("math.quiz.challenge") private var challenge = true
    @AppStorage("math.quiz.wrongOnly") private var wrongOnly = false
    private let lib = MathLibrary.shared
    private let mc = MathMC.shared

    private var pickedSet: Set<String> { Set(picked.split(separator: ",").map(String.init)) }

    var body: some View {
        List {
            MathContentBanner()
            RecentSection(section: .quiz, subject: subj)
            if subj == "chem" { AwardSchemeSection() }
            ForEach(lib.books(subj)) { b in
                Section(T(b.name, b.nameZh)) {
                    ForEach(b.chs.filter { !$0.sets.isEmpty }) { c in
                        NavigationLink(value: Route.mathSets(c.id)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.label)
                                let qs = c.sets.flatMap { $0.qids }.map { MathMC.key($0) }
                                let s = prog.stat(qs)
                                Text(T("\(c.sets.count) sets · \(qs.count) MC · \(s.done) done", "\(c.sets.count) 套 · \(qs.count) 题 · 已做 \(s.done)"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if s.done > 0 { ProgressView(value: Double(s.done), total: Double(max(qs.count, 1))) }
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                }
            }
            if subj == "zh" {
                ZhCustomSection()
            } else {
            Section {
                ForEach(lib.chapters(subj).filter { !$0.sets.isEmpty }) { c in
                    Button { toggle(c.id) } label: {
                        HStack {
                            Image(systemName: pickedSet.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(pickedSet.contains(c.id) ? Color.accentColor : .secondary)
                            Text(c.isZh ? "\(c.book) · \(c.t)" : "\(c.book) · Ch\(c.n) \(c.t)").foregroundStyle(.primary)
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
                Stepper(T("\(n) questions", "\(n) 题"), value: $n, in: 5...60, step: 5).listRowBackground(Color.cardBackground)
                Toggle(T("Include challenge sets", "包括挑战题"), isOn: $challenge).listRowBackground(Color.cardBackground)
                Toggle(T("Only marked wrong", "只看标错的"), isOn: $wrongOnly).listRowBackground(Color.cardBackground)
                NavigationLink(value: Route.mathQuiz(.custom(pickedHere, n, challenge))) {
                    Label(T("Start", "开始"), systemImage: "play.fill").bold()
                }
                .disabled(pickedHere.isEmpty)
                .listRowBackground(Color.cardBackground)
            } header: {
                Text(T("Custom range", "自选范围"))
            } footer: {
                Text(T("Questions you haven't done come first, then ones you got wrong.", "先出没做过的题，再出做错的题。"))
            }
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(MathLibrary.title(subj, T))
    }

    private var pickedHere: [String] { let ids = Set(lib.chapters(subj).map(\.id)); return pickedSet.filter { ids.contains($0) }.sorted() }

    private func toggle(_ id: String) {
        var s = pickedSet
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        picked = s.sorted().joined(separator: ",")
    }
}

struct MathSetsView: View {
    let chapterID: String
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    var body: some View {
        let c = MathLibrary.shared.chapter(chapterID)
        List {
            ForEach(ChemKind.groups(c?.sets ?? [], chem: c?.isChem ?? false, kind: \.kind), id: \.0) { g in
            Section {
            ForEach(g.1) { s in
                NavigationLink(value: Route.mathQuiz(.set(s.id))) {
                    HStack(spacing: 12) {
                        Image(systemName: s.kind == "challenge" ? "flame" : "list.number")
                            .foregroundStyle(s.kind == "challenge" ? Color.orange : Color.accentColor).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.l == "Challenge" ? T("Challenge", "挑战") : s.l.replacingOccurrences(of: "Work", with: T("Work", "Work"))).font(.headline)
                            Text(s.t).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let st = prog.stat(s.qids.map { MathMC.key($0) })
                        if st.done > 0 { Text("\(st.correct)/\(st.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        else { Text("\(s.n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                }
                .listRowBackground(Color.cardBackground)
                if s.kind == "award", let full = MathMC.shared.set(s.id) {
                    let fs = ChemKind.filters(full.qs.map { ($0.tg, $0.asg) })
                    if !fs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(fs, id: \.self) { f in
                                    NavigationLink(value: Route.mathQuiz(.set(s.id + "|" + f))) { Text(ChemKind.chip(f)).font(.caption.bold()) }
                                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                                }
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                }
            }
            } header: { if !g.0.isEmpty { Text(g.0) } }
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(c.map { "Ch\($0.n) \($0.t)" } ?? "")
        .task { await MathContent.shared.ensure(chapterID) }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Runner (split screen with scratch)

struct MathQuizItem: Identifiable, Hashable {
    let q: MCQ
    let v: MCVariant
    let order: [Int]      // display order of the choices
    var id: String { q.id }
}

struct MathQuizRunner: View {
    let spec: MathQuizSpec
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    @AppStorage("math.split.on") private var splitOn = true
    @State private var items: [MathQuizItem] = []
    @State private var index = 0
    @State private var picked: [String: Int] = [:]
    @State private var started = Date().timeIntervalSince1970
    @State private var attempt = UUID().uuidString
    @State private var resumed = false

    private struct Snap: Codable { var ids: [String]; var variants: [Int]; var orders: [[Int]]; var index: Int; var picked: [String: Int] }
    private var resumeKey: String { "mq:" + String(describing: spec) }
    private var subjectID: String { isZh ? "zh" : (title.isEmpty ? "math" : (MathMC.shared.chapter(of: items.first?.q.id ?? "").map { $0.hasPrefix("c-") ? "chem" : "math" } ?? "math")) }
    private func persist() {
        guard !items.isEmpty else { return }
        let st = ResumeStore.shared
        if index >= items.count {
            st.clear(resumeKey); st.update(resumeKey, answered: picked.count, total: items.count, status: 1); return
        }
        st.save(resumeKey, Snap(ids: items.map(\.q.id), variants: items.map { it in it.q.v.firstIndex(of: it.v) ?? 0 },
                                orders: items.map(\.order), index: index, picked: picked))
        st.update(resumeKey, answered: picked.count, total: items.count, status: 0)
    }
    private func restore() -> Bool {
        guard let s = ResumeStore.shared.snapshot(resumeKey, as: Snap.self) else { return false }
        let byID = Dictionary(MathMC.shared.sets.flatMap { $0.qs }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [MathQuizItem] = []
        for (i, id) in s.ids.enumerated() {
            guard let q = byID[id], !q.v.isEmpty else { return false }
            let v = q.v[min(max(0, s.variants[i]), q.v.count - 1)]
            out.append(MathQuizItem(q: q, v: v, order: s.orders[i].count == v.c.count ? s.orders[i] : Array(v.c.indices)))
        }
        items = out; picked = s.picked; index = min(s.index, out.count - 1)
        return !out.isEmpty
    }

    /// Chinese 範文 quizzes have no scratch paper.
    private var isZh: Bool {
        switch spec {
        case .set(let id): return id.hasPrefix("Z-")
        case .custom(let chs, _, _): return !chs.isEmpty && chs.allSatisfy { $0.hasPrefix("z-") }
        }
    }
    private var split: Bool { splitOn && !isZh }
    /// zh / chem / math, from the chapter (labels used to say 数学测验 for every subject).
    private var quizSubject: String {
        switch spec {
        case .set(let id):
            if let cid = MathMC.allInfo.first(where: { $0.1.id == id.components(separatedBy: "|")[0] })?.0, let c = MathLibrary.shared.chapter(cid) { return c.subjectID }
            return id.hasPrefix("Z-") ? "zh" : "math"
        case .custom(let chs, _, _):
            return chs.first.flatMap { MathLibrary.shared.chapter($0)?.subjectID } ?? "math"
        }
    }

    private var title: String {
        switch spec {
        case .set(let id):
            guard let (cid, s) = MathMC.allInfo.first(where: { $0.1.id == id.components(separatedBy: "|")[0] }), let c = MathLibrary.shared.chapter(cid) else { return "" }
            return (c.isZh ? c.t : "Ch\(c.n)") + " · " + (s.l == "Challenge" ? T("Challenge", "挑战") : s.l)
        case .custom: return T("Custom quiz", "自选测验")
        }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ProgressView()
            } else if index >= items.count {
                summary
            } else {
                let it = items[index]
                WorkSplit(on: split, sheetID: "quiz-\(spec)", figs: split ? figImages(it) : []) {
                    question(it).id(it.id)
                        .padMC("mq-" + it.id, count: it.order.count, selected: picked[it.id].flatMap { ci in it.order.firstIndex(of: ci) }, pick: { pos in
                            if it.order.indices.contains(pos) { choose(it, it.order[pos]) }
                        })
                } bar: {
                    PageCluster(index: index, count: items.count,
                                prev: index > 0 ? { index -= 1 } : nil,
                                next: index < items.count - 1 ? { index += 1 } : nil)
                    if index == items.count - 1 {
                        Button { index += 1 } label: { Label(T("Submit", "交卷"), systemImage: "flag.checkered") }
                            .glassButton(prominent: true)
                    }
                }
            }
        }
        .appScreen()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isZh {
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation { splitOn.toggle() } } label: {
                    Image(systemName: splitOn ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                }
                .accessibilityLabel(T("Split", "分屏"))
            }
            }
        }
        .deepSeek(dsContext)
        .task {
            if items.isEmpty {
                await prepare()
                if restore() { withAnimation { resumed = true } } else { build() }
                ResumeStore.shared.touch(Activity(id: resumeKey, title: title, subject: subjectID, target: .mathQuiz(spec),
                                                  answered: picked.count, total: items.count, status: 0))
            }
        }
        .onChange(of: index) { _, _ in persist() }
        .onChange(of: picked) { _, _ in persist() }
        .safeAreaInset(edge: .top, spacing: 0) {
            ResumedBanner(restart: { picked = [:]; index = 0; build(); persist() }, shown: $resumed)
        }
        .workingSession("quiz-\(spec)")
        .noteRecent(.mathQuiz(spec), title, MathLibrary.title(quizSubject, T) + T(" quiz", "测验"))
        .padSubmit(!items.isEmpty && index < items.count) { index = items.count }
    }

    private var dsContext: DSContext? {
        guard index < items.count else { return nil }
        let it = items[index]
        let L = ["A", "B", "C", "D", "E", "F"]
        let opts = it.order.enumerated().map { "\(L[min($0.offset, 5)]). " + it.v.c[$0.element].t }.joined(separator: "\n")
        var rev: String?
        if let ch = picked[it.id], let pos = it.order.firstIndex(of: it.v.a), let mine = it.order.firstIndex(of: ch) {
            rev = "正确答案：\(L[min(pos, 5)])；学生选了 \(L[min(mine, 5)])。\n" + it.v.so.joined(separator: "\n")
        }
        var ans: String?
        if rev == nil, let pos = it.order.firstIndex(of: it.v.a) { ans = "正确答案：\(L[min(pos, 5)])\n" + it.v.so.joined(separator: "\n") }
        let ch = MathMC.shared.chapter(of: it.q.id).flatMap { MathLibrary.shared.chapter($0) }.map { DSContext.mathChapter($0) }
        return DSContext(key: "m-mc-" + it.id, subject: isZh ? "zh" : (MathMC.shared.chapter(of: it.q.id).map { $0.hasPrefix("c-") ? "chem" : "math" } ?? "math"), title: title + " · Q\(index + 1)",
                         page: it.v.st + "\n\n" + opts, images: figImages(it), revealed: rev, answer: ans, chapter: ch,
                         sheetID: split ? "quiz-\(spec)" : nil)
    }

    private func figImages(_ it: MathQuizItem) -> [UIImage] {
        guard let f = it.v.fig, let u = MathLibrary.resource(f, "mcfig"), let img = UIImage(contentsOfFile: u.path) else { return [] }
        return [img]
    }

    private func prepare() async {
        switch spec {
        case .set(let id):
            if let cid = MathMC.allInfo.first(where: { $0.1.id == id })?.0 { await MathContent.shared.ensure(cid) }
        case .custom(let chs, _, _):
            for c in Set(chs.map { ZhSec.chapter($0) }) { await MathContent.shared.ensure(c) }
        }
    }

    private func build() {
        let mc = MathMC.shared
        var qs: [MCQ] = []
        switch spec {
        case .set(let id):
            qs = mc.set(id)?.qs ?? []
        case .custom(let chs, let n, let ch):
            let wrongOnly = UserDefaults.standard.bool(forKey: "math.quiz.wrongOnly")
            let pool = mc.sets.filter { set in chs.contains { ZhSec.matches($0, set) } && (ch || set.kind != "challenge") }.flatMap { $0.qs }
                .filter { !wrongOnly || prog.mark(MathMC.key($0)) == false }
            let byKey = Dictionary(pool.map { (MathMC.key($0), $0) }, uniquingKeysWith: { a, _ in a })
            qs = prog.prioritised(Array(byKey.keys)).prefix(n).compactMap { byKey[$0] }
        }
        items = qs.map { q in
            let v = q.v.randomElement() ?? q.v[0]
            return MathQuizItem(q: q, v: v, order: Array(v.c.indices).shuffled())
        }
    }

    private func choose(_ it: MathQuizItem, _ ci: Int) {
        guard picked[it.id] == nil else { return }
        let isAns = ci == it.v.a
        picked[it.id] = ci
        prog.record(MathMC.key(it.q), ok: isAns)
        prog.marks[MathMC.key(it.q)] = isAns
        // Instant feedback: move on after 1 s, only when right (wrong stays so the explanation can be read).
        if isAns, UserDefaults.standard.bool(forKey: "autoNext"), index < items.count - 1 {
            let here = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { if index == here { withAnimation(.snappy) { index += 1 } } }
        }
    }

    private func question(_ it: MathQuizItem) -> some View {
        let chosen = picked[it.id]
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    if let f = it.q.fo, !f.isEmpty { Text(f).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if let a = it.q.asg, !a.isEmpty { Text(a).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3).background(Color.orange.opacity(0.18), in: Capsule()) }
                    if let l = it.q.lvl, !l.isEmpty { Text("Level \(l)").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3).background(Color.secondary.opacity(0.15), in: Capsule()) }
                }
                MathText(text: it.v.st, size: 18)
                if let img = figImages(it).first { FigureInline(img: img, maxWidth: 520) }
                ForEach(Array(it.order.enumerated()), id: \.offset) { pos, ci in
                    let c = it.v.c[ci]
                    let isAns = ci == it.v.a
                    Button {
                        choose(it, ci)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                MCLetter(l: ["A", "B", "C", "D", "E", "F"][min(pos, 5)],
                                         color: chosen == nil ? Color.accentColor : (isAns ? Color.good : (chosen == ci ? Color.bad : .secondary)))
                                MathText(text: c.t, size: 17)
                                if chosen != nil && (isAns || chosen == ci) {
                                    Image(systemName: isAns ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(isAns ? Color.good : Color.bad)
                                }
                            }
                            if chosen != nil && !c.e.isEmpty {
                                MathText(text: c.e, size: 14, color: .secondary).padding(.leading, 26)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mcGlass(chosen == nil ? .idle : (isAns ? .correct : (chosen == ci ? .wrong : .idle)))
                    }
                    .buttonStyle(.plain)
                }
                if chosen != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(T("Solution", "解答"), systemImage: "text.book.closed").font(.headline)
                        if it.v.sod == true {
                            Text("推导解析").font(.caption.bold()).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 3).background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        MathText(text: it.v.so.joined(separator: "\n\n"), size: 16)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    MarkControl(key: MathMC.key(it.q))
                }
            }
            .padding()
        }
        .softEdges()
    }

    private var summary: some View {
        let got = items.filter { picked[$0.id] == $0.v.a }.count
        return VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(Color.accentColor)
            Text("\(got) / \(items.count)").font(.largeTitle.bold().monospacedDigit())
            Text(T("\(picked.count) answered", "已答 \(picked.count) 题")).foregroundStyle(.secondary)
            if case .set(let sid) = spec, let st = MathMC.shared.set(sid), st.kind != "pastpaper", st.kind != "award", !st.ch.hasPrefix("c-") { PortalStatusView(attempt: attempt).font(.subheadline) }
            HStack {
                Button(T("Review", "回看")) { index = 0 }.glassButton()
                Button(T("New round", "再来一轮")) { picked = [:]; index = 0; attempt = UUID().uuidString; ScratchStore.shared.session("quiz-\(spec)-\(Date().timeIntervalSince1970)"); build() }.glassButton(prominent: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            prog.saveRun(RunRecord(t: started, title: title, got: got, tot: items.count,
                                   qs: items.enumerated().map { i, it in RunQ(l: "\(i + 1). " + String(it.v.st.prefix(60)), ok: picked[it.id].map { $0 == it.v.a }, key: MathMC.key(it.q)) }))
            ScratchStore.shared.clear()
            if case .set(let id) = spec, let set = MathMC.shared.set(id), set.kind != "pastpaper", set.kind != "award", !set.ch.hasPrefix("c-") {
                // One bit per portal question, in the portal's order (any variant).
                let ok = Dictionary(items.map { ($0.q.id, picked[$0.id] == $0.v.a ? 1 : 0) }, uniquingKeysWith: { a, _ in a })
                PortalSubmit.shared.submit(setID: set.id, attempt: attempt, answers: set.qs.map { ok[$0.id] ?? 0 })
            }
        }
    }
}


// MARK: - 测验 › Award Scheme: every Award Scheme MC set and long question, by chapter.

struct AwardSchemeSection: View {
    @Environment(ProgressStore.self) private var prog
    private var chapters: [MChapter] {
        MathLibrary.shared.chapters("chem").filter { c in
            c.sets.contains { $0.kind == "award" } || (ZhLong.load(c.id)?.qs.contains { ChemKind.key($0.src) == "award" } ?? false)
        }
    }
    var body: some View {
        let cs = chapters
        if !cs.isEmpty {
            Section {
                ForEach(cs) { c in
                    NavigationLink(value: Route.awardChapter(c.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.label)
                            let qs = c.sets.filter { $0.kind == "award" }.flatMap(\.qids).map { MathMC.key($0) }
                            let st = prog.stat(qs)
                            Text("\(qs.count) 道选择题 · 已做 \(st.done) · 长题在里面").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            } header: { Text("Award Scheme") } footer: { Text("所有 Award Scheme 卷子的选择题和长题，按章节放在一起；章节页里也还有。") }
        }
    }
}

struct AwardChapterView: View {
    let chapterID: String
    @Environment(ProgressStore.self) private var prog
    @State private var hasLong = false
    var body: some View {
        let c = MathLibrary.shared.chapter(chapterID)
        let sets = (c?.sets ?? []).filter { $0.kind == "award" }
        List {
            MathContentBanner()
            if !sets.isEmpty {
                Section("选择题") {
                    ForEach(sets) { s in
                        NavigationLink(value: Route.mathQuiz(.set(s.id))) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) { Text(s.l).font(.headline); Text(s.t).font(.subheadline).foregroundStyle(.secondary) }
                                Spacer()
                                let st = prog.stat(s.qids.map { MathMC.key($0) })
                                Text(st.done > 0 ? "\(st.correct)/\(st.total)" : "\(s.n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        if let full = MathMC.shared.set(s.id) {
                            let f = ChemKind.filters(full.qs.map { ($0.tg, $0.asg) })
                            if !f.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(f, id: \.self) { x in
                                            NavigationLink(value: Route.mathQuiz(.set(s.id + "|" + x))) { Text(ChemKind.chip(x)).font(.caption.bold()) }
                                                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .listRowBackground(Color.cardBackground)
            }
            if hasLong {
                Section("长题") {
                    NavigationLink(value: Route.longSet(chapterID, "award")) { Label("长题 · Award Scheme", systemImage: "text.alignleft") }
                }
                .listRowBackground(Color.cardBackground)
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(c.map { "Award Scheme · Ch\($0.n)" } ?? "Award Scheme")
        .navigationBarTitleDisplayMode(.inline)
        .task { await MathContent.shared.ensure(chapterID) }
        .task(id: MathContent.shared.loading.count) {
            hasLong = ZhLong.load(chapterID)?.qs.contains { ChemKind.key($0.src) == "award" } ?? false
        }
    }
}
