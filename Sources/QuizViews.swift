import SwiftUI

struct QuizBuilderView: View {
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(SceneModel.self) private var scene
    @Environment(\.tr) private var T
    @State private var noType = false

    var body: some View {
        @Bindable var prog = prog
        Form {
            Section {
                VStack(alignment: .leading) {
                    LabeledContent(T("Questions", "题数")) {
                        Text("\(prog.quiz.n)").monospacedDigit()
                    }
                    Slider(value: Binding(get: { Double(prog.quiz.n) }, set: { prog.quiz.n = Int($0) }), in: 5...100, step: 5) {
                        Text(T("Questions", "题数"))
                    } minimumValueLabel: { Text("5") } maximumValueLabel: { Text("100") }
                }
            } footer: {
                Text(T("One question per page, marked at the end.", "一页一题，交卷后统一批改。"))
            }
            .listRowBackground(Color.cardBackground)

            Section(T("Question type", "题型")) {
                typeToggle("mc", "MC")
                typeToggle("sq", T("Structured", "结构题"))
                typeToggle("lq", T("DSE long (1B)", "DSE 长题 (1B)"))
                typeToggle("pr", T("Hands-on", "实操"))
            }
            .listRowBackground(Color.cardBackground)

            Section {
                scopeToggle("comp", T("All compulsory", "全部必修"))
                scopeToggle("elec", T("All electives", "全部选修"))
                ForEach(lib.books.filter(\.elective)) { b in scopeToggle("b:" + b.id, T("Elective · ", "选修 · ") + b.name) }
                ForEach(Topics.order, id: \.self) { t in scopeToggle("t:" + t, Topics.name(t)) }
                NavigationLink(value: Route.chapterPicker) {
                    HStack {
                        Text(T("Choose chapters", "选择章节"))
                        Spacer()
                        let n = prog.quiz.scope.filter { $0.hasPrefix("c:") }.count
                        if n > 0 { Text("\(n)").foregroundStyle(.secondary) }
                    }
                }
            } header: {
                Text(T("Scope", "范围"))
            } footer: {
                Text(T("Nothing selected means everything.", "不选就是全部范围。"))
            }
            .listRowBackground(Color.cardBackground)

            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text(T("Real DSE share", "真题比例"))
                        Spacer()
                        Text("\(Int(prog.quiz.mix))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $prog.quiz.mix, in: 0...100, step: 10) {
                        Text(T("Real DSE share", "真题比例"))
                    }
                }
            }
            .listRowBackground(Color.cardBackground)

            Section {
                Button { build() } label: {
                    Label(T("Generate", "生成测验"), systemImage: "sparkles.rectangle.stack")
                        .frame(maxWidth: .infinity).bold()
                }
                .keyboardShortcut(.return, modifiers: .command)
                let wrong = prog.wrongMC(in: lib)
                if !wrong.isEmpty {
                    Button { scene.start(T("Wrong questions", "错题重做"), Array(wrong.shuffled().prefix(prog.quiz.n))) } label: {
                        Label(T("Redo my wrong MC (\(wrong.count))", "重做我的错题（\(wrong.count)）"), systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .listRowBackground(Color.cardBackground)

            Section {
                ImportLibraryLink()
            } footer: {
                Text("导入任何科目的 PDF、照片或扫描的试卷：直接写在上面，或让 DeepSeek 拆成答题卡。")
            }
            .listRowBackground(Color.cardBackground)

            Section(T("Recent results", "最近成绩")) {
                if prog.runs.isEmpty {
                    Text("—").foregroundStyle(.secondary)
                }
                ForEach(prog.runs.prefix(10)) { r in
                    NavigationLink { RunDetailView(run: r) } label: { HStack {
                        Text(r.title).lineLimit(2)
                        Spacer()
                        Text("\(r.got)/\(r.tot) · \(Date(timeIntervalSince1970: r.t).formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } }
                }
            }
            .listRowBackground(Color.cardBackground)
        }
        .appList()
        .navigationTitle(T(Library.subject.name + " Quiz", Library.subject.name + " 测验"))
        .alert(T("Pick a question type", "请选题型"), isPresented: $noType) {}
        .sectionToolbar()
    }

    private func typeToggle(_ v: String, _ label: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { prog.quiz.types.contains(v) },
            set: { on in
                if on { if !prog.quiz.types.contains(v) { prog.quiz.types.append(v) } } else { prog.quiz.types.removeAll { $0 == v } }
            }))
    }

    private func scopeToggle(_ v: String, _ label: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { prog.quiz.scope.contains(v) },
            set: { on in
                if on { if !prog.quiz.scope.contains(v) { prog.quiz.scope.append(v) } } else { prog.quiz.scope.removeAll { $0 == v } }
            }))
    }

    private func build() {
        let q = prog.quiz
        let type = Set(q.types), scope = q.scope
        guard !type.isEmpty else { noType = true; return }
        let n = max(1, q.n)
        let chs = lib.chapters.filter { c in
            let t = Topics.bookTopic[c.bookID] ?? c.bookID
            return scope.isEmpty || scope.contains("c:" + c.id) || (scope.contains("comp") && !c.elective)
                || (scope.contains("elec") && c.elective) || scope.contains("t:" + t) || scope.contains("b:" + c.bookID)
        }
        var tps = Set(chs.map { Topics.bookTopic[$0.bookID] ?? $0.bookID })
        scope.filter { $0.hasPrefix("t:") }.forEach { tps.insert(String($0.dropFirst(2))) }
        func inScope(_ k: String) -> Bool { scope.isEmpty || tps.contains(lib.items[k]?.topic ?? "") }
        let real = (type.contains("mc") ? lib.dseMC.filter(inScope) : [])
            + ((type.contains("lq") || type.contains("sq")) ? lib.dseLQ.filter(inScope) : [])
        // Chapter lists can contain the same DSE questions; keep the two pools disjoint so 0% really means none.
        let realSet = Set(lib.dseMC + lib.dseLQ)
        let orig = chs.flatMap { c in
            (type.contains("mc") ? c.mc : []) + (type.contains("sq") ? c.sq : []) + (type.contains("pr") ? c.pr : [])
        }.filter { !realSet.contains($0) }
        let mix = min(100, max(0, q.mix))
        var nr = Int((Double(n) * mix / 100).rounded())
        if mix > 0 && nr == 0 { nr = 1 }
        if mix < 100 && nr == n && n > 1 { nr = n - 1 }
        // Only top up from the other pool when one pool runs short, never across 0% / 100%.
        var takeReal = min(nr, real.count)
        var takeOrig = min(n - nr, orig.count)
        if mix > 0, takeOrig < n - nr { takeReal = min(real.count, n - takeOrig) }
        if mix < 100, takeReal < nr { takeOrig = min(orig.count, n - takeReal) }
        let pick = Array(prog.prioritised(real).prefix(takeReal)) + Array(prog.prioritised(orig).prefix(takeOrig))
        guard !pick.isEmpty else { noType = true; return }
        scene.start(T("Quiz", "测验") + " · \(pick.count) " + T("Qs", "题"), pick.shuffled())
    }
}

struct ChapterPickerView: View {
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    @State private var part: PartFilter = .all
    @State private var status: LearnedFilter = .all

    var body: some View {
        List {
            Section {
                Button {
                    let ids = lib.chapters.filter { prog.learned.contains($0.id) }.map { "c:" + $0.id }
                    prog.quiz.scope.removeAll { $0.hasPrefix("c:") }
                    prog.quiz.scope.append(contentsOf: ids)
                } label: {
                    Label(T("Select only chapters I've learned (\(prog.learned.count))", "只选已学章节（\(prog.learned.count)）"), systemImage: "checkmark.circle")
                }
                .disabled(prog.learned.isEmpty)
            }
            .listRowBackground(Color.cardBackground)
            ForEach(lib.books.filter { part.keep($0.elective) }) { b in
                let chs = b.chapters.filter { status.keep(prog.learned.contains($0.id)) }
                if !chs.isEmpty {
                    Section {
                        ForEach(chs) { c in
                            let v = "c:" + c.id
                            Button {
                                if prog.quiz.scope.contains(v) { prog.quiz.scope.removeAll { $0 == v } } else { prog.quiz.scope.append(v) }
                            } label: {
                                HStack {
                                    Text("Ch\(c.n) \(c.t)").foregroundStyle(.primary)
                                    if prog.learned.contains(c.id) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).imageScale(.small)
                                            .accessibilityLabel(T("Learned", "已学"))
                                    }
                                    Spacer()
                                    if prog.quiz.scope.contains(v) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).bold() }
                                }
                            }
                            .accessibilityAddTraits(prog.quiz.scope.contains(v) ? .isSelected : [])
                        }
                    } header: {
                        HStack {
                            Text("\(b.id) · \(b.name)")
                            Spacer()
                            let all = chs.allSatisfy { prog.quiz.scope.contains("c:" + $0.id) }
                            Button(all ? T("None", "全不选") : T("All", "全选")) {
                                for c in chs {
                                    let v = "c:" + c.id
                                    prog.quiz.scope.removeAll { $0 == v }
                                    if !all { prog.quiz.scope.append(v) }
                                }
                            }
                            .font(.caption.bold())
                            .textCase(nil)
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(T("Chapters", "章节"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) { FilterMenu(part: $part, status: $status) }
            ToolbarItem(placement: .secondaryAction) {
                Button(T("Clear", "清除")) { prog.quiz.scope.removeAll { $0.hasPrefix("c:") } }
            }
        }
    }
}

// MARK: - Progress

struct StatsView: View {
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(SceneModel.self) private var scene
    @Environment(\.tr) private var T
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                let all = lib.chapters.flatMap { $0.mc } + lib.dseMC
                let s = prog.stat(all)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { pills(s) }
                    VStack(alignment: .leading, spacing: 8) { pills(s) }
                }
            }
            .listRowBackground(Color.cardBackground)

            Section(T("DSE topics (real MC)", "DSE 课题（真题选择题）")) {
                ForEach(Topics.order, id: \.self) { t in
                    let k = lib.dseMC.filter { lib.items[$0]?.topic == t }
                    bar(Topics.name(t), prog.stat(k))
                }
            }
            .listRowBackground(Color.cardBackground)

            Section(T("Textbook MC", "课本选择题")) {
                ForEach(lib.chapters) { c in
                    let s = prog.stat(c.mc)
                    if s.done > 0 { bar(c.name, s) }
                }
                if lib.chapters.allSatisfy({ prog.stat($0.mc).done == 0 }) {
                    Text(T("Nothing yet.", "还没做题。")).foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.cardBackground)

            Section {
                Button(T("Reset all progress", "清除全部进度"), role: .destructive) { confirmReset = true }
            } footer: {
                Text(T("Progress is saved only on this device.", "进度只保存在这台设备上。"))
            }
            .listRowBackground(Color.cardBackground)
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(T(Library.subject.name + " Progress", Library.subject.name + " 进度"))
        .sectionToolbar()
        .confirmationDialog(T("Reset all progress? This can't be undone.", "清除全部进度？无法恢复。"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(T("Reset", "清除"), role: .destructive) { prog.reset() }
        }
    }

    @ViewBuilder private func pills(_ s: (done: Int, correct: Int, total: Int)) -> some View {
        StatPill(value: "\(s.done)", label: T("MC done", "已做选择题"))
        StatPill(value: s.done > 0 ? "\(Int((Double(s.correct) / Double(s.done) * 100).rounded()))%" : "—", label: T("accuracy", "正确率"))
        StatPill(value: "\(prog.wrongMC(in: lib).count)", label: T("to redo", "待重做"))
        StatPill(value: "\(prog.seen.count)", label: T("cards read", "已读卡"))
    }

    private func bar(_ title: String, _ s: (done: Int, correct: Int, total: Int)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(s.correct)/\(s.done) · \(s.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(s.done), total: Double(max(s.total, 1)))
                .tint(s.done > 0 && Double(s.correct) / Double(s.done) < 0.6 ? .orange : .accentColor)
        }
        .accessibilityElement(children: .combine)
    }
}
