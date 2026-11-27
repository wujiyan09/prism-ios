import SwiftUI

/// ‹ 3/20 › cluster, used by every paged screen. Native buttons; one glass capsule on iOS 26.
struct PageCluster<Extra: View>: View {
    let index: Int
    let count: Int
    let prev: (() -> Void)?
    let next: (() -> Void)?
    @ViewBuilder var counter: () -> Extra
    @Environment(\.tr) private var T
    @State private var owner = UUID()
    private func claim() {
        let h = PadHub.shared
        h.navOwner = owner
        // Re-read state at call time so the pad never holds stale closures.
        h.prev = prev; h.next = next
    }

    var body: some View {
        let row = HStack(spacing: 2) {
            Button { prev?() } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                .disabled(prev == nil)
                .accessibilityLabel(T("Previous", "上一题"))
            counter()
                .font(.subheadline.monospacedDigit())
                .padding(.horizontal, 4)
            Button { next?() } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                .disabled(next == nil)
                .accessibilityLabel(T("Next", "下一题"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .onAppear { claim() }
        .onChange(of: index) { _, _ in claim() }
        .onChange(of: count) { _, _ in claim() }
        // Only clear if no newer cluster took over (split/layout changes re-create the bar).
        .onDisappear { if PadHub.shared.navOwner == owner { PadHub.shared.prev = nil; PadHub.shared.next = nil } }
        if #available(iOS 26.0, *) {
            GlassEffectContainer { row.glassEffect(.regular.interactive(), in: .capsule) }
        } else {
            row.glassBackground(Capsule())
        }
    }
}

extension PageCluster where Extra == Text {
    init(index: Int, count: Int, prev: (() -> Void)?, next: (() -> Void)?) {
        self.index = index; self.count = count; self.prev = prev; self.next = next
        self.counter = { Text("\(index + 1)/\(count)") }
    }
}

extension View {
    /// Pins a page cluster (and optional trailing extra) to the bottom-left of this view.
    func pageNav<B: View>(@ViewBuilder _ bar: () -> B) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 10) { bar(); Spacer(minLength: 0) }
                .padding(.horizontal, 16).padding(.bottom, 10).padding(.top, 4)
        }
    }
}

/// ✓ / ✗ self-marking for one question. key goes into ProgressStore marks/hist (synced).
struct MarkControl: View {
    let key: String
    @Environment(\.tr) private var T
    private var prog: ProgressStore { ProgressStore.shared }
    var body: some View {
        let m = prog.mark(key)
        HStack(spacing: 10) {
            Text(T("Mark", "自评")).font(.subheadline).foregroundStyle(.secondary)
            Button { prog.setMark(key, m == true ? nil : true) } label: {
                Label(T("Correct", "对"), systemImage: m == true ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .glassButton().tint(m == true ? .green : nil)
            Button { prog.setMark(key, m == false ? nil : false) } label: {
                Label(T("Wrong", "错"), systemImage: m == false ? "xmark.circle.fill" : "xmark.circle")
            }
            .glassButton().tint(m == false ? .red : nil)
        }
        .glassGroup()
        .sensoryFeedback(.selection, trigger: m)
    }
}

/// Collapsed answer with a 显示答案 button; resets per question via .id().
struct AnswerReveal<C: View>: View {
    var title: String? = nil
    @ViewBuilder let content: () -> C
    @State private var open = false
    @Environment(\.tr) private var T
    var body: some View {
        if open {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title ?? T("Answer", "答案")).font(.headline)
                    Spacer()
                    Button(T("Hide", "隐藏")) { withAnimation { open = false } }.font(.subheadline)
                }
                content()
            }
        } else {
            Button { withAnimation { open = true } } label: {
                Label(T("Show answer", "显示答案"), systemImage: "eye").frame(maxWidth: .infinity)
            }
            .glassButton()
            .controlSize(.large)
        }
    }
}

/// Written-question sets that were handed in (交卷) but not yet finished self-marking (完成).
/// Their scratch sheet is kept until 完成, even across app launches.
@Observable
final class ReviewStore {
    static let shared = ReviewStore()
    struct Pending: Codable, Hashable { var title: String; var route: String; var t: Double }
    private(set) var pending: [String: Pending] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: "review.pending") }
    }
    init() {
        pending = UserDefaults.standard.data(forKey: "review.pending").flatMap { try? JSONDecoder().decode([String: Pending].self, from: $0) } ?? [:]
    }
    func inReview(_ sheet: String) -> Bool { pending[sheet] != nil }
    /// route: "item:<id>" or "daily:<date>"
    func handIn(_ sheet: String, title: String, route: String) {
        pending[sheet] = Pending(title: title, route: route, t: Date().timeIntervalSince1970)
    }
    /// Leaves review. Daily sheets are kept (deleted with the daily); others ask via `askKeep`.
    func finish(_ sheet: String) {
        guard pending[sheet] != nil else { return }
        pending[sheet] = nil
        if sheet.hasPrefix("daily-") { ScratchStore.shared.keep(sheet) }
        else if ScratchStore.shared.has(sheet) { askKeep = sheet }
    }
    /// Sheet waiting for the 保留草稿纸 / 删除 choice.
    var askKeep: String?
    /// Drops stale entries: a daily is no longer pending once every written part has a score
    /// (or the day is gone), and nothing stays pending for more than 30 days.
    @MainActor func prune() {
        let now = Date().timeIntervalSince1970
        for (k, p) in pending {
            if now - p.t > 30 * 86400 { finish(k); continue }
            if k.hasPrefix("daily-") {
                let date = String(k.dropFirst(6))
                if let done = DailyStore.shared.allMarked(date), done { finish(k) }
            }
        }
    }
}

struct PendingReviewRows: View {
    @Environment(SceneModel.self) private var scene
    @Environment(\.tr) private var T
    let section: AppSection
    private var store: ReviewStore { ReviewStore.shared }
    var body: some View {
        ForEach(store.pending.sorted { $0.value.t > $1.value.t }, id: \.key) { k, p in
            row(k, p)
                .swipeActions { Button(T("Done", "已完成")) { store.finish(k) }.tint(.green) }
                .contextMenu { Button { store.finish(k) } label: { Label(T("Mark as done", "标记为已完成"), systemImage: "checkmark") } }
        }
        .task { store.prune() }
    }
    @ViewBuilder private func row(_ k: String, _ p: ReviewStore.Pending) -> some View {
            Button {
                let r: Route? = p.route.hasPrefix("item:") ? .mathItem(String(p.route.dropFirst(5)))
                    : p.route.hasPrefix("daily:") ? .daily(String(p.route.dropFirst(6))) : nil
                if let r { var path = scene.path(section); path.append(r); scene.paths[section] = path }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checklist.unchecked").foregroundStyle(.orange).frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        Text(T("Waiting for self-marking", "待自评")).font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(T("Mark", "去自评")).font(.subheadline.bold()).foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.cardBackground)
    }
}

// MARK: - Liquid Glass buttons (iOS 26), bordered fallback

extension View {
    /// In-content buttons: native Liquid Glass on iOS 26 (.glass / .glassProminent), bordered before that.
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.glassButton(prominent: true) } else { self.glassButton() }
        }
    }
    /// Groups neighbouring glass buttons so they blend (e.g. ✓ / ✗).
    @ViewBuilder func glassGroup(spacing: CGFloat = 10) -> some View {
        if #available(iOS 26.0, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
    }
}

// MARK: - MC option glass

enum MCState { case idle, selected, correct, wrong }

extension View {
    /// Full-width rounded Liquid Glass option row: selected = accent tint, correct = green, wrong = red.
    @ViewBuilder func mcGlass(_ s: MCState) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let tint: Color? = s == .selected ? .accentColor : s == .correct ? .green : s == .wrong ? .red : nil
        // A clear hit layer on top, so LaTeX / text views inside never swallow the tap: the whole row is the button.
        let hit = self.overlay { Color.clear.contentShape(shape) }.contentShape(shape)
        if #available(iOS 26.0, *) {
            hit.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.35)).interactive() } ?? Glass.regular.interactive(), in: shape)
        } else {
            hit.background((tint?.opacity(0.18) ?? Color.cardBackground), in: shape)
        }
    }
}

/// A / B / C / D in the content font (Times New Roman).
struct MCLetter: View {
    let l: String
    var color: Color = .accentColor
    var body: some View { Text(l).font(Reading.font(18, weight: .bold)).foregroundStyle(color).frame(minWidth: 20, alignment: .leading) }
}

extension View {
    /// After 结算: 保留草稿纸 / 删除 for that set's scratch sheet.
    func scratchKeepPrompt() -> some View { modifier(ScratchKeepPrompt()) }
}
struct ScratchKeepPrompt: ViewModifier {
    @State private var store = ReviewStore.shared
    func body(content: Content) -> some View {
        content.confirmationDialog("草稿纸要保留吗？", isPresented: Binding(get: { store.askKeep != nil }, set: { if !$0 { store.askKeep = nil } }), titleVisibility: .visible) {
            Button("保留草稿纸") { if let k = store.askKeep { ScratchStore.shared.keep(k) }; store.askKeep = nil }
            Button("删除", role: .destructive) { if let k = store.askKeep { ScratchStore.shared.clear(k, force: true) }; store.askKeep = nil }
        }
    }
}
