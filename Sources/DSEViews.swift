import SwiftUI

struct DSEView: View {
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(SceneModel.self) private var scene
    @Environment(\.tr) private var T

    var body: some View {
        List {
            Section {
                Text(T("Verbatim HKDSE ICT Paper 1 questions with official answers and % correct, plus full Paper 2 elective papers.", "HKDSE ICT 卷一原题照录，附官方答案和当年答对率；卷二选修整卷可在 App 内看。"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            Section(T("Section A MC by topic", "卷一 A 选择题 · 按课题")) {
                ForEach(Topics.order, id: \.self) { t in
                    let k = lib.dseMC.filter { lib.items[$0]?.topic == t }
                    if !k.isEmpty {
                        let s = prog.stat(k)
                        Button { scene.start(Topics.name(t), Array(prog.prioritised(k).prefix(20))) } label: {
                            TopicRow(title: Topics.name(t), detail: "\(k.count)" + (s.done > 0 ? " · \(s.correct)/\(s.done)" : ""))
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                }
            }
            Section(T("Section B long questions by topic", "卷一 B 长题 · 按课题")) {
                ForEach(Topics.order, id: \.self) { t in
                    let k = lib.dseLQ.filter { lib.items[$0]?.topic == t }
                    if !k.isEmpty {
                        Button { scene.start("1B · " + Topics.name(t), Array(prog.prioritised(k).prefix(3))) } label: {
                            TopicRow(title: Topics.name(t), detail: "\(k.count)")
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                }
            }
            Paper2Section()
            Section(T("By year", "按年份")) {
                ForEach(lib.years) { y in
                    NavigationLink(value: Route.year(y.y)) {
                        HStack {
                            Text(y.label)
                            Spacer()
                            if let st = prog.sheets[y.y], st.done {
                                Text("\(st.score)/\(y.key.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            } else if !y.mc.isEmpty {
                                Text(T("in app", "站内可做")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(T(Library.subject.name + " Past Papers", Library.subject.name + " 真题"))
        .sectionToolbar()
    }
}

struct TopicRow: View {
    let title: String
    let detail: String
    var body: some View {
        HStack {
            Text(title).foregroundStyle(.primary).multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

struct YearView: View {
    let y: String
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(SceneModel.self) private var scene
    @Environment(\.tr) private var T
    @State private var confirmClear = false

    var body: some View {
        if let Y = lib.year(y) {
            let st = prog.sheets[y] ?? SheetState()
            List {
                Section {
                    if !Y.mc.isEmpty {
                        Button { scene.start(yearLabel(y) + " 1A", Y.mc) } label: {
                            Label(T("Paper 1A in app (\(Y.mc.count))", "卷一 A 站内整卷（\(Y.mc.count) 题）"), systemImage: "play.fill")
                        }
                    }
                    if !Y.lq.isEmpty {
                        Button { scene.start(yearLabel(y) + " 1B", Y.lq) } label: {
                            Label(T("Paper 1B long questions (\(Y.lq.count))", "卷一 B 长题（\(Y.lq.count) 题）"), systemImage: "square.and.pencil")
                        }
                    }
                    if let p = Y.paper { NavigationLink(value: Route.pdf(p, Y.label + " ICT Paper 1")) { Label(T("Paper PDF", "试卷 PDF"), systemImage: "doc.richtext") } }
                    if let m = Y.ms { Link(destination: m) { Label("Marking scheme", systemImage: "checkmark.seal") } }
                    ForEach(lib.paper2.filter { $0.year == y }) { p in
                        NavigationLink(value: Route.pdf(p.paper, "DSE \(y) Paper 2\(p.code)")) {
                            Label(T("Paper 2\(p.code) · ", "卷二 \(p.code) · ") + String(Electives.name(p.code).dropFirst(3)), systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    if Y.paper == nil && Y.mc.isEmpty {
                        Text(T("No public paper found for this year. Use your own copy with the answer sheet below.", "这一年没有公开试卷，可以用自己的试卷配合下面的答题纸。"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.cardBackground)

                Section {
                    AnswerSheet(y: y, key: Y.key, pct: Y.pct)
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text(T("Answer sheet", "答题纸") + (Y.note.map { " · \($0)" } ?? ""))
                } footer: {
                    if st.done {
                        Text(T("Score \(st.score)/\(Y.key.count)", "得分 \(st.score)/\(Y.key.count)")).font(.title3.bold()).foregroundStyle(.primary)
                    }
                }

                Section {
                    if st.done {
                        Button(T("Clear answers", "清空答案"), role: .destructive) { confirmClear = true }
                    } else {
                        Button(T("Submit answer sheet", "提交答题纸")) { submit(Y) }.bold()
                    }
                }
                .listRowBackground(Color.cardBackground)
            }
            .listStyle(.insetGrouped)
            .appList()
            .navigationTitle(Y.label + " ICT Paper 1")
            .deepSeek(DSContext.dseYear(Y, st))
            .noteRecent(.year(y), Y.label + " ICT Paper 1", T("Answer sheet", "答题纸"))
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(T("Clear this answer sheet?", "清空这份答题纸？"), isPresented: $confirmClear, titleVisibility: .visible) {
                Button(T("Clear", "清空"), role: .destructive) { prog.sheets[y] = SheetState() }
            }
        } else {
            ContentUnavailableView(T("Not found", "找不到"), systemImage: "questionmark")
        }
    }

    private func submit(_ Y: PaperYear) {
        var st = prog.sheets[y] ?? SheetState()
        st.score = Y.key.enumerated().filter { i, k in k == "*" || st.a[i + 1] == k }.count
        st.done = true
        prog.sheets[y] = st
    }
}

struct AnswerSheet: View {
    let y: String
    let key: [String]
    let pct: [String]
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T

    var body: some View {
        let st = prog.sheets[y] ?? SheetState()
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(Array(key.enumerated()), id: \.offset) { i, k in
                let n = i + 1
                HStack(spacing: 6) {
                    Text("\(n)").font(.callout.monospacedDigit().bold()).frame(width: 28, alignment: .trailing)
                    ForEach(["A", "B", "C", "D"], id: \.self) { l in
                        let chosen = st.a[n] == l
                        let color: Color = {
                            if st.done && k != "*" {
                                if l == k { return .good }
                                if chosen { return .bad }
                            }
                            return chosen ? .accentColor : Color(uiColor: .tertiarySystemFill)
                        }()
                        Button {
                            guard !st.done else { return }
                            var s = st
                            s.a[n] = chosen ? nil : l
                            prog.sheets[y] = s
                        } label: {
                            let _ = color
                            Text(l).font(Reading.font(16, weight: .bold))
                                .frame(width: 34, height: 30)
                                .mcGlass(st.done && k != "*" && l == k ? .correct : (st.done && chosen && k != "*" ? .wrong : (chosen ? .selected : .idle)))
                                .foregroundStyle(Color.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(n) \(l)")
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                    if st.done {
                        Text(k == "*" ? T("cancelled", "取消") : (i < pct.count && pct[i] != "-" ? pct[i] : ""))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Paper 2 (electives)

struct Paper2Section: View {
    @Environment(Library.self) private var lib
    @Environment(\.tr) private var T
    var body: some View {
        Section {
            ForEach(Electives.codes, id: \.self) { c in
                let n = lib.paper2.filter { $0.code == c }.count
                NavigationLink(value: Route.paper2(c)) {
                    HStack(spacing: 12) {
                        Text("2" + c).font(.subheadline.monospaced().bold()).foregroundStyle(.white)
                            .frame(width: 36, height: 30)
                            .background(Color.purple.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(Electives.name(c).dropFirst(3)))
                            if let b = Electives.book(c), let bk = lib.books.first(where: { $0.id == b }) {
                                Text(T("Closest textbook: \(bk.id) \(bk.name)", "对应课本：\(bk.id) \(bk.name)")).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(T("Old elective, not in the current textbooks", "旧课程选修，现行课本没有")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.cardBackground)
            }
        } header: {
            Text(T("Paper 2 · electives", "卷二 · 选修"))
        } footer: {
            Text(T("Full papers 2012–2023, opened inside the app. Marking schemes for 2012–2017.", "2012–2023 年完整试卷，在 App 内打开；2012–2017 年附评分标准。"))
        }
    }
}

struct Paper2View: View {
    let code: String
    @Environment(SceneModel.self) private var scene
    @Environment(Library.self) private var lib
    @Environment(\.tr) private var T
    var body: some View {
        List {
            Section {
                ForEach(lib.paper2.filter { $0.code == code }) { p in
                    NavigationLink(value: Route.pdf(p.paper, "DSE \(p.year) Paper 2\(code)")) {
                        HStack {
                            Label("HKDSE \(p.year)", systemImage: "doc.richtext")
                            Spacer(minLength: 8)
                            if let ms = p.ms {
                                Button {
                                    var path = scene.path(scene.section)
                                    path.append(Route.pdf(ms, "DSE \(p.year) 2\(code) Marking"))
                                    scene.paths[scene.section] = path
                                } label: {
                                    Label(T("Marking", "评分"), systemImage: "checkmark.seal")
                                        .font(.subheadline)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .contextMenu {
                        if let ms = p.ms {
                            Button {
                                var path = scene.path(scene.section)
                                path.append(Route.pdf(ms, "DSE \(p.year) 2\(code) Marking"))
                                scene.paths[scene.section] = path
                            } label: { Label(T("Open marking scheme", "打开评分标准"), systemImage: "checkmark.seal") }
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            } footer: {
                Text(T("2024–2026 Paper 2 aren't publicly available yet.", "2024–2026 年卷二暂时找不到公开版本。"))
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(Electives.name(code))
        .deepSeek(DSContext(key: "dse-p2-" + code, subject: "ict", title: Electives.name(code) + " · Paper 2",
                            page: "HKDSE ICT 卷二 " + Electives.name(code) + "。学生正在看这个选修的历年卷二列表。"))
        .noteRecent(.paper2(code), Electives.name(code), T("Paper 2", "卷二"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
