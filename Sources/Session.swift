import SwiftUI
import Observation

@Observable
final class Session: Identifiable {
    let id = UUID()
    let title: String
    let keys: [String]
    let started = Date().timeIntervalSince1970
    var index = 0
    var mc: [Int: Int] = [:]
    var text: [Int: [Int: String]] = [:]
    var code: [Int: String] = [:]
    var codePass: [Int: Bool] = [:]
    var selfMarks: [Int: [Int: Int]] = [:]
    var submitted = false
    /// Exam-plan task (exam id, task id) to tick when this session is submitted.
    var planTask: (UUID, String)?

    init(title: String, keys: [String]) { self.title = title; self.keys = keys }

    func answered(_ i: Int, _ it: Item?) -> Bool {
        guard let it else { return false }
        switch it.type {
        case .mc: return mc[i] != nil
        case .pr: return !(code[i] ?? "").isEmpty && code[i] != it.practical?.starter
        case .sq, .lq: return (text[i] ?? [:]).values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    func score(_ lib: Library) -> (got: Int, tot: Int) {
        var got = 0, tot = 0
        for (i, k) in keys.enumerated() {
            guard let it = lib.items[k] else { continue }
            switch it.type {
            case .mc: tot += 1; if it.cancel || mc[i] == it.a { got += 1 }
            case .pr: tot += 1; if codePass[i] == true { got += 1 }
            case .sq, .lq:
                for (j, p) in it.parts.enumerated() { tot += p.marks; got += min(p.marks, selfMarks[i]?[j] ?? 0) }
            }
        }
        return (got, tot)
    }

    func submit(_ lib: Library, _ prog: ProgressStore) {
        submitted = true
        if let (eid, tid) = planTask { ExamStore.shared.tick(eid, tid) }
        for (i, k) in keys.enumerated() {
            guard let it = lib.items[k] else { continue }
            if it.type == .mc { prog.record(k, ok: it.cancel || mc[i] == it.a) }
            if it.type == .pr { prog.record(k, ok: codePass[i] == true) }
        }
        saveRun(lib, prog)
    }

    func saveRun(_ lib: Library, _ prog: ProgressStore) {
        let s = score(lib)
        prog.saveRun(RunRecord(t: started, title: title, got: s.got, tot: s.tot))
    }

    func setSelfMark(_ i: Int, _ j: Int, _ v: Int, _ lib: Library, _ prog: ProgressStore) {
        selfMarks[i, default: [:]][j] = v
        saveRun(lib, prog)
        if let it = lib.items[keys[i]] {
            let full = it.parts.enumerated().allSatisfy { (selfMarks[i]?[$0.offset] ?? 0) >= $0.element.marks }
            prog.record(it.key, ok: full)
        }
    }
}

// MARK: - Keyboard actions published to scene-level commands

struct PagerActions {
    var prev: (() -> Void)?
    var next: (() -> Void)?
    var choose: ((Int) -> Void)?
    var submit: (() -> Void)?
}

struct PagerActionsKey: FocusedValueKey { typealias Value = PagerActions }
extension FocusedValues {
    var pager: PagerActions? {
        get { self[PagerActionsKey.self] }
        set { self[PagerActionsKey.self] = newValue }
    }
}

/// Fallback when focus is inside PencilKit / a PDF / a sheet: commands still reach the visible screen.
final class KeyRouter {
    static let shared = KeyRouter()
    var pager: PagerActions?
    var section: Binding<AppSection>?
}
extension View {
    func keyPager(_ a: PagerActions) -> some View {
        KeyRouter.shared.pager = a
        return self.onDisappear { KeyRouter.shared.pager = nil }
    }
}

struct PagerCommands: Commands {
    @FocusedValue(\.pager) private var focused
    private var pager: PagerActions? { focused ?? KeyRouter.shared.pager }
    @AppStorage("lang") private var lang = "zh"
    var body: some Commands {
        let T = Tr(en: lang == "en")
        CommandMenu(T("Study", "学习")) {
            Button(T("Previous", "上一页")) { pager?.prev?() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(pager?.prev == nil)
            Button(T("Next", "下一页")) { pager?.next?() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(pager?.next == nil)
            Button(T("Previous (⌘)", "上一页（⌘）")) { pager?.prev?() }
                .keyboardShortcut("[", modifiers: .command)
            Button(T("Next (⌘)", "下一页（⌘）")) { pager?.next?() }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            ForEach(0..<4, id: \.self) { i in
                Button(T("Choose ", "选 ") + ["A", "B", "C", "D"][i]) { pager?.choose?(i) }
                    .keyboardShortcut(KeyEquivalent(Character(["a", "b", "c", "d"][i])), modifiers: [])
                    .disabled(pager?.choose == nil)
            }
            Divider()
            Button(T("Submit", "交卷")) { pager?.submit?() }
                .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

// MARK: - Session screen (native List/Form)

struct SessionView: View {
    @Bindable var session: Session
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(SceneModel.self) private var scene
    @Environment(\.tr) private var T
    @State private var confirmSubmit = false
    @State private var confirmQuit = false
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            Group {
                if session.submitted {
                    ResultView(session: session)
                } else {
                    questionPage
                        .pageNav {
                            PageCluster(index: session.index, count: session.keys.count,
                                        prev: session.index > 0 ? { go(-1) } : nil,
                                        next: session.index < session.keys.count - 1 ? { go(1) } : nil)
                            if session.index == session.keys.count - 1 {
                                Button(T("Submit", "交卷")) { trySubmit() }.buttonStyle(.borderedProminent)
                            }
                        }
                }
            }
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(session.submitted ? T("Done", "完成") : T("Quit", "退出")) {
                        if session.submitted || session.keys.indices.allSatisfy({ !session.answered($0, lib.items[session.keys[$0]]) }) {
                            scene.session = nil
                        } else {
                            confirmQuit = true
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                }
                if !session.submitted {
                    ToolbarItem(placement: .principal) { jumpMenu }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(T("Submit", "交卷")) { trySubmit() }
                    }
                }
            }
            .confirmationDialog(T("Quit without submitting?", "不交卷直接退出？"), isPresented: $confirmQuit, titleVisibility: .visible) {
                Button(T("Quit", "退出"), role: .destructive) { scene.session = nil }
            }
            .confirmationDialog(T("\(unanswered) unanswered. Submit anyway?", "还有 \(unanswered) 题没做，确定交卷？"), isPresented: $confirmSubmit, titleVisibility: .visible) {
                Button(T("Submit anyway", "仍然交卷")) { session.submit(lib, prog) }
            }
        }
        .focusedSceneValue(\.pager, actions)
        .keyPager(actions)
        .hardTopEdge()
        .onKeyPress(.leftArrow) { guard !typing, !session.submitted else { return .ignored }; go(-1); return .handled }
        .onKeyPress(.rightArrow) { guard !typing, !session.submitted else { return .ignored }; go(1); return .handled }
    }

    private var actions: PagerActions {
        guard !session.submitted else { return PagerActions() }
        let it = lib.items[session.keys[session.index]]
        var a = PagerActions()
        if !typing {
            a.prev = session.index > 0 ? { go(-1) } : nil
            a.next = session.index < session.keys.count - 1 ? { go(1) } : nil
            if it?.type == .mc {
                let i = session.index
                let n = it?.o.count ?? 4
                a.choose = { j in if j < n { session.mc[i] = session.mc[i] == j ? nil : j; session.autoAdvance(from: i) } }
            }
        }
        a.submit = { trySubmit() }
        return a
    }

    private func go(_ d: Int) {
        session.index = min(max(0, session.index + d), session.keys.count - 1)
    }

    private var jumpMenu: some View {
        Menu {
            Picker(T("Question", "题目"), selection: $session.index) {
                ForEach(session.keys.indices, id: \.self) { j in
                    let done = session.answered(j, lib.items[session.keys[j]])
                    Label("\(j + 1)", systemImage: done ? "checkmark.circle.fill" : "circle").tag(j)
                }
            }
        } label: {
            Label(T("Question \(session.index + 1) of \(session.keys.count)", "第 \(session.index + 1) / \(session.keys.count) 题"), systemImage: "list.number")
                .labelStyle(.titleAndIcon)
        }
    }

    private var unanswered: Int {
        session.keys.indices.filter { !session.answered($0, lib.items[session.keys[$0]]) }.count
    }

    private func trySubmit() {
        if unanswered > 0 { confirmSubmit = true } else { session.submit(lib, prog) }
    }

    private var questionPage: some View {
        let i = session.index
        return Group {
            if let it = lib.items[session.keys[i]] {
                QuestionForm(item: it, index: i, session: session, typing: $typing)
                    .id(i)
                    .deepSeek(DSContext.ictItem(it, title: session.title + " · Q\(i + 1)"))
            }
        }
    }
}

// MARK: - Question content

struct QuestionHeader: View {
    let item: Item
    @Environment(\.tr) private var T
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !item.q.isEmpty {
                RichText(html: item.q, code: item.code && !HTML.hasTag(item.q))
            }
            ForEach(item.figs, id: \.self) { PageImage(url: $0) }
            if let f = item.fig { PageImage(url: f) }
            if !item.st.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(item.st.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if s.range(of: #"^\s*\(\d\)"#, options: .regularExpression) == nil {
                                Text("(\(i + 1))").monospacedDigit()
                            }
                            RichText(html: s)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    var meta: String {
        [item.src, (!item.pct.isEmpty && item.pct != "-" && item.isReal) ? T("% correct \(item.pct)", "当年答对率 \(item.pct)") : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A native list row for an MC option.
struct OptionRow: View {
    let letter: String
    let html: String
    let code: Bool
    var selected = false
    var mark: Bool? = nil   // true = correct answer, false = your wrong choice
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(letter).font(.headline).frame(width: 22, alignment: .leading)
            RichText(html: html, code: code).foregroundStyle(Color.primary)
            Spacer(minLength: 0)
            if let mark {
                Image(systemName: mark ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(mark ? Color.good : Color.bad)
            } else if selected {
                Image(systemName: "checkmark").bold().foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct QuestionForm: View {
    let item: Item
    let index: Int
    @Bindable var session: Session
    var typing: FocusState<Bool>.Binding
    @Environment(\.tr) private var T

    var body: some View {
        let hdr = QuestionHeader(item: item)
        Form {
            Section {
                hdr
            } header: {
                Text("\(T("Question", "第")) \(index + 1)\(T.en ? "" : " 题")" + (hdr.meta.isEmpty ? "" : " · " + hdr.meta))
            }
            .listRowBackground(Color.cardBackground)
            switch item.type {
            case .mc:
                Section(T("Choose one", "选一个答案")) {
                    ForEach(Array(item.o.enumerated()), id: \.offset) { j, o in
                        Button {
                            session.mc[index] = session.mc[index] == j ? nil : j
                            session.autoAdvance(from: index)
                        } label: {
                            OptionRow(letter: ["A", "B", "C", "D"][min(j, 3)], html: o, code: item.code && o.contains("\n"),
                                      selected: session.mc[index] == j)
                        }
                    }
                }
                .listRowBackground(Color.cardBackground)
            case .sq, .lq:
                if !item.pages.isEmpty {
                    Section(T("Original pages", "原卷页面")) {
                        ForEach(item.pages, id: \.self) { PageImage(url: $0) }
                    }
                    .listRowBackground(Color.cardBackground)
                }
                ForEach(Array(item.parts.enumerated()), id: \.offset) { j, p in
                    Section {
                        if let q = p.q, !q.isEmpty { RichText(html: q) }
                        ForEach(p.figs ?? [], id: \.self) { PageImage(url: Library.imageFile($0)) }
                        TextField(T("Your answer", "你的答案"),
                                  text: Binding(get: { session.text[index]?[j] ?? "" }, set: { session.text[index, default: [:]][j] = $0 }),
                                  axis: .vertical)
                            .lineLimit(4...)
                            .focused(typing)
                    } header: {
                        Text([p.l ?? "", T("\(p.marks) marks", "\(p.marks) 分")].filter { !$0.isEmpty }.joined(separator: " · "))
                    }
                    .listRowBackground(Color.cardBackground)
                }
            case .pr:
                if let p = item.practical {
                    Section {
                        PracticalEditor(item: item, practical: p,
                                        code: Binding(get: { session.code[index] ?? p.starter ?? "" }, set: { session.code[index] = $0 }),
                                        inSession: true) { pass in session.codePass[index] = pass }
                            .focused(typing)
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
        }
        .appList()
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: - Results

struct ResultView: View {
    @Bindable var session: Session
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(SceneModel.self) private var scene
    @Environment(\.tr) private var T

    var body: some View {
        let sc = session.score(lib)
        let wrong = session.keys.enumerated().filter { i, k in
            guard let it = lib.items[k], it.type == .mc, !it.cancel else { return false }
            return session.mc[i] != it.a
        }.map { $0.element }
        List {
            Section {
                LabeledContent(T("Score", "得分")) {
                    Text("\(sc.got) / \(sc.tot)").font(.title2.bold()).monospacedDigit()
                }
                Button { scene.start(session.title, session.keys.shuffled()) } label: {
                    Label(T("Retry (reshuffled)", "再做一次（重新洗牌）"), systemImage: "arrow.clockwise")
                }
                if !wrong.isEmpty {
                    Button { scene.start(T("Redo wrong ones", "重做错题"), wrong) } label: {
                        Label(T("Redo wrong (\(wrong.count))", "只做错题（\(wrong.count)）"), systemImage: "xmark.circle")
                    }
                }
            } footer: {
                if session.keys.contains(where: { lib.items[$0]?.type == .sq || lib.items[$0]?.type == .lq }) {
                    Text(T("Structured answers: give yourself marks against the marking points.", "结构题：对照评分要点，自己给分。"))
                }
            }
            .listRowBackground(Color.cardBackground)
            DSAnalyseChapters(chapters: Array(NSOrderedSet(array: session.keys.compactMap { lib.items[$0]?.chapterID }.filter { lib.chapter($0) != nil })) as? [String] ?? [])
            ForEach(Array(session.keys.enumerated()), id: \.offset) { i, k in
                if let it = lib.items[k] { review(i, it) }
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .deepSeek(DSContext.ictResult(session, lib))
    }

    @ViewBuilder private func review(_ i: Int, _ it: Item) -> some View {
        let hdr = QuestionHeader(item: it)
        Section {
            hdr
            switch it.type {
            case .mc:
                let a = session.mc[i]
                let ok = it.cancel || a == it.a
                ForEach(Array(it.o.enumerated()), id: \.offset) { j, o in
                    OptionRow(letter: ["A", "B", "C", "D"][min(j, 3)], html: o, code: it.code && o.contains("\n"),
                              selected: a == j, mark: j == it.a ? true : (a == j ? false : nil))
                }
                Label {
                    Text(T("Answer", "答案") + " " + (it.cancel ? T("(cancelled, mark given)", "（题目取消，全部给分）") : (it.a >= 0 && it.a < 4 ? ["A", "B", "C", "D"][it.a] : "?"))
                         + (a == nil ? " · " + T("not answered", "未作答") : ""))
                } icon: {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                }
                .foregroundStyle(ok ? Color.good : Color.bad)
                let ex = T.en ? it.e : (it.ez.isEmpty ? it.e : it.ez)
                if !ex.isEmpty { RichText(html: ex) }
            case .pr:
                let pass = session.codePass[i] == true
                Label(pass ? T("All tests passed", "全部测试通过") : T("Not passed", "未通过"),
                      systemImage: pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(pass ? Color.good : Color.bad)
                if let c = session.code[i], !c.isEmpty { CodeBlock(text: c) }
                DisclosureGroup(T("Reference solution", "参考答案")) {
                    CodeBlock(text: it.practical?.solution ?? it.practical?.modelAnswer ?? "")
                }
            case .sq, .lq:
                ForEach(Array(it.parts.enumerated()), id: \.offset) { j, p in
                    VStack(alignment: .leading, spacing: 8) {
                        if let l = p.l, !l.isEmpty { Text(l).bold() }
                        if let q = p.q, !q.isEmpty { RichText(html: q) }
                        ForEach(p.figs ?? [], id: \.self) { PageImage(url: Library.imageFile($0)) }
                        LabeledContent(T("Your answer", "你的答案")) {
                            let ans = session.text[i]?[j] ?? ""
                            Text(ans.isEmpty ? "—" : ans).textSelection(.enabled)
                        }
                        GroupBox(T("Marking points", "评分要点")) {
                            RichText(html: p.ms ?? "").frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Picker(T("Marks", "得分"), selection: Binding(
                        get: { session.selfMarks[i]?[j] ?? 0 },
                        set: { session.setSelfMark(i, j, $0, lib, prog) })) {
                        ForEach(0...p.marks, id: \.self) { Text("\($0) / \(p.marks)").tag($0) }
                    }
                }
            }
        } header: {
            Text("\(i + 1)" + (hdr.meta.isEmpty ? "" : " · " + hdr.meta))
        }
        .listRowBackground(Color.cardBackground)
    }
}

struct PageImage: View {
    let url: URL
    @State private var full = false
    @State private var tick = 0
    var body: some View {
        Group {
            let _ = tick
            if !FileManager.default.fileExists(atPath: url.path) {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    .task { await Library.fetchImage(url); tick += 1 }
            } else if let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture { full = true }
                    .accessibilityAddTraits(.isButton)
                    .sheet(isPresented: $full) { ZoomImage(image: img) }
            }
        }
    }
}

struct ZoomImage: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: 700 * scale * pinch)
            }
            .softEdges()
            .gesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
                .onEnded { v in scale = min(4, max(0.5, scale * v.magnification)) })
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
}



extension Session {
    /// "选好自动下一题": after an MC answer is picked, move on once the selection has been seen.
    func autoAdvance(from i: Int) {
        guard UserDefaults.standard.bool(forKey: "autoNext"), !submitted, mc[i] != nil, i < keys.count - 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.index == i, self.mc[i] != nil, !self.submitted else { return }
            withAnimation(.snappy) { self.index = i + 1 }
        }
    }
}
