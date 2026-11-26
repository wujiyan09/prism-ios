import SwiftUI
import AuthenticationServices
import Observation

/// Google sign-in + cross-device sync (last writer wins per record).
/// Local changes are found by diffing against the last synced snapshot, so anything changed offline
/// is pushed the next time sync runs.
@MainActor
@Observable
final class SyncManager: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SyncManager()
    static let base = URL(string: "https://prism-sync.wujiyan2009.workers.dev")!

    var email: String? = UserDefaults.standard.string(forKey: "sync.email")
    var lastSynced: Date? = UserDefaults.standard.object(forKey: "sync.last") as? Date
    var syncing = false
    var error: String?
    var configured: Bool?
    /// Stored (observed) copy of the Keychain token, so views refresh the moment sign-in finishes.
    private var tokenCache: String? = Keychain.get("sync.token")
    var signedIn: Bool { tokenCache != nil }

    private var token: String? {
        get { tokenCache }
        set { if let newValue { Keychain.set("sync.token", newValue) } else { Keychain.delete("sync.token") }; tokenCache = newValue }
    }
    private var cursor: Int {
        get { UserDefaults.standard.integer(forKey: "sync.cursor") }
        set { UserDefaults.standard.set(newValue, forKey: "sync.cursor") }
    }
    private let snapURL: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return d.appendingPathComponent("sync-snapshot.json")
    }()
    private var snapshot: [String: String] {
        get { (try? Data(contentsOf: snapURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
        set { if let d = try? JSONEncoder().encode(newValue) { try? d.write(to: snapURL, options: .atomic) } }
    }
    private var timer: Timer?

    // MARK: sign in

    func checkConfigured() async {
        guard let (d, _) = try? await URLSession.shared.data(from: Self.base.appendingPathComponent("status")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        configured = (o["configured"] as? Bool) ?? false
    }

    func signIn() {
        error = nil
        var c = URLComponents(url: Self.base.appendingPathComponent("auth/start"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "cb", value: "prism://auth")]
        let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "prism") { url, err in
            Task { @MainActor in
                guard let url, let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
                    if let e = err as? ASWebAuthenticationSessionError, e.code == .canceledLogin { return }
                    self.error = err?.localizedDescription; return
                }
                if let e = q.first(where: { $0.name == "error" })?.value { self.error = e; return }
                guard let t = q.first(where: { $0.name == "token" })?.value else { return }
                self.token = t
                self.email = q.first(where: { $0.name == "email" })?.value
                UserDefaults.standard.set(self.email, forKey: "sync.email")
                // first sign-in: merge local data with the account
                self.cursor = 0
                self.snapshot = [:]
                await self.sync()
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        s.start()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    func signOut() {
        token = nil; email = nil; lastSynced = nil; cursor = 0; snapshot = [:]
        for k in ["sync.email", "sync.last"] { UserDefaults.standard.removeObject(forKey: k) }
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in await SyncManager.shared.sync() } }
        Task { await checkConfigured(); await sync() }
    }

    // MARK: sync

    struct Rec: Codable { var k: String; var v: String?; var t: Int64; var d: Bool }
    struct Resp: Codable { var cursor: Int; var records: [Rec] }

    func sync() async {
        guard let token, !syncing else { return }
        syncing = true
        defer { syncing = false }
        let first = cursor == 0 && snapshot.isEmpty
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let cur = SyncRecords.collect()
        let snap = snapshot
        var out: [Rec] = []
        for (k, v) in cur where snap[k] != v {
            // on first merge, local data must not beat what other devices already saved
            out.append(Rec(k: k, v: v, t: first ? SyncRecords.naturalTime(k, v) : now, d: false))
        }
        for k in snap.keys where cur[k] == nil { out.append(Rec(k: k, v: nil, t: now, d: true)) }
        do {
            var req = URLRequest(url: Self.base.appendingPathComponent("sync"))
            req.httpMethod = "POST"
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["since": cursor, "records": out.map { r -> [String: Any] in
                var o: [String: Any] = ["k": r.k, "t": r.t, "d": r.d]; if let v = r.v { o["v"] = v }; return o }])
            req.timeoutInterval = 30
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { signOut(); error = "登录已过期，请重新登录"; return }
            guard code == 200 else { throw URLError(.badServerResponse) }
            let r = try JSONDecoder().decode(Resp.self, from: d)
            var s = snap
            for x in out { s[x.k] = x.d ? nil : x.v }
            let changed = r.records.filter { x in x.d ? s[x.k] != nil || cur[x.k] != nil : cur[x.k] != x.v }
            SyncRecords.apply(changed)
            for x in r.records { s[x.k] = x.d ? nil : x.v }
            snapshot = s
            cursor = r.cursor
            lastSynced = Date()
            UserDefaults.standard.set(lastSynced, forKey: "sync.last")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Maps app data to flat sync records and back.
@MainActor
enum SyncRecords {
    static let settingKeys = ["theme", "lang", "subject.order", "sidebar.order", "sidebar.hidden", "autoNext", "appearance"] + Reading.keys
    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return e }()
    private static func j<T: Encodable>(_ x: T) -> String? { (try? enc.encode(x)).flatMap { String(data: $0, encoding: .utf8) } }
    private static func d<T: Decodable>(_ s: String?, _ t: T.Type) -> T? { s.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }

    static func collect() -> [String: String] {
        let p = ProgressStore.shared
        var o: [String: String] = [:]
        for (k, v) in p.hist { o["h/" + k] = j(v) }
        for r in p.runs { o["run/\(r.t)"] = j(r) }
        for (k, v) in p.sheets { o["sh/" + k] = j(v) }
        for k in p.seen { o["seen/" + k] = "1" }
        for k in p.learned { o["learned/" + k] = "1" }
        for (k, v) in p.marks { o["mark/" + k] = v ? "1" : "0" }
        for (k, v) in p.scores { o["sc/" + k] = "\(v)" }
        o["quiz"] = j(p.quiz)
        for (k, v) in DailyStore.shared.results { o["daily/" + k] = j(v) }
        for e in ExamStore.shared.exams { o["exam/" + e.id.uuidString] = j(e) }
        for (k, v) in InboxStore.shared.items { o["inbox/" + k] = j(v) }
        for (k, v) in ImportStore.shared.collect() { o[k] = v }
        for (k, v) in NoteStore.shared.collect() { o[k] = v }
        for (k, v) in DSStore.shared.collect() { o[k] = v }
        let u = UserDefaults.standard
        for k in settingKeys {
            if let v = u.object(forKey: k) { o["set/" + k] = (v as? Bool).map { $0 ? "true" : "false" } ?? "\(v)" }
        }
        return o
    }

    /// Timestamp used when merging local data into an account for the first time.
    static func naturalTime(_ k: String, _ v: String) -> Int64 {
        if k.hasPrefix("h/"), let e = d(v, HistEntry.self) { return Int64(e.last * 1000) }
        if k.hasPrefix("run/"), let r = d(v, RunRecord.self) { return Int64(r.t * 1000) }
        return 1
    }

    static func apply(_ recs: [SyncManager.Rec]) {
        guard !recs.isEmpty else { return }
        let p = ProgressStore.shared
        var hist = p.hist, runs = p.runs, sheets = p.sheets, seen = p.seen, learned = p.learned, quiz = p.quiz, marks = p.marks, scores = p.scores
        var daily = DailyStore.shared.results
        var exams = ExamStore.shared.exams
        var inbox = InboxStore.shared.items
        func split(_ k: String) -> (String, String) {
            guard let i = k.firstIndex(of: "/") else { return (k, "") }
            return (String(k[..<i]), String(k[k.index(after: i)...]))
        }
        var ds: [(id: String, v: String?, d: Bool)] = []
        for r in recs {
            let (kind, id) = split(r.k)
            switch kind {
            case "ds": ds.append((id, r.v, r.d))
            case "h": hist[id] = r.d ? nil : d(r.v, HistEntry.self)
            case "run":
                runs.removeAll { "\($0.t)" == id }
                if !r.d, let x = d(r.v, RunRecord.self) { runs.append(x) }
            case "sh": sheets[id] = r.d ? nil : d(r.v, SheetState.self)
            case "seen": if r.d { seen.remove(id) } else { seen.insert(id) }
            case "learned": if r.d { learned.remove(id) } else { learned.insert(id) }
            case "mark": marks[id] = r.d ? nil : (r.v == "1")
            case "sc": scores[id] = r.d ? nil : r.v.flatMap { Int($0) }
            case "quiz": if let x = d(r.v, QuizPrefs.self) { quiz = x }
            case "daily": daily[id] = r.d ? nil : d(r.v, DailyResult.self)
            case "inbox": inbox[id] = r.d ? nil : d(r.v, InboxItem.self)
            case "imp": ImportStore.shared.apply(id, r.v, deleted: r.d)
            case "note": NoteStore.shared.apply(id, r.v, deleted: r.d)
            case "exam":
                exams.removeAll { $0.id.uuidString == id }
                if !r.d, let x = d(r.v, Exam.self) { exams.append(x) }
            case "set":
                let u = UserDefaults.standard
                if r.d { u.removeObject(forKey: id) }
                else if let v = r.v {
                    if v == "true" || v == "false" { u.set(v == "true", forKey: id) } else if Reading.keys.contains(id), let x = Double(v) { u.set(x, forKey: id) } else { u.set(v, forKey: id) }
                }
            default: break
            }
        }
        if hist.count != p.hist.count || recs.contains(where: { $0.k.hasPrefix("h/") }) { p.hist = hist }
        if recs.contains(where: { $0.k.hasPrefix("run/") }) { p.runs = Array(runs.sorted { $0.t > $1.t }.prefix(200)) }
        if recs.contains(where: { $0.k.hasPrefix("sh/") }) { p.sheets = sheets }
        if recs.contains(where: { $0.k.hasPrefix("seen/") }) { p.seen = seen }
        if recs.contains(where: { $0.k.hasPrefix("learned/") }) { p.learned = learned }
        if recs.contains(where: { $0.k == "quiz" }) { p.quiz = quiz }
        if recs.contains(where: { $0.k.hasPrefix("mark/") }) { p.marks = marks }
        if recs.contains(where: { $0.k.hasPrefix("sc/") }) { p.scores = scores }
        if recs.contains(where: { $0.k.hasPrefix("daily/") }) { DailyStore.shared.results = daily }
        DSStore.shared.apply(ds)
        if recs.contains(where: { $0.k.hasPrefix("inbox/") }) { InboxStore.shared.items = inbox }
        if recs.contains(where: { $0.k.hasPrefix("exam/") }) { ExamStore.shared.exams = exams.sorted { $0.date < $1.date } }
    }
}

enum Keychain {
    static func set(_ k: String, _ v: String) {
        delete(k)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrAccount: k, kSecValueData: Data(v.utf8),
                    kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock] as CFDictionary, nil)
    }
    static func get(_ k: String) -> String? {
        var out: AnyObject?
        let st = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrAccount: k, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &out)
        guard st == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ k: String) { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: k] as CFDictionary) }
}
