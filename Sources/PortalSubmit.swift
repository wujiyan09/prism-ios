import SwiftUI
import Observation

/// Sends Maths portal MC set results to the school's marking backend on 交卷 (same format as the portal's own "Send result").
@Observable
final class PortalSubmit {
    static let shared = PortalSubmit()
    static let endpoint = URL(string: Secrets.portalURL) ?? URL(string: "https://example.invalid")!
    static let classes = ["S5A", "S5G", "S5H", "S5K", "S5U"]

    struct Payload: Codable, Hashable {
        let v: Int
        let quizId: String
        let cls: String
        let classNo: Int
        let answers: [Int]
        let isDebug: Bool
        let submissionId: String
    }
    struct Pending: Codable, Hashable { let attempt: String; let payload: Payload }
    enum Status: Codable, Hashable { case sending, sent(Int, Int), queued(String) }

    var cls: String { didSet { UserDefaults.standard.set(cls, forKey: "portal.cls") } }
    var classNo: Int { didSet { UserDefaults.standard.set(classNo, forKey: "portal.no") } }
    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "portal.on") } }
    var ready: Bool { Self.classes.contains(cls) && (1...40).contains(classNo) }
    private(set) var status: [String: Status] = [:]
    private var queue: [Pending] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(queue), forKey: "portal.queue") }
    }
    private var flushing = false

    init() {
        let u = UserDefaults.standard
        cls = u.string(forKey: "portal.cls") ?? ""
        classNo = u.integer(forKey: "portal.no")
        enabled = u.object(forKey: "portal.on") as? Bool ?? true
        queue = (u.data(forKey: "portal.queue")).flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? []
        status = (u.data(forKey: "portal.status")).flatMap { try? JSONDecoder().decode([String: Status].self, from: $0) } ?? [:]
    }

    private func setStatus(_ a: String, _ s: Status) {
        status[a] = s
        UserDefaults.standard.set(try? JSONEncoder().encode(status), forKey: "portal.status")
    }

    /// Called once per attempt on 交卷. answers = 1/0 per portal question, in portal order.
    @MainActor
    func submit(setID: String, attempt: String, answers: [Int]) {
        guard enabled, ready, status[attempt] == nil, !queue.contains(where: { $0.attempt == attempt }) else { return }
        let p = Payload(v: 1, quizId: "s5-mc-" + setID.lowercased(), cls: cls, classNo: classNo, answers: answers,
                        isDebug: false, submissionId: "\(attempt)-\(cls)-\(classNo)")
        queue.append(Pending(attempt: attempt, payload: p))
        Task { await flush() }
    }

    /// Sends anything waiting (also retried at launch / foreground).
    @MainActor
    func flush() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        for item in queue {
            setStatus(item.attempt, .sending)
            do {
                var r = URLRequest(url: Self.endpoint)
                r.httpMethod = "POST"
                r.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
                r.httpBody = try JSONEncoder().encode(item.payload)
                r.timeoutInterval = 30
                let (d, _) = try await URLSession.shared.data(for: r)
                let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any]
                guard obj?["ok"] as? Bool == true else {
                    throw NSError(domain: "portal", code: 1, userInfo: [NSLocalizedDescriptionKey: (obj?["error"] as? String) ?? "rejected"])
                }
                let score = (obj?["score"] as? Int) ?? (obj?["score"] as? Double).map { Int($0) } ?? item.payload.answers.reduce(0, +)
                setStatus(item.attempt, .sent(score, item.payload.answers.count))
                queue.removeAll { $0.attempt == item.attempt }
            } catch {
                setStatus(item.attempt, .queued(error.localizedDescription))
            }
        }
    }
}

struct PortalStatusView: View {
    let attempt: String
    @Environment(\.tr) private var T
    private var p: PortalSubmit { PortalSubmit.shared }
    var body: some View {
        switch p.status[attempt] {
        case .sending?:
            Label(T("Sending to school site…", "正在提交到学校网站…"), systemImage: "arrow.up.circle").foregroundStyle(.secondary)
        case .sent(let s, let n)?:
            Label(T("Submitted \(s)/\(n)", "已提交 \(s)/\(n)"), systemImage: "checkmark.icloud").foregroundStyle(.green)
        case .queued?:
            VStack(spacing: 4) {
                Label(T("Not sent yet; will retry", "暂未提交，稍后自动重试"), systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
                Button(T("Retry now", "立即重试")) { Task { await p.flush() } }.font(.caption)
            }
        case nil:
            if !p.ready && p.enabled {
                Text(T("Set class and number in Settings to submit to the school site.", "在设置里填班别和学号，就能自动提交到学校网站。")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PortalSettingsSection: View {
    @Environment(\.tr) private var T
    @State private var p = PortalSubmit.shared
    var body: some View {
        Section {
            Toggle(T("Auto-submit Maths MC sets", "交卷时自动提交数学选择题"), isOn: $p.enabled)
            Picker(T("Class", "班别"), selection: $p.cls) {
                Text("—").tag("")
                ForEach(PortalSubmit.classes, id: \.self) { Text($0).tag($0) }
            }
            Stepper(value: $p.classNo, in: 0...40) {
                LabeledContent(T("Class number", "学号"), value: p.classNo == 0 ? "—" : "\(p.classNo)")
            }
        } header: {
            Text(T("School site submission", "学校网站提交"))
        } footer: {
            Text(T("Results of the Maths portal sets (Work / Challenge) go to your teacher when you finish. Custom quizzes are not sent.",
                   "完成数学网站的练习套（Work / Challenge）后，成绩会提交给老师。自选范围测验不会提交。"))
        }
        .listRowBackground(Color.cardBackground)
    }
}
