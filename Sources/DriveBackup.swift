import SwiftUI
import AuthenticationServices
import CryptoKit
import Observation

/// Google 云端硬盘备份: mirrors the app's own data (notes, PDF handwriting, scratch paper, imports, records, settings)
/// into a "Prism 备份" folder in the user's Drive. drive.file scope: the app only sees files it created.
/// Only changed files upload (SHA-256 manifest). 从备份恢复 downloads everything back.
@MainActor
@Observable
final class DriveBackup: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = DriveBackup()

    static let clientID = "604525247700-nif26q5j8d3o7ph6rud43igc836g4pv7.apps.googleusercontent.com"
    static let scheme = "com.googleusercontent.apps.604525247700-nif26q5j8d3o7ph6rud43igc836g4pv7"
    static var redirect: String { scheme + ":/oauth2redirect" }
    static let folderName = "Prism 备份"
    /// Application Support folders that are re-downloadable content, not user data.
    static let skip: Set<String> = ["mathdata", "sync-snapshot.json", "drive-manifest.json"]

    var email: String? = UserDefaults.standard.string(forKey: "drive.email")
    var lastBackup: Date? = UserDefaults.standard.object(forKey: "drive.last") as? Date
    var auto: Bool = UserDefaults.standard.object(forKey: "drive.auto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(auto, forKey: "drive.auto") }
    }
    var busy = false
    var status: String?
    var error: String?
    private var refreshCache: String? = Keychain.get("drive.refresh")
    var signedIn: Bool { refreshCache != nil }
    private var access: (String, Date)?
    private var session: ASWebAuthenticationSession?
    private var timer: Timer?

    private var refresh: String? {
        get { refreshCache }
        set { if let newValue { Keychain.set("drive.refresh", newValue) } else { Keychain.delete("drive.refresh") }; refreshCache = newValue }
    }

    private static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    private static var manifestURL: URL { root.appendingPathComponent("drive-manifest.json") }
    /// path → (Drive file id, sha256)
    private struct Entry: Codable { var id: String; var h: String }
    private var manifest: [String: Entry] {
        get { (try? Data(contentsOf: Self.manifestURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:] }
        set { if let d = try? JSONEncoder().encode(newValue) { try? d.write(to: Self.manifestURL, options: .atomic) } }
    }
    private var folderID: String? {
        get { UserDefaults.standard.string(forKey: "drive.folder") }
        set { UserDefaults.standard.set(newValue, forKey: "drive.folder") }
    }

    // MARK: sign in (OAuth 2.0 + PKCE, iOS client: no secret)

    func signIn() {
        error = nil
        let verifier = Self.randomURLSafe(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "https://www.googleapis.com/auth/drive.file openid email"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
        ]
        let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: Self.scheme) { url, err in
            Task { @MainActor in
                self.session = nil
                guard let url, let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
                    if let e = err as? ASWebAuthenticationSessionError, e.code == .canceledLogin { return }
                    self.error = err?.localizedDescription; return
                }
                if let e = q.first(where: { $0.name == "error" })?.value { self.error = e == "access_denied" ? "没有授权" : e; return }
                guard let code = q.first(where: { $0.name == "code" })?.value else { return }
                await self.exchange(code: code, verifier: verifier)
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        s.start()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            PadHub.mainWindow ?? ASPresentationAnchor()
        }
    }

    private func exchange(code: String, verifier: String) async {
        do {
            let o = try await tokenRequest(["code": code, "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": Self.redirect])
            guard let at = o["access_token"] as? String else { throw Fail("登录失败") }
            if let rt = o["refresh_token"] as? String { refresh = rt }
            access = (at, Date().addingTimeInterval(Double(o["expires_in"] as? Int ?? 3600) - 60))
            if let idt = o["id_token"] as? String, let e = Self.email(fromIDToken: idt) { email = e; UserDefaults.standard.set(e, forKey: "drive.email") }
            folderID = nil
            await backup()
        } catch { self.error = error.localizedDescription }
    }

    func signOut() {
        refresh = nil; access = nil; email = nil; lastBackup = nil; folderID = nil
        try? FileManager.default.removeItem(at: Self.manifestURL)
        for k in ["drive.email", "drive.last"] { UserDefaults.standard.removeObject(forKey: k) }
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var f = form; f["client_id"] = Self.clientID
        r.httpBody = f.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&").data(using: .utf8)
        let (d, resp) = try await URLSession.shared.data(for: r)
        let o = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        if (resp as? HTTPURLResponse)?.statusCode != 200 {
            if (o["error"] as? String) == "invalid_grant" { signOut(); throw Fail("登录已过期，请重新登录 Google") }
            throw Fail((o["error_description"] as? String) ?? "Google 登录出错")
        }
        return o
    }

    private func token() async throws -> String {
        if let (t, exp) = access, exp > Date() { return t }
        guard let rt = refresh else { throw Fail("请先登录 Google") }
        let o = try await tokenRequest(["refresh_token": rt, "grant_type": "refresh_token"])
        guard let at = o["access_token"] as? String else { throw Fail("Google 登录出错") }
        access = (at, Date().addingTimeInterval(Double(o["expires_in"] as? Int ?? 3600) - 60))
        return at
    }

    // MARK: Drive calls

    private func call(_ url: String, method: String = "GET", body: Data? = nil, type: String? = nil) async throws -> Data {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        r.timeoutInterval = 120
        r.setValue("Bearer " + (try await token()), forHTTPHeaderField: "Authorization")
        if let type { r.setValue(type, forHTTPHeaderField: "Content-Type") }
        r.httpBody = body
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { access = nil }
        guard (200..<300).contains(code) else {
            let m = ((try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            throw Fail(m ?? "云端硬盘出错（\(code)）")
        }
        return d
    }

    private func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+'"))) ?? s }

    private func ensureFolder() async throws -> String {
        if let f = folderID { return f }
        let query = "name = '\(Self.folderName)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        let d = try await call("https://www.googleapis.com/drive/v3/files?q=\(q(query))&fields=files(id)&spaces=drive")
        if let id = ((try JSONSerialization.jsonObject(with: d) as? [String: Any])?["files"] as? [[String: Any]])?.first?["id"] as? String {
            folderID = id; return id
        }
        let meta = try JSONSerialization.data(withJSONObject: ["name": Self.folderName, "mimeType": "application/vnd.google-apps.folder"])
        let c = try await call("https://www.googleapis.com/drive/v3/files?fields=id", method: "POST", body: meta, type: "application/json")
        guard let id = (try JSONSerialization.jsonObject(with: c) as? [String: Any])?["id"] as? String else { throw Fail("建不了备份文件夹") }
        folderID = id; return id
    }

    private func upload(path: String, data: Data, existing: String?, folder: String) async throws -> String {
        let boundary = "prism-" + UUID().uuidString
        var meta: [String: Any] = ["name": path, "appProperties": ["p": path]]
        if existing == nil { meta["parents"] = [folder] }
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(try JSONSerialization.data(withJSONObject: meta))
        body.append("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let url = existing.map { "https://www.googleapis.com/upload/drive/v3/files/\($0)?uploadType=multipart&fields=id" }
            ?? "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id"
        do {
            let d = try await call(url, method: existing == nil ? "POST" : "PATCH", body: body, type: "multipart/related; boundary=\(boundary)")
            guard let id = (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["id"] as? String else { throw Fail("上传失败") }
            return id
        } catch where existing != nil {
            // The file was deleted in Drive: upload it again.
            return try await upload(path: path, data: data, existing: nil, folder: folder)
        }
    }

    // MARK: what to back up

    /// Relative path → file URL, for every user-data file under Application Support (+ settings as one file).
    private static func localFiles() -> [String: URL] {
        var out: [String: URL] = [:]
        let fm = FileManager.default
        let base = root.standardizedFileURL.path
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return out }
        for case let u as URL in e {
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let top = rel.split(separator: "/").first, skip.contains(String(top)) { if (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile != true { e.skipDescendants() }; continue }
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { out[rel] = u }
        }
        return out
    }
    private static let settingsPath = "_settings.plist"
    private static func settingsData() -> Data? {
        let all = UserDefaults.standard.dictionaryRepresentation()
        let mine = all.filter { k, _ in !k.hasPrefix("Apple") && !k.hasPrefix("NS") && !k.hasPrefix("com.apple") && !k.hasPrefix("drive.") && !k.hasPrefix("sync.") && !k.hasPrefix("PK") && !k.hasPrefix("AK") && !k.hasPrefix("INNext") }
        return try? PropertyListSerialization.data(fromPropertyList: mine, format: .binary, options: 0)
    }

    // MARK: backup / restore

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in Task { @MainActor in DriveBackup.shared.autoBackup() } }
    }
    /// On app background and every 10 minutes, when 自动备份 is on.
    func autoBackup() {
        guard signedIn, auto, !busy else { return }
        if let l = lastBackup, Date().timeIntervalSince(l) < 120 { return }
        Task { await backup() }
    }

    func backup() async {
        guard signedIn, !busy else { return }
        busy = true; error = nil
        defer { busy = false; status = nil }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "drive-backup")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        do {
            let folder = try await ensureFolder()
            var man = manifest
            var files: [(String, () -> Data?)] = Self.localFiles().map { p, u in (p, { try? Data(contentsOf: u) }) }
            files.append((Self.settingsPath, { Self.settingsData() }))
            var done = 0
            for (path, read) in files {
                guard let data = read() else { continue }
                let h = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if man[path]?.h == h { continue }
                done += 1
                status = "正在上传 \(done) 个文件…"
                let id = try await upload(path: path, data: data, existing: man[path]?.id, folder: folder)
                man[path] = Entry(id: id, h: h)
                if done % 10 == 0 { manifest = man }
            }
            // Deleted locally: delete the copy too.
            let present = Set(files.map(\.0))
            for (path, e) in man where !present.contains(path) {
                _ = try? await call("https://www.googleapis.com/drive/v3/files/\(e.id)", method: "DELETE")
                man[path] = nil
            }
            manifest = man
            lastBackup = Date()
            UserDefaults.standard.set(lastBackup, forKey: "drive.last")
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Downloads every file in the backup folder and overwrites the local copies. The app must restart afterwards.
    func restore() async -> Bool {
        guard signedIn, !busy else { return false }
        busy = true; error = nil
        defer { busy = false; status = nil }
        do {
            let folder = try await ensureFolder()
            var all: [[String: Any]] = []
            var pageToken: String?
            repeat {
                var url = "https://www.googleapis.com/drive/v3/files?q=\(q("'\(folder)' in parents and trashed = false"))&fields=nextPageToken,files(id,name,appProperties)&pageSize=1000"
                if let t = pageToken { url += "&pageToken=\(q(t))" }
                let d = try await call(url)
                let o = try JSONSerialization.jsonObject(with: d) as? [String: Any]
                all += (o?["files"] as? [[String: Any]]) ?? []
                pageToken = o?["nextPageToken"] as? String
            } while pageToken != nil
            guard !all.isEmpty else { throw Fail("云端硬盘里还没有备份") }
            var man: [String: Entry] = [:]
            for (i, f) in all.enumerated() {
                guard let id = f["id"] as? String else { continue }
                let path = ((f["appProperties"] as? [String: String])?["p"]) ?? (f["name"] as? String ?? "")
                guard !path.isEmpty, !path.contains("..") else { continue }
                status = "正在下载 \(i + 1)/\(all.count)…"
                let data = try await call("https://www.googleapis.com/drive/v3/files/\(id)?alt=media")
                if path == Self.settingsPath {
                    if let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                        for (k, v) in dict { UserDefaults.standard.set(v, forKey: k) }
                    }
                } else {
                    let u = Self.root.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: u, options: .atomic)
                }
                man[path] = Entry(id: id, h: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            }
            manifest = man
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: helpers

    struct Fail: LocalizedError { let m: String; init(_ m: String) { self.m = m }; var errorDescription: String? { m } }
    private static func randomURLSafe(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b).base64URL
    }
    private static func email(fromIDToken t: String) -> String? {
        let parts = t.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["email"] as? String
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - 设置 › 存储 › Google 云端硬盘备份

struct DriveBackupView: View {
    @State private var b = DriveBackup.shared
    @State private var confirmRestore = false
    @State private var restored = false

    var body: some View {
        Form {
            Section {
                if b.signedIn {
                    LabeledContent("账号", value: b.email ?? "Google 账号")
                    LabeledContent("上次备份", value: b.lastBackup.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "还没有")
                    Toggle("自动备份", isOn: $b.auto)
                } else {
                    Button { b.signIn() } label: { Label("登录 Google 并开始备份", systemImage: "person.crop.circle.badge.plus") }
                }
            } footer: {
                Text("备份笔记、试卷和 PDF 上的手写、草稿纸、导入的试卷、做题记录和设置，存到你云端硬盘的「\(DriveBackup.folderName)」文件夹。只上传改过的文件。App 只能看到它自己建的文件，看不到你云端硬盘里的其他东西。")
            }
            if b.signedIn {
                Section {
                    Button { Task { await b.backup() } } label: {
                        HStack { Label("立即备份", systemImage: "icloud.and.arrow.up"); Spacer(); if b.busy { ProgressView() } }
                    }.disabled(b.busy)
                    Button { confirmRestore = true } label: { Label("从备份恢复", systemImage: "icloud.and.arrow.down") }.disabled(b.busy)
                } footer: {
                    if let s = b.status { Text(s) }
                }
                Section { Button("退出 Google 账号", role: .destructive) { b.signOut() } }
            }
            if let e = b.error { Section { Text(e).foregroundStyle(.red) } }
        }
        .navigationTitle("Google 云端硬盘备份")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("用云端硬盘里的备份覆盖本机的数据？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("恢复", role: .destructive) { Task { restored = await b.restore() } }
            Button("取消", role: .cancel) {}
        } message: { Text("本机上同名的笔记、手写和记录会被备份里的版本替换。") }
        .alert("恢复完成", isPresented: $restored) {
            Button("好") {}
        } message: { Text("请从多任务界面完全关掉 Prism 再打开，恢复的内容才会显示。") }
    }
}
