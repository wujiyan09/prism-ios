import SwiftUI

struct RootView: View {
    @Environment(Library.self) private var lib
    @Environment(\.horizontalSizeClass) private var hsc
    @AppStorage("lang") private var lang = "zh"
    @AppStorage("theme") private var theme = AppTheme.navy.rawValue
    @State private var scene = SceneModel()

    var body: some View {
        let T = Tr(en: lang == "en")
        Group {
            if !lib.loaded || lib.needsDownload {
                DownloadView()
            } else if hsc == .compact {
                tabs(T)
            } else {
                split(T)
            }
        }
        .scratchKeepPrompt()
        .id(theme)   // rebuild so every page picks up a new background theme
        .environment(scene)
        .environment(\.tr, T)
        .onChange(of: Reminders.shared.openExam) { _, id in
            guard let id else { return }
            scene.open(.plan, .exam(id))
            Reminders.shared.openExam = nil
        }
        .focusedSceneValue(\.sectionSelection, Binding(get: { scene.section }, set: { scene.section = $0 }))
        .onAppear { KeyRouter.shared.section = Binding(get: { scene.section }, set: { scene.section = $0 }) }
        .fullScreenCover(item: Binding(get: { scene.session }, set: { scene.session = $0 })) { s in
            SessionView(session: s)
                .environment(scene)
                .environment(\.tr, T)
                .environment(lib)
                .environment(ProgressStore.shared)
                .environment(ExamStore.shared)
        }
    }

    @AppStorage("sidebar.order") private var sidebarOrder = ""
    @AppStorage("sidebar.hidden") private var sidebarHidden = ""
    @State private var sidebarEditing: EditMode = .inactive

    private func tabs(_ T: Tr) -> some View {
        let _ = (sidebarOrder, sidebarHidden)
        return TabView(selection: Binding<String>(
            get: { AppSection.compactTabs.contains(scene.section) ? scene.section.rawValue : "more" },
            set: { v in
                if let s = AppSection(rawValue: v) { scene.section = s }
                else if !AppSection.moreSections.contains(scene.section) { scene.section = AppSection.moreSections.first ?? .settings }
            })) {
            ForEach(AppSection.compactTabs) { s in
                stack(s)
                    .tabItem { Label(s.title(T), systemImage: s.icon) }
                    .tag(s.rawValue)
            }
            MoreRoot()
                .tabItem { Label(T("More", "更多"), systemImage: "ellipsis.circle") }
                .tag("more")
        }
    }

    private func split(_ T: Tr) -> some View {
        NavigationSplitView {
            List(selection: Binding<AppSection?>(get: { scene.section }, set: { if let v = $0 { scene.section = v } })) {
                let _ = (sidebarOrder, sidebarHidden)
                Section {
                    ForEach(sidebarEditing.isEditing ? AppSection.ordered : AppSection.visible) { s in
                        Label(s.title(T), systemImage: s.icon).tag(s)
                            .opacity(AppSection.hidden.contains(s) ? 0.4 : 1)
                            .contextMenu {
                                Button { withAnimation { sidebarEditing = .active } } label: { Label(T("Edit sidebar", "编辑侧边栏"), systemImage: "arrow.up.arrow.down") }
                                if s != .settings {
                                    Button { withAnimation { AppSection.setHidden(s, true); sidebarHidden = UserDefaults.standard.string(forKey: "sidebar.hidden") ?? "" } } label: {
                                        Label(T("Hide", "隐藏"), systemImage: "eye.slash")
                                    }
                                }
                            }
                    }
                    .onMove { from, to in
                        var all = AppSection.ordered
                        all.move(fromOffsets: from, toOffset: to)
                        AppSection.saveOrder(all)
                        sidebarOrder = UserDefaults.standard.string(forKey: "sidebar.order") ?? ""
                    }
                } footer: {
                    let t = lib.totals
                    let m = MathLibrary.shared
                    let mmc = m.chapters("math").reduce(0) { $0 + $1.sets.reduce(0) { $0 + $1.n } }
                    VStack(alignment: .leading, spacing: 2) {
                        let dl = lib.chapters.filter { !$0.cards.isEmpty }.count
                        Text("ICT · \(lib.chapters.count) \(T("chapters", "章"))" + (dl < lib.chapters.count ? T(" · \(dl) downloaded", " · 已下载 \(dl)") : " · \(t.cards) \(T("cards", "卡")) · \(t.mc) MC") + " · \(lib.dseMC.count) DSE")
                        Text("\(T("Maths", "数学")) · \(m.chapters("math").count) \(T("chapters", "章")) · \(m.chapters("math").reduce(0) { $0 + $1.nCards }) \(T("cards", "卡")) · \(mmc) MC")
                        if !m.chapters("zh").isEmpty { Text("中文 · \(m.chapters("zh").count) 篇範文 · \(m.chapters("zh").reduce(0) { $0 + $1.sets.reduce(0) { $0 + $1.n } }) MC") }
                        if !m.chapters("chem").isEmpty { Text("\(T("Chemistry", "化学")) · \(m.chapters("chem").count) \(T("chapters", "章")) · \(m.chapters("chem").reduce(0) { $0 + $1.nCards }) \(T("cards", "卡")) · \(m.chapters("chem").reduce(0) { $0 + $1.sets.reduce(0) { $0 + $1.n } }) MC") }
                    }
                }
            }
            .navigationTitle("Prism")
            .environment(\.editMode, $sidebarEditing)
            .toolbar {
                if sidebarEditing.isEditing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(T("Done", "完成")) { withAnimation { sidebarEditing = .inactive } }
                    }
                }
            }
        } detail: {
            stack(scene.section)
                .id(scene.section)
        }
    }

    private func stack(_ s: AppSection) -> some View {
        NavigationStack(path: Binding(get: { scene.path(s) }, set: { scene.paths[s] = $0 })) {
            SectionRoot(section: s, asRoot: true)
                .navigationDestination(for: Route.self) { r in RouteView(route: r) }
        }
    }
}

/// Root content of a section. Subject-first sections show the subject list when there's more than one subject…
/// and always as the first level, as Sam asked: subject, then textbook/chapters.
struct SectionRoot: View {
    let section: AppSection
    var asRoot = false
    var body: some View {
        switch section {
        case .learn, .dse, .quiz, .progress: SubjectListView(section: section)
        case .tools: ToolsView()
        case .settings: SettingsView()
        case .inbox: InboxView()
        case .notes: NotesLibraryView()
        case .plan: PlanListView()
        case .daily: DailyListView()
        }
    }
}

struct RouteView: View {
    let route: Route
    /// 中文 content screens get the Songti serif.
    private var zh: Bool {
        switch route {
        case .subject(_, "zh"): return true
        case .mathChapter(let id), .mathCards(let id, _), .mathSets(let id): return id.hasPrefix("z-")
        case .mathItem(let id): return MathLibrary.shared.item(id)?.0.isZh ?? false
        case .mathBook(let id): return MathLibrary.shared.books("zh").contains { $0.id == id }
        case .mathQuiz(let s):
            switch s {
            case .set(let id): return id.lowercased().hasPrefix("z-")
            case .custom(let chs, _, _): return !chs.isEmpty && chs.allSatisfy { $0.hasPrefix("z-") }
            }
        default: return false
        }
    }
    var body: some View {
        content.environment(\.zhSerif, zh)
    }
    @ViewBuilder private var content: some View {
        switch route {
        case .chapter(let id): ChapterView(chapterID: id)
        case .cards(let id, let i): CardPagerView(chapterID: id, start: i)
        case .practical(let k): PracticalPage(key: k)
        case .year(let y): YearView(y: y)
        case .tool(let t): ToolView(kind: t)
        case .chapterPicker: ChapterPickerView()
        case .exam(let id): ExamDetailView(id: id)
        case .subject(.learn, "math"): MathBookListView()
        case .subject(.quiz, "math"): MathQuizHome()
        case .subject(.progress, "math"): MathStatsView()
        case .subject(.dse, "math"): MathPapersHome()
        case .subject(.learn, "zh"): MathBookListView(subj: "zh")
        case .subject(.quiz, "zh"): MathQuizHome(subj: "zh")
        case .subject(.progress, "zh"): MathStatsView(subj: "zh")
        case .subject(.learn, "chem"): MathBookListView(subj: "chem")
        case .subject(.quiz, "chem"): MathQuizHome(subj: "chem")
        case .subject(.progress, "chem"): MathStatsView(subj: "chem")
        case .subject(.dse, "chem"): ChemPapersHome()
        case .subject(let sec, _):
            switch sec {
            case .learn: BookListView()
            case .dse: DSEView()
            case .quiz: QuizBuilderView()
            default: StatsView()
            }
        case .book(let id): BookChaptersView(bookID: id)
        case .section(let s): SectionRoot(section: s)
        case .paper2(let code): Paper2View(code: code)
        case .pdf(let u, let title): PDFPage(url: u, title: title)
        case .mathBook(let id): MathBookView(bookID: id)
        case .mathChapter(let id): MathChapterView(chapterID: id)
        case .mathCards(let id, let i): MathCardPager(chapterID: id, start: i)
        case .mathItem(let id): MathItemView(itemID: id)
        case .mathSets(let id):
            if id.hasPrefix("z-") { ZhSetsView(chapterID: id) } else { MathSetsView(chapterID: id) }
        case .mathQuiz(let s): MathQuizRunner(spec: s)
        case .daily(let d): DailyDayView(date: d)
        case .dailyRun(let d): DailyRunner(date: d)
        case .mathPaper(let id): OfficialRoute(id: id, set: false)
        case .ppSet(let id): OfficialRoute(id: id, set: true)
        }
    }
}

/// Level 1 of Textbook / Past Papers / Quiz / Progress: pick a subject.
struct SubjectListView: View {
    let section: AppSection
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    @AppStorage("subject.order") private var orderRaw = ""
    @State private var editing: EditMode = .inactive
    private var subjects: [Subject] {
        _ = orderRaw
        return Subject.ordered.filter { section == .learn || section == .quiz || section == .progress || !$0.bundled || $0.id == "math" || $0.id == "chem" }
    }
    var body: some View {
        List {
            RecentSection(section: section)
            Section {
                ForEach(subjects) { sub in
                    NavigationLink(value: Route.subject(section, sub.id)) {
                        HStack(spacing: 14) {
                            Image(systemName: sub.icon)
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 48, height: 48)
                                .background(section.tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(T(sub.name, sub.nameZh)).font(.headline)
                                Text(detail(sub)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.cardBackground)
                }
                .onMove { from, to in
                    var all = Subject.ordered
                    let shown = subjects
                    var moved = shown
                    moved.move(fromOffsets: from, toOffset: to)
                    // keep hidden subjects where they were
                    var it = moved.makeIterator()
                    all = all.map { s in shown.contains(s) ? (it.next() ?? s) : s }
                    Subject.saveOrder(all)
                    orderRaw = all.map(\.id).joined(separator: ",")
                }
            } footer: {
                Text(T("Tap Edit to reorder subjects.", "点「编辑」可以调整科目顺序。"))
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .environment(\.editMode, $editing)
        .toolbar { ToolbarItem(placement: .confirmationAction) { EditButton().environment(\.editMode, $editing).tint(.primary) } }
        .navigationTitle(section.title(T))
    }

    private func detail(_ sub: Subject) -> String {
        if sub.id == "math" && section == .dse { return T("HKCEE by topic · school papers", "HKCEE 按课题 · 学校卷") }
        if sub.id == "zh" {
            let m = MathLibrary.shared
            let chs = m.chapters("zh")
            let qn = chs.reduce(0) { $0 + $1.sets.reduce(0) { $0 + $1.n } }
            if section == .quiz { return "\(qn) 道選擇題" }
            if section == .progress {
                let s = prog.stat(chs.flatMap { $0.sets.flatMap { $0.qids } }.map { MathMC.key($0) })
                return "已做 \(s.done) 道選擇題"
            }
            let n = chs.filter { prog.learned.contains($0.id) }.count
            return "\(chs.count) 篇範文 · 已學 \(n) 篇"
        }
        if sub.id == "math" {
            let m = MathLibrary.shared
            let mInfo = m.chapters("math").flatMap { $0.sets }
            let mq = mInfo.reduce(0) { $0 + $1.n }
            if section == .quiz { return T("\(mInfo.count) MC sets · \(mq) questions", "\(mInfo.count) 套选择题 · \(mq) 题") }
            if section == .progress {
                let s = prog.stat(mInfo.flatMap { $0.qids }.map { MathMC.key($0) })
                return T("\(s.done) MC done", "已做 \(s.done) 道选择题")
            }
            return T("\(m.books("math").count) books · \(m.chapters("math").count) chapters", "\(m.books("math").count) 本课本 · \(m.chapters("math").count) 章")
        }
        guard sub.id == Library.subject.id else { return "" }
        switch section {
        case .learn:
            let n = lib.chapters.filter { prog.learned.contains($0.id) }.count
            return T("\(lib.books.count) textbooks · \(n)/\(lib.chapters.count) chapters learned", "\(lib.books.count) 本课本 · 已学 \(n)/\(lib.chapters.count) 章")
        case .dse:
            return T("Paper 1 · Paper 2 electives · \(lib.years.count) years", "卷一 · 卷二选修 · \(lib.years.count) 年")
        case .quiz:
            return T("\(lib.totals.mc) textbook MC · \(lib.dseMC.count) DSE MC", "\(lib.totals.mc) 道课本选择题 · \(lib.dseMC.count) 道 DSE 真题")
        default:
            let s = prog.stat(lib.chapters.flatMap { $0.mc } + lib.dseMC)
            return T("\(s.done) MC done", "已做 \(s.done) 道选择题")
        }
    }
}

/// Portrait "More" tab: a proper grouped list in the style of Settings.
struct MoreRoot: View {
    @Environment(SceneModel.self) private var scene
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    var body: some View {
        NavigationStack(path: Binding(get: { scene.path(.tools) }, set: { scene.paths[.tools] = $0 })) {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "triangle.fill")
                            .font(.title)
                            .foregroundStyle(LinearGradient(colors: [.white, .accentColor], startPoint: .top, endPoint: .bottom))
                            .frame(width: 56, height: 56)
                            .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Prism").font(.title3.bold())
                            let s = prog.stat(lib.chapters.flatMap { $0.mc } + lib.dseMC)
                            Text(T("\(prog.learned.count) chapters learned · \(s.done) MC done", "已学 \(prog.learned.count) 章 · 已做 \(s.done) 题"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color.cardBackground)

                Section(T("Study", "学习")) {
                    let _ = (sidebarOrder, sidebarHidden)
                    ForEach(AppSection.moreSections.filter { $0 != .settings }) { s in row(s, sub(s)) }
                }
                .listRowBackground(Color.cardBackground)

                Section(T("Tools", "工具")) {
                    ForEach(ToolKind.allCases) { k in
                        NavigationLink(value: Route.tool(k)) {
                            Label { Text(k.title(T)) } icon: { IconTile(symbol: k.icon, color: .indigo) }
                        }
                    }
                }
                .listRowBackground(Color.cardBackground)

                Section(T("App", "应用")) {
                    row(.settings, T("Language, content updates, reminders", "语言、内容更新、提醒"))
                }
                .listRowBackground(Color.cardBackground)
            }
            .listStyle(.insetGrouped)
            .appList()
            .navigationTitle(T("More", "更多"))
            .navigationDestination(for: Route.self) { r in RouteView(route: r) }
        }
    }

    @AppStorage("sidebar.order") private var sidebarOrder = ""
    @AppStorage("sidebar.hidden") private var sidebarHidden = ""
    private func sub(_ s: AppSection) -> String {
        switch s {
        case .dse: return T("DSE past papers and marking schemes", "DSE 历届真题和评分标准")
        case .progress: return T("Accuracy by topic and chapter", "按课题和章节看正确率")
        case .tools: return T("Bases, two's complement, subnets, SQL, tracing", "进制、补码、子网、SQL、追踪表")
        case .daily: return T("Today's practice paper", "今天的练习卷")
        case .learn: return T("Textbooks and chapters", "课本和章节")
        case .quiz: return T("MC quizzes by chapter", "按章节做选择题")
        case .plan: return T("Test-week plans", "测验周计划")
        case .inbox: return T("Ideas, to-dos and notes", "想法、待办和笔记")
        case .notes: return T("Documents with ink, images and text", "手写、图片和文本框的文档")
        case .settings: return ""
        }
    }
    private func row(_ s: AppSection, _ sub: String) -> some View {
        NavigationLink(value: Route.section(s)) {
            HStack(spacing: 12) {
                IconTile(symbol: s.icon, color: s.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title(T))
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct IconTile: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct LanguageMenu: View {
    @AppStorage("lang") private var lang = "zh"
    var body: some View {
        Menu {
            Picker("Language", selection: $lang) {
                Text("全英文 · English").tag("en")
                Text("英文知识点 + 中文讲解").tag("zh")
            }
        } label: {
            Label(lang == "en" ? "Language" : "语言", systemImage: "globe")
        }
    }
}

/// Shared toolbar for section roots.
struct SectionToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content
    }
}
extension View { func sectionToolbar() -> some View { modifier(SectionToolbar()) } }

struct DownloadView: View {
    @Environment(Library.self) private var lib
    @AppStorage("lang") private var lang = "zh"
    var body: some View {
        let T = Tr(en: lang == "en")
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle").font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text(T("Getting your study content", "正在下载学习内容")).font(.title2.bold())
            if lib.downloadFailed {
                Text(T("Download failed. Check your internet connection.", "下载失败，请检查网络。"))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(T("Try again", "重试")) { Task { await lib.firstDownload() } }
                    .glassButton(prominent: true)
            } else {
                Text(lib.version == 0 ? T("Step 1 of 2: lessons and questions", "第 1 步（共 2 步）：课程和题目")
                                      : T("Step 2 of 2: exam pages and figures", "第 2 步（共 2 步）：试卷页面和图片"))
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(lib.downloadDone), total: Double(max(lib.downloadTotal, 1)))
                    .frame(maxWidth: 360)
                Text("\(lib.downloadDone) / \(lib.downloadTotal)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(T("Only needed once. After this everything works offline.", "只需下载一次，之后可离线使用。"))
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appScreen()
    }
}

struct SettingsView: View {
    @Environment(Library.self) private var lib
    @AppStorage("lang") private var lang = "zh"
    @State private var checking = false
    @AppStorage("autoNext") private var autoNext = true
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("theme") private var theme = AppTheme.navy.rawValue
    var body: some View {
        let T = Tr(en: lang == "en")
        Form {
            Section {
                NavigationLink {
                    AccountView()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 52))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            if SyncManager.shared.signedIn {
                                Text(SyncManager.shared.email ?? T("Google account", "Google 账号")).font(.title3.weight(.semibold)).lineLimit(1)
                                Text(T("Account, sync", "账号与同步")).font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                Text(T("Sign in", "登录")).font(.title3.weight(.semibold))
                                Text(T("Sync progress across your devices", "在你的设备间同步进度")).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                NavigationLink {
                    StorageView()
                } label: {
                    Label(T("Storage", "存储"), systemImage: "internaldrive")
                }
                NavigationLink {
                    ReadingSettingsView()
                } label: {
                    Label(T("Reading", "阅读"), systemImage: "textformat.size")
                }
                NavigationLink {
                    DeepSeekSettingsView()
                } label: {
                    Label("DeepSeek", systemImage: "sparkles")
                }
            }
            .listRowBackground(Color.cardBackground)
            PortalSettingsSection()
            Section {
                Picker(T("Language", "语言"), selection: $lang) {
                    Text("English").tag("en")
                    Text("English + 中文").tag("zh")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text(T("Language", "语言"))
            } footer: {
                Text(T("Knowledge points stay in English. EN + 中文 adds Chinese explanations.", "知识点保持英文；EN + 中文 会加上中文讲解。"))
            }
            .listRowBackground(Color.cardBackground)
            Section {
                NavigationLink { SidebarOrderView() } label: { Label(T("Sidebar", "侧边栏"), systemImage: "sidebar.left") }
                NavigationLink { SubjectOrderView() } label: { Label(T("Subject order", "学科顺序"), systemImage: "arrow.up.arrow.down") }
            } header: {
                Text(T("Order", "顺序"))
            }
            .listRowBackground(Color.cardBackground)
            Section {
                Picker(T("Appearance", "外观"), selection: $appearance) {
                    Text(T("System", "跟随系统")).tag("system")
                    Text(T("Light", "浅色")).tag("light")
                    Text(T("Dark", "深色")).tag("dark")
                }
                .pickerStyle(.segmented)
            } header: { Text(T("Appearance", "外观")) }
            .listRowBackground(Color.cardBackground)
            Section {
                Picker(selection: $theme) {
                    ForEach(AppTheme.allCases) { th in
                        Label {
                            Text(th.title(T))
                        } icon: {
                            Circle().fill(th.swatch).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(.secondary.opacity(0.5), lineWidth: 1))
                        }
                        .tag(th.rawValue)
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text(T("Background", "背景颜色"))
            } footer: {
                Text(T("Used in dark mode. Light mode always uses the system colours.", "深色模式下生效；浅色模式始终用系统颜色。"))
            }
            .listRowBackground(Color.cardBackground)
            Section {
                Toggle(T("Auto-advance after choosing", "选好自动下一题"), isOn: $autoNext)
            } header: {
                Text(T("Practice", "做题"))
            } footer: {
                Text(T("After you pick an MC answer, go to the next question. Not on the last one.", "选好选择题答案后自动跳到下一题，最后一题不会跳。"))
            }
            .listRowBackground(Color.cardBackground)
            ReminderSettingsSection()
            Section(T("Content", "内容")) {
                LabeledContent(T("Version", "版本"), value: lib.version == 0 ? "—" : String(lib.version))
                LabeledContent(T("Chapters", "章节"), value: "\(lib.chapters.count)")
                Button {
                    checking = true
                    Task { await lib.refresh(); await lib.fetchImages(missingOnly: true); checking = false }
                } label: {
                    HStack {
                        Text(T("Check for updates", "检查更新"))
                        if checking { Spacer(); ProgressView() }
                    }
                }
                .disabled(checking)
                if let e = lib.lastError {
                    Text(e).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.cardBackground)
        }
        .appList()
        .navigationTitle(T("Settings", "设置"))
    }
}


/// 设置 › 侧边栏: drag to reorder, switch to hide. ⌘1… and the iPhone tabs (first 4) follow this order.
struct SidebarOrderView: View {
    @Environment(\.tr) private var T
    @AppStorage("sidebar.order") private var orderRaw = ""
    @AppStorage("sidebar.hidden") private var hiddenRaw = ""
    var body: some View {
        let _ = (orderRaw, hiddenRaw)
        List {
            Section {
                ForEach(AppSection.ordered) { s in
                    HStack(spacing: 12) {
                        IconTile(symbol: s.icon, color: s.tint)
                        Text(s.title(T))
                        Spacer()
                        if s != .settings {
                            Toggle("", isOn: Binding(get: { !AppSection.hidden.contains(s) }, set: { v in
                                AppSection.setHidden(s, !v); hiddenRaw = UserDefaults.standard.string(forKey: "sidebar.hidden") ?? ""
                            })).labelsHidden()
                        }
                    }
                }
                .onMove { from, to in
                    var all = AppSection.ordered
                    all.move(fromOffsets: from, toOffset: to)
                    AppSection.saveOrder(all)
                    orderRaw = UserDefaults.standard.string(forKey: "sidebar.order") ?? ""
                }
            } footer: {
                Text(T("Drag to reorder. ⌘1… and the first four tabs on iPhone follow this order.", "拖动调整顺序，开关可隐藏。⌘1… 和 iPhone 底部前四个标签按这个顺序。"))
            }
            .listRowBackground(Color.cardBackground)
            Section {
                Button(T("Reset", "恢复默认")) { orderRaw = ""; hiddenRaw = "" }
            }
            .listRowBackground(Color.cardBackground)
        }
        .environment(\.editMode, .constant(.active))
        .appList()
        .navigationTitle(T("Sidebar", "侧边栏"))
    }
}

/// 设置 › 学科顺序.
struct SubjectOrderView: View {
    @Environment(\.tr) private var T
    @AppStorage("subject.order") private var orderRaw = ""
    var body: some View {
        let _ = orderRaw
        List {
            ForEach(Subject.ordered) { s in Label(T(s.name, s.nameZh), systemImage: s.icon) }
                .onMove { from, to in
                    var all = Subject.ordered
                    all.move(fromOffsets: from, toOffset: to)
                    orderRaw = all.map(\.id).joined(separator: ",")
                }
                .listRowBackground(Color.cardBackground)
        }
        .environment(\.editMode, .constant(.active))
        .appList()
        .navigationTitle(T("Subject order", "学科顺序"))
    }
}
