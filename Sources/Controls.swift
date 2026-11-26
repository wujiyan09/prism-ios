import SwiftUI

/// ‹ 3/20 › cluster, used by every paged screen. Native buttons; one glass capsule on iOS 26.
struct PageCluster<Extra: View>: View {
    let index: Int
    let count: Int
    let prev: (() -> Void)?
    let next: (() -> Void)?
    @ViewBuilder var counter: () -> Extra
    @Environment(\.tr) private var T

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
        if #available(iOS 26.0, *) {
            GlassEffectContainer { row.glassEffect(.regular.interactive(), in: .capsule) }
        } else {
            row.background(.regularMaterial, in: Capsule())
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
            .buttonStyle(.bordered).tint(m == true ? .green : .secondary)
            Button { prog.setMark(key, m == false ? nil : false) } label: {
                Label(T("Wrong", "错"), systemImage: m == false ? "xmark.circle.fill" : "xmark.circle")
            }
            .buttonStyle(.bordered).tint(m == false ? .red : .secondary)
        }
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
            .buttonStyle(.bordered)
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
    func finish(_ sheet: String) {
        pending[sheet] = nil
        ScratchStore.shared.clear(sheet, force: true)
    }
}

struct PendingReviewRows: View {
    @Environment(SceneModel.self) private var scene
    @Environment(\.tr) private var T
    let section: AppSection
    private var store: ReviewStore { ReviewStore.shared }
    var body: some View {
        ForEach(store.pending.sorted { $0.value.t > $1.value.t }, id: \.key) { k, p in
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
}
