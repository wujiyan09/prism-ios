import SwiftUI
import Observation

/// "刚才在学": the last place visited in each section, saved on device.
enum RecentTarget: Codable, Hashable {
    case cards(String, Int)
    case chapter(String)
    case practical(String)
    case year(String)
    case paper2(String)
    case pdf(String, String)
    case exam(UUID)
    case tool(String)
    case mathCards(String, Int)
    case mathItem(String)
    case mathQuiz(MathQuizSpec)
    case daily(String)
    case session            // a practice session still open in this run of the app
}

struct RecentEntry: Codable, Hashable {
    var target: RecentTarget
    var title: String
    var detail: String
    var time: Double = Date().timeIntervalSince1970
}

@Observable
final class RecentStore {
    static let shared = RecentStore()
    var entries: [String: RecentEntry] = [:] { didSet { save() } }
    /// Unfinished practice sessions, by section (memory only).
    var sessions: [AppSection: Session] = [:]

    private let key = "recent.v1"
    init() {
        if let d = UserDefaults.standard.data(forKey: key), let e = try? JSONDecoder().decode([String: RecentEntry].self, from: d) {
            entries = e.filter { $0.value.target != .session }
        }
    }
    private func save() {
        let keep = entries.filter { $0.value.target != .session }
        if let d = try? JSONEncoder().encode(keep) { UserDefaults.standard.set(d, forKey: key) }
    }

    func note(_ s: AppSection, _ target: RecentTarget, _ title: String, _ detail: String = "") {
        let e = RecentEntry(target: target, title: title, detail: detail)
        if entries[s.rawValue]?.target == target && entries[s.rawValue]?.title == title && entries[s.rawValue]?.detail == detail { return }
        entries[s.rawValue] = e
        // Also remember it per subject, so each subject page shows only its own last item.
        if let subj = Self.subject(of: target) { entries[s.rawValue + "." + subj] = e }
    }

    /// Which subject a target belongs to (nil = not subject-specific).
    static func subject(of t: RecentTarget) -> String? {
        func m(_ chapterID: String) -> String { (MathLibrary.shared.chapter(chapterID)?.isZh ?? chapterID.hasPrefix("z-")) ? "zh" : "math" }
        switch t {
        case .cards, .chapter, .practical, .year, .paper2: return "ict"
        case .mathCards(let c, _): return m(c)
        case .mathItem(let id):
            if let hit = MathLibrary.shared.item(id) { return hit.0.isZh ? "zh" : "math" }
            return nil
        case .mathQuiz(let spec):
            switch spec {
            case .set(let id): return id.hasPrefix("z-") ? "zh" : "math"
            case .custom(let ids, _, _): return ids.first.map { m(String($0.split(separator: ":").first ?? "")) }
            }
        default: return nil
        }
    }

    func entry(_ s: AppSection, subject: String? = nil) -> RecentEntry? {
        guard let e = entries[subject.map { s.rawValue + "." + $0 } ?? s.rawValue] else { return nil }
        if e.target == .session, sessions[s] == nil { return nil }
        return e
    }
}

/// Top-of-section card that resumes the last thing visited.
struct RecentSection: View {
    let section: AppSection
    var subject: String? = nil
    @Environment(SceneModel.self) private var scene
    @Environment(\.tr) private var T
    @State private var store = RecentStore.shared

    var body: some View {
        if !ReviewStore.shared.pending.isEmpty && (section == .learn || section == .daily) {
            Section(T("Waiting for self-marking", "待自评")) { PendingReviewRows(section: section) }
        }
        if let e = store.entry(section, subject: subject) {
            Section {
                Button { resume(e) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon(e.target))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(section.tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                            if !e.detail.isEmpty { Text(e.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 8)
                        Text(T("Resume", "继续")).font(.subheadline.bold()).foregroundStyle(Color.accentColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.cardBackground)
            } header: {
                Text(T("Just now", "刚才在学"))
            }
        }
    }

    private func icon(_ t: RecentTarget) -> String {
        switch t {
        case .cards: return "rectangle.stack"
        case .chapter: return "book"
        case .practical: return "chevron.left.forwardslash.chevron.right"
        case .year, .pdf, .paper2: return "doc.text"
        case .exam: return "calendar"
        case .tool: return "wrench.and.screwdriver"
        case .mathCards: return "function"
        case .mathItem: return "pencil.and.scribble"
        case .mathQuiz: return "checklist"
        case .daily: return "pencil.and.list.clipboard"
        case .session: return "play.fill"
        }
    }

    private func resume(_ e: RecentEntry) {
        let r: Route?
        switch e.target {
        case .cards(let c, let i): r = .cards(c, i)
        case .chapter(let c): r = .chapter(c)
        case .practical(let k): r = .practical(k)
        case .year(let y): r = .year(y)
        case .paper2(let c): r = .paper2(c)
        case .pdf(let u, let t): r = URL(string: u).map { .pdf($0, t) }
        case .exam(let id): r = .exam(id)
        case .tool(let k): r = ToolKind(rawValue: k).map { .tool($0) }
        case .mathCards(let c, let i): r = .mathCards(c, i)
        case .mathItem(let i): r = .mathItem(i)
        case .mathQuiz(let q): r = .mathQuiz(q)
        case .daily(let d): r = .daily(d)
        case .session:
            if let s = store.sessions[section] { scene.session = s }
            r = nil
        }
        if let r {
            var p = scene.path(section)
            p.append(r)
            scene.paths[section] = p
        }
    }
}

private struct NoteRecent: ViewModifier {
    let target: RecentTarget
    let title: String
    let detail: String
    @Environment(SceneModel.self) private var scene
    func body(content: Content) -> some View {
        content
            .onAppear { RecentStore.shared.note(scene.section, target, title, detail) }
            .onChange(of: target) { _, t in RecentStore.shared.note(scene.section, t, title, detail) }
    }
}
extension View {
    func noteRecent(_ target: RecentTarget, _ title: String, _ detail: String = "") -> some View {
        modifier(NoteRecent(target: target, title: title, detail: detail))
    }
}
