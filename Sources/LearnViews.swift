import SwiftUI

enum PartFilter: String, CaseIterable, Identifiable {
    case all, compulsory, elective
    var id: String { rawValue }
    func title(_ T: Tr) -> String {
        switch self { case .all: return T("All parts", "全部"); case .compulsory: return T("Compulsory", "必修"); case .elective: return T("Electives", "选修") }
    }
    func keep(_ elective: Bool) -> Bool { self == .all || (self == .elective) == elective }
}

enum LearnedFilter: String, CaseIterable, Identifiable {
    case all, learned, notLearned
    var id: String { rawValue }
    func title(_ T: Tr) -> String {
        switch self { case .all: return T("All chapters", "全部章节"); case .learned: return T("Learned", "已学"); case .notLearned: return T("Not learned", "未学") }
    }
    var icon: String {
        switch self { case .all: return "list.bullet"; case .learned: return "checkmark.circle"; case .notLearned: return "circle" }
    }
    func keep(_ learned: Bool) -> Bool { self == .all || (self == .learned) == learned }
}

/// Textbook level 2: the subject's textbooks (compulsory + electives), with learned progress.
struct BookListView: View {
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    @State private var query = ""
    @AppStorage("learn.part") private var part: PartFilter = .all
    @AppStorage("learn.status") private var status: LearnedFilter = .all

    var body: some View {
        List {
            if query.isEmpty {
                Section { summary }
                    .listRowBackground(Color.cardBackground)
                if part.keep(false) { bookSection(lib.books.filter { !$0.elective }, title: T("Compulsory", "必修部分")) }
                if part.keep(true) { bookSection(lib.books.filter { $0.elective }, title: T("Electives", "选修部分")) }
            } else {
                searchResults
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(T(Library.subject.name + " Textbooks", Library.subject.name + " 课本"))
        .searchable(text: $query, prompt: T("Search knowledge cards", "搜索知识卡"))
        .refreshable { await lib.refresh() }
        .toolbar { ToolbarItem(placement: .primaryAction) { FilterMenu(part: $part, status: $status) } }
    }

    private var summary: some View {
        let t = lib.totals
        let learned = lib.chapters.filter { prog.learned.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { stats(t, learned) }
                VStack(alignment: .leading, spacing: 8) { stats(t, learned) }
            }
            ProgressView(value: Double(learned), total: Double(max(lib.chapters.count, 1)))
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func stats(_ t: (cards: Int, mc: Int, sq: Int, pr: Int), _ learned: Int) -> some View {
        StatPill(value: "\(learned)/\(lib.chapters.count)", label: T("chapters learned", "已学章节"))
        StatPill(value: "\(t.cards)", label: T("cards", "知识卡"))
        StatPill(value: "\(t.mc)", label: "MC")
        StatPill(value: "\(t.sq)", label: T("structured", "结构题"))
        StatPill(value: "\(t.pr)", label: T("hands-on", "实操"))
    }

    @ViewBuilder private func bookSection(_ books: [Book], title: String) -> some View {
        let shown = books.filter { b in status == .all || b.chapters.contains { status.keep(prog.learned.contains($0.id)) } }
        if !shown.isEmpty {
            Section(title) {
                ForEach(shown) { b in
                    NavigationLink(value: Route.book(b.id)) { BookRow(book: b) }
                        .listRowBackground(Color.cardBackground)
                }
            }
        }
    }

    private var searchResults: some View {
        let q = query.lowercased()
        var hits: [(Chapter, Int, Card)] = []
        for c in lib.chapters where part.keep(c.elective) {
            for (i, k) in c.cards.enumerated() where k.t.lowercased().contains(q) || (k.tz ?? "").lowercased().contains(q) {
                hits.append((c, i, k))
                if hits.count > 200 { break }
            }
        }
        return Section(T("\(hits.count) cards", "\(hits.count) 张知识卡")) {
            ForEach(Array(hits.enumerated()), id: \.offset) { _, h in
                NavigationLink(value: Route.cards(h.0.id, h.1)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.2.t)
                        Text(h.0.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.cardBackground)
            }
        }
    }
}

struct FilterMenu: View {
    @Binding var part: PartFilter
    @Binding var status: LearnedFilter
    var showPart = true
    @Environment(\.tr) private var T
    var body: some View {
        Menu {
            if showPart {
                Picker(T("Part", "部分"), selection: $part) {
                    ForEach(PartFilter.allCases) { Text($0.title(T)).tag($0) }
                }
            }
            Picker(T("Status", "状态"), selection: $status) {
                ForEach(LearnedFilter.allCases) { Label($0.title(T), systemImage: $0.icon).tag($0) }
            }
        } label: {
            Label(T("Filter", "筛选"), systemImage: (part == .all && status == .all) ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }
}

struct BookRow: View {
    let book: Book
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    var body: some View {
        let n = book.chapters.filter { prog.learned.contains($0.id) }.count
        HStack(spacing: 12) {
            Text(book.id)
                .font(.headline.monospaced())
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background((book.elective ? Color.purple : Color.blue).gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(book.name).font(.body)
                Text(T("\(n)/\(book.chapters.count) chapters learned", "已学 \(n)/\(book.chapters.count) 章")).font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(n), total: Double(max(book.chapters.count, 1))).tint(n == book.chapters.count ? .green : .accentColor)
            }
            if n == book.chapters.count && n > 0 {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Textbook level 3: chapters of one book, each with a learned checkmark.
struct BookChaptersView: View {
    let bookID: String
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    @AppStorage("learn.status") private var status: LearnedFilter = .all
    @State private var part: PartFilter = .all
    @State private var selecting = false

    var body: some View {
        if let b = lib.books.first(where: { $0.id == bookID }) {
            let shown = b.chapters.filter { status.keep(prog.learned.contains($0.id)) }
            List {
                Section {
                    ForEach(shown) { c in
                        Group {
                            if selecting {
                                Button { withAnimation { prog.toggleLearned(c.id) } } label: { ChapterRow(chapter: c, showCheck: true) }
                                    .buttonStyle(.plain)
                            } else {
                                NavigationLink(value: Route.chapter(c.id)) { ChapterRow(chapter: c) }
                                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                                        withAnimation { selecting = true }
                                    })
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                    if shown.isEmpty {
                        Text(status == .learned ? T("No chapters marked as learned yet.", "还没有标记为已学的章节。") : T("All chapters learned.", "全部章节都学完了。"))
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.cardBackground)
                    }
                } footer: {
                    Text(selecting ? T("Tick the chapters you've learned, then tap Done.", "勾选已学的章节，然后点「完成」。")
                                   : T("Tap Select or long-press a chapter to mark chapters as learned.", "点「选择」或长按章节，可以标记已学。"))
                }
            }
            .listStyle(.insetGrouped)
            .appList()
            .navigationTitle("\(b.id) · \(b.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(selecting ? T("Done", "完成") : T("Select", "选择")) { withAnimation { selecting.toggle() } }
                        .bold(selecting)
                }
                if !selecting {
                    ToolbarItem(placement: .primaryAction) { FilterMenu(part: $part, status: $status, showPart: false) }
                } else {
                    ToolbarItemGroup(placement: .bottomBar) {
                        let all = b.chapters.allSatisfy { prog.learned.contains($0.id) }
                        Button(all ? T("Unmark all", "全部取消") : T("Mark all learned", "全部标为已学")) {
                            for c in b.chapters { if all { prog.learned.remove(c.id) } else { prog.learned.insert(c.id) } }
                        }
                        Spacer()
                        Text(T("\(b.chapters.filter { prog.learned.contains($0.id) }.count) learned", "已学 \(b.chapters.filter { prog.learned.contains($0.id) }.count) 章"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            ContentUnavailableView(T("Not found", "找不到"), systemImage: "questionmark")
        }
    }
}

struct StatPill: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 64, alignment: .leading)
    }
}

struct ChapterRow: View {
    let chapter: Chapter
    var showCheck = false
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    var body: some View {
        let s = prog.stat(chapter.mc)
        let learned = prog.learned.contains(chapter.id)
        HStack(spacing: 12) {
            if showCheck {
                Image(systemName: learned ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(learned ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .accessibilityLabel(learned ? T("Learned", "已学") : T("Not learned", "未学"))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Ch\(chapter.n) \(chapter.t)").font(.body)
                Text("\(chapter.nCards) \(T("cards", "卡")) · \(chapter.nMC) MC · \(chapter.nSQ) \(T("structured", "结构题"))\((chapter.nPR == 0) ? "" : " · \(chapter.nPR) \(T("hands-on", "实操"))")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if s.done > 0 {
                Text("\(s.correct)/\(s.done)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !showCheck && learned {
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.green)
                    .accessibilityLabel(T("Learned", "已学"))
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Chapter

struct ChapterView: View {
    let chapterID: String
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(SceneModel.self) private var scene
    @Environment(\.tr) private var T
    @State private var tab = 0

    var body: some View {
        if let c = lib.chapter(chapterID) {
            List {
                Section {
                    Picker("", selection: $tab) {
                        Text(T("Cards", "知识卡")).tag(0)
                        Text(T("Practice", "练习")).tag(1)
                        Text(T("Structured", "结构题")).tag(2)
                        if !c.pr.isEmpty { Text(T("Hands-on", "实操")).tag(3) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                switch tab {
                case 0: cardsTab(c)
                case 1: practiceTab(c)
                case 2: structuredTab(c)
                default: handsOnTab(c)
                }
                if !c.isStub { DSMasterySection(chapterID: c.id) }
            }
            .overlay { if c.isStub { DownloadOverlay() } }
            .task { await lib.ensureChapter(chapterID) }
            .listStyle(.insetGrouped)
            .appList()
            .navigationTitle(c.name)
            .navigationBarTitleDisplayMode(.inline)
            .noteRecent(.chapter(c.id), c.name, T("Chapter overview", "章节页"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    let on = prog.learned.contains(c.id)
                    Button { prog.toggleLearned(c.id) } label: {
                        Label(on ? T("Learned", "已学") : T("Mark learned", "标为已学"), systemImage: on ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .tint(on ? .green : nil)
                }
            }
        } else {
            ContentUnavailableView(T("Not found", "找不到"), systemImage: "questionmark")
        }
    }

    @ViewBuilder private func cardsTab(_ c: Chapter) -> some View {
        Section {
            NavigationLink(value: Route.cards(c.id, 0)) {
                Label(T("Read from the start", "从第一张开始"), systemImage: "rectangle.stack")
            }
            .listRowBackground(Color.cardBackground)
        }
        ForEach(groupedCards(c), id: \.0) { sec, list in
            Section(sec.isEmpty ? T("Cards", "知识卡") : sectionTitle(c, sec)) {
                ForEach(list, id: \.0) { i, k in
                    NavigationLink(value: Route.cards(c.id, i)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(k.t)
                                if !T.en, let tz = k.tz, !tz.isEmpty { Text(tz).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if prog.seen.contains("\(c.id)-\(i)") {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).imageScale(.small)
                                    .accessibilityLabel(T("Read", "已读"))
                            }
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
        }
    }

    private func sectionTitle(_ c: Chapter, _ num: String) -> String {
        c.sections.first { $0.hasPrefix(num + " ") } ?? num
    }

    private func groupedCards(_ c: Chapter) -> [(String, [(Int, Card)])] {
        var order: [String] = []
        var dict: [String: [(Int, Card)]] = [:]
        for (i, k) in c.cards.enumerated() {
            let s = k.sec ?? ""
            if dict[s] == nil { order.append(s) }
            dict[s, default: []].append((i, k))
        }
        return order.map { ($0, dict[$0]!) }
    }

    @ViewBuilder private func practiceTab(_ c: Chapter) -> some View {
        let s = prog.stat(c.mc)
        Section {
            ForEach([10, 20, 40].filter { $0 < c.mc.count } + [c.mc.count], id: \.self) { n in
                Button {
                    scene.start(c.name, Array(prog.prioritised(c.mc).prefix(n)))
                } label: {
                    Label(n == c.mc.count ? T("All \(n) questions", "全部 \(n) 题") : T("\(n) questions", "\(n) 题"),
                          systemImage: n == 10 ? "play.fill" : "play")
                }
                .listRowBackground(Color.cardBackground)
            }
        } header: {
            Text(T("Multiple choice", "选择题"))
        } footer: {
            Text(T("One question per page, marked at the end. Unseen and wrong questions come first.", "一页一题，做完统一批改。没做过和做错的题优先出现。")
                 + (s.done > 0 ? " " + T("Done \(s.done)/\(s.total), correct \(s.correct).", "已做 \(s.done)/\(s.total)，答对 \(s.correct)。") : ""))
        }
        let bySec: [(String, [String])] = c.sections.compactMap { title in
            let num = String(title.split(separator: " ").first ?? "")
            let keys = c.mc.filter { lib.items[$0]?.sec == num }
            return keys.isEmpty ? nil : (title, keys)
        }
        if bySec.count > 1 {
            Section(T("By section", "按小节")) {
                ForEach(bySec, id: \.0) { title, keys in
                    let st = prog.stat(keys)
                    Button {
                        scene.start(title, Array(prog.prioritised(keys).prefix(10)))
                    } label: {
                        HStack {
                            Text(title).foregroundStyle(.primary)
                            Spacer()
                            Text("\(keys.count)" + (st.done > 0 ? " · \(st.correct)/\(st.done)" : ""))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
        }
        if !c.elective, let t = Topics.bookTopic[c.bookID] {
            let k = lib.dseMC.filter { lib.items[$0]?.topic == t }
            if !k.isEmpty {
                Section(T("Related DSE questions", "相关 DSE 真题")) {
                    Button {
                        scene.start(Topics.name(t), Array(prog.prioritised(k).prefix(10)))
                    } label: {
                        Label(T("\(k.count) real questions · start 10", "\(k.count) 道真题 · 做 10 题"), systemImage: "doc.text")
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
        }
    }

    @ViewBuilder private func structuredTab(_ c: Chapter) -> some View {
        Section {
            if c.sq.isEmpty {
                Text("—").foregroundStyle(.secondary)
            } else {
                Button {
                    scene.start(c.name + " · " + T("Structured", "结构题"), Array(prog.prioritised(c.sq).prefix(4)))
                } label: { Label(T("Start 4", "做 4 题"), systemImage: "play.fill") }
                    .listRowBackground(Color.cardBackground)
                Button {
                    scene.start(c.name + " · " + T("Structured", "结构题"), c.sq)
                } label: { Label(T("All \(c.sq.count)", "全部 \(c.sq.count) 题"), systemImage: "play") }
                    .listRowBackground(Color.cardBackground)
            }
        } footer: {
            Text(T("Write your answers, then compare with the marking points and mark yourself.", "先写答案，交卷后对照评分要点自己给分。"))
        }
    }

    @ViewBuilder private func handsOnTab(_ c: Chapter) -> some View {
        Section {
            ForEach(c.pr, id: \.self) { k in
                if let it = lib.items[k], let p = it.practical {
                    NavigationLink(value: Route.practical(k)) {
                        HStack {
                            Text(T(p.t, p.tz ?? p.t))
                            Spacer()
                            Text((p.lang ?? "").uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if let r = prog.lastResult(k) {
                                Image(systemName: r ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(r ? Color.good : Color.bad)
                            }
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
        } footer: {
            Text(T("SQL, Python, JavaScript and HTML are checked automatically. PHP shows a model answer.", "SQL、Python、JavaScript 和 HTML 会自动判对错；PHP 给参考答案。"))
        }
    }
}

// MARK: - Knowledge cards, one per page

struct CardPagerView: View {
    let chapterID: String
    let start: Int
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    @State private var index: Int?
    @FocusState private var focused: Bool
    @State private var visited: Set<Int> = []
    @Environment(SceneModel.self) private var scene

    var body: some View {
        if let c = lib.chapter(chapterID), c.isStub {
            DownloadOverlay().task { await lib.ensureChapter(chapterID) }
        } else if let c = lib.chapter(chapterID), !c.cards.isEmpty {
            let i = min(max(index ?? start, 0), c.cards.count - 1)
            TabView(selection: Binding(get: { i }, set: { index = $0 })) {
                ForEach(Array(c.cards.enumerated()), id: \.offset) { j, k in
                    ScrollView {
                        CardContent(card: k, position: "\(j + 1)/\(c.cards.count)")
                            .frame(maxWidth: 760)
                            .padding(.vertical)
                            .readingMargin()
                            .frame(maxWidth: .infinity)
                    }
                    .softEdges()
                    .tag(j)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .softEdges()
            .appScreen()
            .navigationTitle(c.name)
            .navigationBarTitleDisplayMode(.inline)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.leftArrow) { if i > 0 { index = i - 1 }; return .handled }
            .onKeyPress(.rightArrow) { if i < c.cards.count - 1 { index = i + 1 }; return .handled }
            .focusedSceneValue(\.pager, PagerActions(prev: i > 0 ? { index = i - 1 } : nil,
                                                       next: i < c.cards.count - 1 ? { index = i + 1 } : nil))
            .keyPager(PagerActions(prev: i > 0 ? { index = i - 1 } : nil,
                                                       next: i < c.cards.count - 1 ? { index = i + 1 } : nil))
            .onAppear { prog.seen.insert("\(c.id)-\(i)"); focused = true }
            .noteRecent(.cards(c.id, i), c.name, T("Card \(i + 1) of \(c.cards.count) · ", "第 \(i + 1)/\(c.cards.count) 张 · ") + c.cards[i].t)
            .onChange(of: i) { _, n in prog.seen.insert("\(c.id)-\(n)"); visited.insert(n); tickIfRead(c) }
            .onAppear { visited.insert(i) }
            .deepSeek(DSContext.ictCard(c, i))
            .pageNav {
                PageCluster(index: i, count: c.cards.count,
                            prev: i > 0 ? { index = i - 1 } : nil,
                            next: i < c.cards.count - 1 ? { index = i + 1 } : nil) {
                    Menu {
                        Picker("", selection: Binding(get: { i }, set: { index = $0 })) {
                            ForEach(Array(c.cards.enumerated()), id: \.offset) { j, k in
                                Text("\(j + 1). \(k.t)").tag(j)
                            }
                        }
                    } label: { Text("\(i + 1)/\(c.cards.count)") }
                }
            }
        } else {
            ContentUnavailableView(T("No cards", "没有知识卡"), systemImage: "rectangle.stack")
        }
    }
}

extension CardPagerView {
    func tickIfRead(_ c: Chapter) {
        guard let t = scene.cardTask, t.chapter == c.id else { return }
        if visited.count >= min(10, c.cards.count) {
            ExamStore.shared.tick(t.exam, t.task)
            scene.cardTask = nil
        }
    }
}

struct CardContent: View {
    let card: Card
    let position: String
    @Environment(\.tr) private var T
    @State private var open: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text([card.sec, card.ty, position].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(card.t).font(.title2.bold())
                if !T.en, let tz = card.tz, !tz.isEmpty { Text(tz).font(.headline).foregroundStyle(.secondary) }
            }
            if card.ty == "cheatsheet" {
                Label(T("Cheat sheet", "速查表"), systemImage: "tablecells").font(.subheadline.bold()).foregroundStyle(Color.accentColor)
            }
            RichText(html: T.en ? (card.en ?? card.zh ?? "") : (card.zh ?? card.en ?? ""))
            if let demo = card.demo { DemoView(demo: demo).id(card.t) }
            ForEach(Array((card.code ?? []).enumerated()), id: \.offset) { _, c in
                CodeSnippetView(snip: c)
            }
            ForEach(Array((card.ex ?? []).enumerated()), id: \.offset) { j, e in
                let mistake = e.mistake == true
                VStack(alignment: .leading, spacing: 10) {
                    if mistake {
                        Label(T("Common mistake · Example \(j + 1)", "常见错误 · 例题 \(j + 1)"), systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(Color.bad)
                    } else {
                        Text(T("Example \(j + 1)", "例题 \(j + 1)")).font(.headline)
                    }
                    RichText(html: e.q)
                    DisclosureGroup(isExpanded: Binding(get: { open.contains(j) }, set: { if $0 { open.insert(j) } else { open.remove(j) } })) {
                        RichText(html: T.en ? e.a : ((e.az ?? "").isEmpty ? e.a : e.az!))
                            .padding(.top, 8)
                    } label: {
                        Text(mistake ? T("Why it's wrong", "错在哪里") : T("Worked solution", "看解答"))
                    }
                }
                .card()
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(mistake ? Color.bad.opacity(0.6) : .clear, lineWidth: 1.5))
            }
        }
        .card()
    }
}
