import SwiftUI
import Observation

@main
struct ICTApp: App {
    @State private var library = Library.shared
    @State private var progress = ProgressStore.shared
    @State private var exams = ExamStore.shared
    @Environment(\.scenePhase) private var phase

    init() { UserDefaults.standard.register(defaults: ["autoNext": true]) }
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(appearance == "light" ? .light : (appearance == "dark" ? .dark : nil))
                .environment(library)
                .environment(progress)
                .environment(exams)
                .task { if !library.loaded { await library.load() }; Reminders.shared.reschedule() }
                .task { Reminders.shared.setUp() }
                .task { SongtiFont.request() }
                .task { await MathContent.shared.sync() }
                .task { await PortalSubmit.shared.flush() }
                .task { SyncManager.shared.start() }
                .onOpenURL { OpenIn.shared.receive($0) }
                .sheet(item: Binding(get: { OpenIn.shared.item }, set: { OpenIn.shared.item = $0 })) { it in
                    NavigationStack { OpenInSheet(item: it) }
                }
                .onChange(of: phase) { _, p in
                    if p == .active { Reminders.shared.reschedule(); Task { await PortalSubmit.shared.flush() } }
                    if p != .inactive { Task { await SyncManager.shared.sync() } }
                }
        }
        .commands {
            SectionCommands()
            PagerCommands()
        }
    }
}

// MARK: - Language

struct Tr {
    let en: Bool
    func callAsFunction(_ e: String, _ z: String) -> String { en ? e : z }
}

private struct TrKey: EnvironmentKey { static let defaultValue = Tr(en: false) }
extension EnvironmentValues {
    var tr: Tr {
        get { self[TrKey.self] }
        set { self[TrKey.self] = newValue }
    }
}

// MARK: - Theme (Color War navy in dark mode, system grouped colours in light mode)

extension Color {
    static var appBackground: Color {
        let th = AppTheme.current
        return Color(uiColor: UIColor { t in
            if t.userInterfaceStyle != .dark { return th.light?.bg ?? .systemGroupedBackground }
            return th.colors?.bg ?? .systemGroupedBackground
        })
    }
    static var cardBackground: Color {
        let th = AppTheme.current
        return Color(uiColor: UIColor { t in
            if t.userInterfaceStyle != .dark { return th.light?.card ?? .secondarySystemGroupedBackground }
            return th.colors?.card ?? .secondarySystemGroupedBackground
        })
    }
    static let good = Color.green
    static let bad = Color.red
}

extension View {
    /// Card-style grouped list on the app background.
    func appList() -> some View {
        self.scrollContentBackground(.hidden).appScreen().softEdges()
    }
    /// Same background as build-10 (only on content pages).
    func appScreen() -> some View {
        self.background(Color.appBackground)
    }
    /// iOS 26 soft scroll edge effect on every edge.
    @ViewBuilder func softEdges() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
    func card() -> some View {
        self.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Sections & navigation

enum AppSection: String, CaseIterable, Identifiable, Hashable, Codable {
    case daily, learn, dse, quiz, plan, tools, progress, inbox, notes, settings
    var id: String { rawValue }
    func title(_ T: Tr) -> String {
        switch self {
        case .learn: return T("Textbook", "课本")
        case .dse: return T("Past Papers", "真题")
        case .quiz: return T("Quiz", "测验")
        case .plan: return T("Exam Plan", "备考计划")
        case .daily: return T("Daily Practice", "每日练习")
        case .tools: return T("Tools", "工具")
        case .progress: return T("Progress", "进度")
        case .inbox: return T("Inbox", "收件箱")
        case .notes: return T("Notes", "笔记")
        case .settings: return T("Settings", "设置")
        }
    }
    var icon: String {
        switch self {
        case .learn: return "books.vertical"
        case .dse: return "doc.text"
        case .quiz: return "checklist"
        case .plan: return "calendar"
        case .daily: return "pencil.and.list.clipboard"
        case .tools: return "wrench.and.screwdriver"
        case .progress: return "chart.bar"
        case .inbox: return "tray"
        case .notes: return "note.text"
        case .settings: return "gearshape"
        }
    }
    /// Sections that get their own tab in compact width; the rest live under "More".
    /// Sidebar order Sam chose (设置 › 侧边栏, or 编辑 in the sidebar). Synced as "sidebar.order".
    static var ordered: [AppSection] {
        let ids = (UserDefaults.standard.string(forKey: "sidebar.order") ?? "").split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        var out: [AppSection] = []
        for s in ids where !out.contains(s) { out.append(s) }
        for s in allCases where !out.contains(s) { out.append(s) }
        return out
    }
    static var hidden: Set<AppSection> {
        Set((UserDefaults.standard.string(forKey: "sidebar.hidden") ?? "").split(separator: ",").compactMap { AppSection(rawValue: String($0)) })
            .subtracting([.settings])
    }
    /// What the sidebar shows, in order (设置 can't be hidden).
    static var visible: [AppSection] { ordered.filter { !hidden.contains($0) } }
    static func saveOrder(_ s: [AppSection]) { UserDefaults.standard.set(s.map(\.rawValue).joined(separator: ","), forKey: "sidebar.order") }
    static func setHidden(_ s: AppSection, _ h: Bool) {
        var set = hidden; if h { set.insert(s) } else { set.remove(s) }
        UserDefaults.standard.set(set.map(\.rawValue).sorted().joined(separator: ","), forKey: "sidebar.hidden")
    }
    /// Compact width: the first 4 visible sections get tabs; the rest live under "More".
    static var compactTabs: [AppSection] { Array(visible.filter { $0 != .settings }.prefix(4)) }
    static var moreSections: [AppSection] { visible.filter { !compactTabs.contains($0) } }
    /// Sections whose root starts with a subject list.
    var subjectFirst: Bool { [.learn, .dse, .quiz, .progress].contains(self) }
    var tint: Color {
        switch self {
        case .learn: return .blue
        case .dse: return .orange
        case .quiz: return .green
        case .plan: return .red
        case .daily: return .pink
        case .tools: return .indigo
        case .progress: return .teal
        case .inbox: return .brown
        case .notes: return .yellow
        case .settings: return .gray
        }
    }
    /// ⌘1… follow the sidebar order; 设置 stays ⌘,.
    var shortcut: KeyEquivalent? {
        if self == .settings { return "," }
        guard let i = AppSection.visible.filter({ $0 != .settings }).firstIndex(of: self), i < 9 else { return nil }
        return KeyEquivalent(Character(String(i + 1)))
    }
}

enum Route: Hashable {
    case chapter(String)
    case cards(String, Int)
    case practical(String)
    case year(String)
    case tool(ToolKind)
    case chapterPicker
    case exam(UUID)
    case subject(AppSection, String)
    case book(String)
    case section(AppSection)
    case paper2(String)
    case pdf(URL, String)
    case mathBook(String)
    case mathChapter(String)
    case mathCards(String, Int)
    case mathItem(String)
    case mathSets(String)
    case mathQuiz(MathQuizSpec)
    case daily(String)
    case dailyRun(String)
    case mathPaper(String)
    case ppSet(String)
}

enum ToolKind: String, CaseIterable, Hashable, Identifiable {
    case base, twos, subnet, sql, trace
    var id: String { rawValue }
    func title(_ T: Tr) -> String {
        switch self {
        case .base: return T("Number Bases", "进制转换")
        case .twos: return T("Two's Complement", "补码与溢出")
        case .subnet: return T("Subnet Calculator", "子网计算")
        case .sql: return T("SQL Playground", "SQL 练习场")
        case .trace: return T("Trace Tables", "算法追踪")
        }
    }
    func subtitle(_ T: Tr) -> String {
        switch self {
        case .base: return T("Decimal, binary, octal and hex", "十进制、二进制、八进制、十六进制互换")
        case .twos: return T("8-bit two's complement, addition and overflow", "8 位补码、加法和溢出检查")
        case .subnet: return T("Mask, network, broadcast and host range", "求子网掩码、网络地址、广播地址和主机范围")
        case .sql: return T("Run any SQL on a sample database", "在示例数据库上运行任何 SQL")
        case .trace: return T("Remainder method, bubble sort, searches", "取余法、冒泡排序、二分和线性查找")
        }
    }
    var icon: String {
        switch self {
        case .base: return "number"
        case .twos: return "plusminus"
        case .subnet: return "network"
        case .sql: return "tablecells"
        case .trace: return "list.number"
        }
    }
}

/// Per-window state: current section, navigation paths and the active practice session.
@Observable
final class SceneModel {
    var section: AppSection = .learn
    var paths: [AppSection: NavigationPath] = [:]
    var session: Session? {
        didSet {
            guard let old = oldValue, old !== session else { return }
            let started = old.keys.indices.contains { old.answered($0, Library.shared.items[old.keys[$0]]) }
            if !old.submitted && started {
                RecentStore.shared.sessions[section] = old
                RecentStore.shared.note(section, .session, old.title,
                                        "\(old.index + 1)/\(old.keys.count) · " + (UserDefaults.standard.string(forKey: "lang") == "en" ? "unfinished" : "未交卷"))
            } else if RecentStore.shared.sessions[section] === old {
                RecentStore.shared.sessions[section] = nil
                if RecentStore.shared.entries[section.rawValue]?.target == .session { RecentStore.shared.entries[section.rawValue] = nil }
            }
        }
    }

    func path(_ s: AppSection) -> NavigationPath { paths[s] ?? NavigationPath() }

    var cardTask: (exam: UUID, task: String, chapter: String)?

    func start(_ title: String, _ keys: [String], planTask: (UUID, String)? = nil) {
        guard !keys.isEmpty else { return }
        let s = Session(title: title, keys: keys)
        s.planTask = planTask
        session = s
    }

    func open(_ s: AppSection, _ route: Route? = nil) {
        section = s
        if let route {
            var p = NavigationPath()
            p.append(route)
            paths[s] = p
        }
    }
}

struct SectionSelectionKey: FocusedValueKey { typealias Value = Binding<AppSection> }
extension FocusedValues {
    var sectionSelection: Binding<AppSection>? {
        get { self[SectionSelectionKey.self] }
        set { self[SectionSelectionKey.self] = newValue }
    }
}

struct SectionCommands: Commands {
    @FocusedValue(\.sectionSelection) private var focused
    private var selection: Binding<AppSection>? { focused ?? KeyRouter.shared.section }
    @AppStorage("lang") private var lang = "zh"
    @AppStorage("sidebar.order") private var orderRaw = ""
    @AppStorage("sidebar.hidden") private var hiddenRaw = ""
    var body: some Commands {
        CommandMenu(lang == "en" ? "Go" : "前往") {
            let _ = (orderRaw, hiddenRaw)
            ForEach(AppSection.visible) { s in
                if let k = s.shortcut {
                    Button(s.title(Tr(en: lang == "en"))) { selection?.wrappedValue = s }
                        .keyboardShortcut(k, modifiers: .command)
                } else {
                    Button(s.title(Tr(en: lang == "en"))) { selection?.wrappedValue = s }
                }
            }
        }
    }
}


// MARK: - Background theme (Settings)

enum AppTheme: String, CaseIterable, Identifiable {
    case navy, black, graphite, forest, plum, system
    var id: String { rawValue }
    static var current: AppTheme { AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .navy }

    private static func rgb(_ h: UInt32) -> UIColor {
        UIColor(red: CGFloat(h >> 16 & 0xFF) / 255, green: CGFloat(h >> 8 & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
    }
    /// Dark-mode background and card colours; nil = system default.
    var colors: (bg: UIColor, card: UIColor)? {
        switch self {
        case .navy: return (Self.rgb(0x060E24), Self.rgb(0x121D3D))
        case .black: return (Self.rgb(0x000000), Self.rgb(0x1C1C1E))
        case .graphite: return (Self.rgb(0x141518), Self.rgb(0x25272C))
        case .forest: return (Self.rgb(0x07180F), Self.rgb(0x13301F))
        case .plum: return (Self.rgb(0x170B22), Self.rgb(0x2A1840))
        case .system: return nil
        }
    }
    /// Light-mode counterparts.
    var light: (bg: UIColor, card: UIColor)? {
        switch self {
        case .navy: return (Self.rgb(0xF5F7FB), Self.rgb(0xFFFFFF))
        case .black: return (Self.rgb(0xF2F2F7), Self.rgb(0xFFFFFF))
        case .graphite: return (Self.rgb(0xF1F2F4), Self.rgb(0xFFFFFF))
        case .forest: return (Self.rgb(0xF1F7F3), Self.rgb(0xFFFFFF))
        case .plum: return (Self.rgb(0xF7F3FA), Self.rgb(0xFFFFFF))
        case .system: return nil
        }
    }
    func title(_ T: Tr) -> String {
        switch self {
        case .navy: return T("Navy (default)", "深海蓝（默认）")
        case .black: return T("Black", "纯黑")
        case .graphite: return T("Graphite", "石墨灰")
        case .forest: return T("Forest", "森林绿")
        case .plum: return T("Plum", "梅紫")
        case .system: return T("System default", "系统默认")
        }
    }
    var swatch: Color { Color(uiColor: colors?.bg ?? .systemGroupedBackground) }
}
