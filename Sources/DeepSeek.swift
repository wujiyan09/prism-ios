import SwiftUI
import Security
import PencilKit
import Observation

// MARK: - DeepSeek: key (Keychain, this device only), client (OpenAI-format chat/completions, SSE streaming)

enum DSKey {
    private static let service = "com.wujiyan09.prism.deepseek"
    private static let account = "api-key"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    static func get() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
    static func set(_ key: String?) {
        SecItemDelete(base as CFDictionary)
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return }
        var q = base
        q[kSecValueData as String] = Data(k.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    static var has: Bool { DSKey.get() != nil }
}

enum DSModel: String, CaseIterable, Identifiable {
    case flash = "deepseek-flash"
    case pro = "deepseek-v4-pro"
    var id: String { rawValue }
    var vision: Bool { self == .flash }
    static var current: DSModel { DSModel(rawValue: UserDefaults.standard.string(forKey: "ds.model") ?? "") ?? .flash }
}

enum DSError: LocalizedError {
    case noKey, auth, balance, rate, server(Int, String), network(String)
    var errorDescription: String? {
        switch self {
        case .noKey: return "还没有填 DeepSeek API key。去 设置 → DeepSeek 填一下。"
        case .auth: return "API key 无效（401）。去 设置 → DeepSeek 检查一下。"
        case .balance: return "DeepSeek 账户余额不足（402）。去 platform.deepseek.com 充值后再试。"
        case .rate: return "请求太频繁（429），稍等一下再试。"
        case .server(let c, let m): return "DeepSeek 出错（\(c)）\(m.isEmpty ? "" : "：" + m)"
        case .network(let m): return "网络连接失败：\(m)"
        }
    }
}

struct DSPart { var text: String; var images: [UIImage] = [] }

enum DSClient {
    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    static let systemPrompt = """
    你是一位熟悉香港中学文凭试（HKDSE）的私人导师，学生是香港 S5 学生，科目包括 ICT、Mathematics（Core 与 M2）、Physics、Chemistry 和中文。
    规则：
    - 默认用简体中文回答；英文专业名词、课本术语、程序代码保留英文。学生用英文提问就用英文答。
    - 跟课本和 DSE 评分标准的方法走，不要用超纲方法；步骤清楚、简洁，不要客套话。
    - 数学式一律用 LaTeX：行内用 $...$，独立一行用 $$...$$。代码用 ``` 代码块。
    - 学生只要提示时，只给下一步的提示，绝对不要给出答案或完整解法。
    - 如果没有给你答案或评分标准，不要假装知道官方答案。
    """

    private static func payload(_ msgs: [[String: Any]], model: DSModel, stream: Bool, json: Bool) -> Data {
        var body: [String: Any] = ["model": model.rawValue, "messages": msgs, "stream": stream]
        let think = UserDefaults.standard.bool(forKey: "ds.thinking")
        body["thinking"] = ["type": think ? "enabled" : "disabled"]
        if json { body["response_format"] = ["type": "json_object"] }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func message(_ role: String, _ p: DSPart, vision: Bool) -> [String: Any] {
        let imgs = vision ? p.images.compactMap { dataURL($0) } : []
        if imgs.isEmpty { return ["role": role, "content": p.text] }
        var c: [[String: Any]] = [["type": "text", "text": p.text]]
        for u in imgs { c.append(["type": "image_url", "image_url": ["url": u]]) }
        return ["role": role, "content": c]
    }

    static func dataURL(_ img: UIImage) -> String? {
        var im = img
        let maxSide: CGFloat = 1600
        let s = max(img.size.width, img.size.height)
        if s > maxSide {
            let k = maxSide / s
            let sz = CGSize(width: img.size.width * k, height: img.size.height * k)
            im = UIGraphicsImageRenderer(size: sz).image { _ in img.draw(in: CGRect(origin: .zero, size: sz)) }
        }
        // Flatten onto white so transparent ink/figures stay readable.
        let flat = UIGraphicsImageRenderer(size: im.size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: im.size)); im.draw(at: .zero)
        }
        guard let d = flat.jpegData(compressionQuality: 0.8) else { return nil }
        return "data:image/jpeg;base64," + d.base64EncodedString()
    }

    private static func request(_ body: Data) throws -> URLRequest {
        guard let key = DSKey.get() else { throw DSError.noKey }
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.timeoutInterval = 180
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        r.httpBody = body
        return r
    }

    private static func check(_ resp: URLResponse, _ body: String) throws {
        guard let h = resp as? HTTPURLResponse else { return }
        switch h.statusCode {
        case 200..<300: return
        case 401: throw DSError.auth
        case 402: throw DSError.balance
        case 429: throw DSError.rate
        default:
            var m = body
            if let d = body.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let e = o["error"] as? [String: Any], let s = e["message"] as? String { m = s }
            throw DSError.server(h.statusCode, String(m.prefix(200)))
        }
    }

    /// Streams the reply; `onDelta` gets each new piece of content on the main actor.
    static func stream(_ msgs: [[String: Any]], model: DSModel, onDelta: @MainActor @escaping (String) -> Void) async throws {
        let req = try request(payload(msgs, model: model, stream: true, json: false))
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                var s = ""
                for try await l in bytes.lines { s += l; if s.count > 2000 { break } }
                try check(resp, s)
            }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let d = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if d == "[DONE]" { break }
                guard let o = try? JSONSerialization.jsonObject(with: Data(d.utf8)) as? [String: Any],
                      let ch = (o["choices"] as? [[String: Any]])?.first,
                      let delta = ch["delta"] as? [String: Any],
                      let c = delta["content"] as? String, !c.isEmpty else { continue }
                await onDelta(c)
            }
        } catch let e as DSError { throw e
        } catch is CancellationError { throw CancellationError()
        } catch let e as URLError where e.code == .cancelled { throw CancellationError()
        } catch { throw DSError.network(error.localizedDescription) }
    }

    /// One-shot request; returns the content string.
    static func complete(_ msgs: [[String: Any]], model: DSModel, json: Bool = false) async throws -> String {
        let req = try request(payload(msgs, model: model, stream: false, json: json))
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            try check(resp, String(data: data, encoding: .utf8) ?? "")
            guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ch = (o["choices"] as? [[String: Any]])?.first,
                  let m = ch["message"] as? [String: Any], let c = m["content"] as? String else {
                throw DSError.server(200, "回复格式无法解析")
            }
            return c
        } catch let e as DSError { throw e
        } catch { throw DSError.network(error.localizedDescription) }
    }

    static func test(key: String, model: DSModel) async -> String {
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.timeoutInterval = 30
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer " + key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model.rawValue, "max_tokens": 5, "thinking": ["type": "disabled"],
            "messages": [["role": "user", "content": "ping"]]] as [String: Any])
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            try check(resp, String(data: data, encoding: .utf8) ?? "")
            return "✓ 连接成功（\(model.rawValue)）"
        } catch {
            return "✗ " + ((error as? DSError)?.errorDescription ?? DSError.network(error.localizedDescription).errorDescription!)
        }
    }
}

// MARK: - Context passed in by each screen

struct DSGradeSpec {
    var question: String
    var scheme: String
    var maxMarks: Int
    var images: [UIImage] = []
    /// Called when the student taps 采用 — screens map the score to their own self-mark.
    var apply: ((Int) -> Void)?
}

struct DSContext {
    var key: String               // chat saved per question/card
    var subject: String
    var title: String
    var page: String              // question / card text
    var images: [UIImage] = []    // figures on this page
    var revealed: String? = nil   // answer / solution — only pass when already shown
    var chapter: String? = nil    // chapter title + card summaries
    var sheetID: String? = nil    // scratch sheet for this set
    var isCard = false
    var grade: DSGradeSpec? = nil

    static func subjectName(_ s: String) -> String {
        switch s {
        case "ict": return "ICT"
        case "math", "maths": return "Mathematics"
        case "m2": return "Mathematics M2"
        case "phy", "physics": return "Physics"
        case "chem": return "Chemistry"
        case "zh", "chinese": return "中文"
        default: return s
        }
    }

    static func plain(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "</p>", with: "\n")
            .replacingOccurrences(of: "</li>", with: "\n")
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    /// Maths/中文 chapter: title + card titles/summaries, trimmed to a budget.
    static func mathChapter(_ c: MChapter, budget: Int = 6000) -> String {
        var s = c.label + "\n"
        for k in c.cards {
            let line = "- " + (k.t ?? "") + ((k.s ?? "").isEmpty ? "" : "：" + String((k.s ?? "").prefix(160)))
            if s.count + line.count > budget { s += "…"; break }
            s += line + "\n"
        }
        return s
    }

    static func ictChapter(_ c: Chapter, budget: Int = 6000) -> String {
        var s = "Ch\(c.n) \(c.t)\(c.tz.isEmpty ? "" : "（\(c.tz)）")\n"
        for k in c.cards {
            let body = plain(k.zh ?? k.en ?? "").replacingOccurrences(of: "\n", with: " ")
            let line = "- " + k.t + "：" + String(body.prefix(160))
            if s.count + line.count > budget { s += "…"; break }
            s += line + "\n"
        }
        return s
    }

    static func ictCard(_ c: Chapter, _ i: Int) -> DSContext {
        let k = c.cards[min(max(0, i), c.cards.count - 1)]
        var page = k.t + "\n" + plain(k.zh ?? k.en ?? "")
        for (j, e) in (k.ex ?? []).enumerated() {
            page += "\n\n例题 \(j + 1)：" + plain(e.q) + "\n解答：" + plain(e.a)
        }
        return DSContext(key: "ict-card-\(c.id)-\(i)", subject: "ict", title: k.t, page: page, chapter: ictChapter(c), isCard: true)
    }

    /// ICT quiz question before 交卷: question + options only, never the answer.
    static func ictItem(_ it: Item, title: String) -> DSContext {
        let L = ["A", "B", "C", "D", "E", "F"]
        var page = plain(it.q)
        if !it.st.isEmpty { page += "\n" + it.st.map { plain($0) }.joined(separator: "\n") }
        if !it.o.isEmpty { page += "\n" + it.o.enumerated().map { "\(L[min($0.offset, 5)]). " + plain($0.element) }.joined(separator: "\n") }
        var imgs: [UIImage] = []
        for u in ([it.fig].compactMap { $0 } + it.figs) where u.isFileURL {
            if let im = UIImage(contentsOfFile: u.path) { imgs.append(im) }
        }
        var ch: String?
        if let id = it.chapterID, let c = Library.shared.chapter(id), !c.isStub { ch = ictChapter(c) }
        return DSContext(key: "ict-q-" + it.key, subject: "ict", title: title, page: page, images: imgs, chapter: ch)
    }

    static func mathCard(_ c: MChapter, _ i: Int) -> DSContext {
        let k = c.cards[min(max(0, i), c.cards.count - 1)]
        var parts: [String] = []
        if let t = k.t { parts.append(t) }
        if let t = k.s { parts.append(t) }
        if let t = k.ex { parts.append("例子：" + t) }
        if let p = k.pos { parts.append("是：" + p.ex + " " + p.why) }
        if let n = k.neg { parts.append("不是：" + n.ex + " " + n.why) }
        if let t = k.rem { parts.append("记住：" + t) }
        if let t = k.wo { parts.append("注意：" + t) }
        var imgs: [UIImage] = []
        for v in k.vis ?? [] {
            if let f = v.img, let u = MathLibrary.resource(f, "vis"), let im = UIImage(contentsOfFile: u.path) { imgs.append(im) }
        }
        return DSContext(key: "m-card-\(c.id)-\(i)", subject: c.isZh ? "zh" : "math", title: k.t ?? c.label,
                         page: parts.filter { !$0.isEmpty }.joined(separator: "\n\n"), images: imgs,
                         chapter: mathChapter(c), isCard: true)
    }

    static func scratchImage(_ id: String?) -> UIImage? {
        guard let id, let d = ScratchStore.shared.load(id), let dr = try? PKDrawing(data: d.drawing), !dr.strokes.isEmpty else { return nil }
        let b = dr.bounds.insetBy(dx: -20, dy: -20)
        let scale = min(2, 2400 / max(b.width, b.height, 1))
        var img: UIImage = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            img = dr.image(from: b, scale: scale)
        }
        return img
    }
}

// MARK: - Chat storage (on device, per question)

struct DSMessage: Codable, Identifiable, Hashable {
    var id = UUID()
    var role: String        // user | assistant
    var text: String
    var note: String? = nil // e.g. "附：本页 · 草稿纸"
}

// MARK: - Settings

struct DeepSeekSettingsView: View {
    @State private var key = DSKey.get() ?? ""
    @AppStorage("ds.model") private var model = DSModel.flash.rawValue
    @AppStorage("ds.thinking") private var thinking = false
    @State private var status: String?
    @State private var testing = false
    @State private var reveal = false
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Group {
                        if reveal { TextField("sk-…", text: $key) } else { SecureField("sk-…", text: $key) }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .onSubmit { DSKey.set(key) }
                    .onChange(of: key) { _, v in DSKey.set(v) }
                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                }
                Button {
                    testing = true; status = nil
                    Task { status = await DSClient.test(key: key, model: DSModel(rawValue: model) ?? .flash); testing = false }
                } label: {
                    HStack { Text("测试连接"); Spacer(); if testing { ProgressView() } }
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                if let s = status { Text(s).font(.footnote).foregroundStyle(s.hasPrefix("✓") ? Color.green : Color.red) }
            } header: { Text("API key") } footer: {
                Text("Key 只保存在这台设备的钥匙串里，不会同步到其他设备或 Google 账号。在 platform.deepseek.com 申请。")
            }
            .listRowBackground(Color.cardBackground)
            Section {
                Picker("模型", selection: $model) {
                    Text("deepseek-flash（快，可看图）").tag(DSModel.flash.rawValue)
                    Text("deepseek-v4-pro（更强，只看文字）").tag(DSModel.pro.rawValue)
                }
                Toggle("思考模式", isOn: $thinking)
            } footer: {
                Text("flash 能读题目图片和草稿纸；pro 推理更强但不能看图，图片会被略过。思考模式更准但更慢、更贵。")
            }
            .listRowBackground(Color.cardBackground)
            Section {
                Text("按 DeepSeek 用量计费，直接从你的 DeepSeek 账户扣。flash 大约每百万输入 token US$0.15–0.30、输出 US$0.6–1.2；问一题通常不到 US$0.001，附图会多一些。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("删除所有对话记录", role: .destructive) { confirmClear = true }
            } header: { Text("用量") }
            .listRowBackground(Color.cardBackground)
        }
        .appList()
        .navigationTitle("DeepSeek")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除所有 DeepSeek 对话？（会同步删除其他设备上的；批改和分析记录保留）", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("删除", role: .destructive) { DSStore.shared.clearChats() }
        }
    }
}

// MARK: - Entry: toolbar button + inspector (sheet on compact)

extension View {
    /// Adds a 问 DeepSeek toolbar button and side panel. The context is only built when the panel is open.
    func deepSeek(_ ctx: @autoclosure @escaping () -> DSContext?) -> some View { modifier(DeepSeekEntry(make: ctx)) }
}

/// Shared state for the pinned (sidebar) mode on iPad. Lives outside the navigation tree.
@Observable
final class DSDock {
    static let shared = DSDock()
    var pinned = UserDefaults.standard.bool(forKey: "ds.pinned") { didSet { UserDefaults.standard.set(pinned, forKey: "ds.pinned") } }
    var visible = UserDefaults.standard.bool(forKey: "ds.pinned.visible") { didSet { UserDefaults.standard.set(visible, forKey: "ds.pinned.visible") } }
    var width = max(320, UserDefaults.standard.double(forKey: "ds.pinned.width")) { didSet { UserDefaults.standard.set(width, forKey: "ds.pinned.width") } }
    @ObservationIgnored var provider: (() -> DSContext?)?
    var owner: UUID?
    var tick = 0
    func attach(_ id: UUID, _ make: @escaping () -> DSContext?) { provider = make; owner = id; tick += 1 }
    func detach(_ id: UUID) { if owner == id { provider = nil; owner = nil; tick += 1 } }
}

struct DeepSeekEntry: ViewModifier {
    let make: () -> DSContext?
    @State private var open = false
    @State private var ctx: DSContext?
    @State private var me = UUID()
    @Environment(\.horizontalSizeClass) private var hsc
    private var dock: DSDock { DSDock.shared }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if hsc == .regular && dock.pinned { dock.attach(me, make); dock.visible.toggle() }
                        else { ctx = make(); open = true }
                    } label: { Label("问 DeepSeek", systemImage: "sparkles") }
                        .accessibilityLabel("问 DeepSeek")
                }
            }
            .onAppear { dock.attach(me, make) }
            .onDisappear { dock.detach(me) }
            .sheet(isPresented: $open) {
                Group {
                    if let ctx {
                        DeepSeekPanel(ctx: ctx, close: { open = false })
                            .overlay(alignment: .topLeading) {
                                if hsc == .regular {
                                    Button { open = false; dock.pinned = true; dock.attach(me, make); dock.visible = true } label: {
                                        Label("固定到侧边", systemImage: "sidebar.right")
                                    }
                                    .font(.footnote).buttonStyle(.bordered).padding(10)
                                }
                            }
                    } else {
                        ContentUnavailableView("这一页暂时没有内容可以问", systemImage: "sparkles")
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
    }
}

/// Trailing column next to the detail stack. Always present in the tree, so navigation never resets.
struct DSDockColumn: View {
    @Environment(\.horizontalSizeClass) private var hsc
    @State private var dragStart: Double?
    var body: some View {
        let dock = DSDock.shared
        let _ = dock.tick
        if hsc == .regular && dock.pinned && dock.visible {
            HStack(spacing: 0) {
                Rectangle().fill(Color(uiColor: .separator)).frame(width: 1)
                    .overlay {
                        Rectangle().fill(.clear).frame(width: 14).contentShape(Rectangle())
                            .gesture(DragGesture().onChanged { v in
                                if dragStart == nil { dragStart = dock.width }
                                dock.width = min(640, max(300, (dragStart ?? dock.width) - v.translation.width))
                            }.onEnded { _ in dragStart = nil })
                    }
                VStack(spacing: 0) {
                    HStack {
                        Label("DeepSeek", systemImage: "sparkles").font(.headline)
                        Spacer()
                        Button { dock.pinned = false; dock.visible = false } label: { Image(systemName: "rectangle.bottomhalf.inset.filled") }
                            .accessibilityLabel("改为弹出")
                        Button { dock.visible = false } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("收起")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    Divider()
                    if let ctx = dock.provider?() {
                        DeepSeekPanel(ctx: ctx, close: { dock.visible = false }).id(ctx.key)
                    } else {
                        ContentUnavailableView("这一页暂时没有内容可以问", systemImage: "sparkles")
                    }
                }
                .frame(width: dock.width)
                .background(Color(uiColor: .systemBackground))
            }
            .transition(.move(edge: .trailing))
        }
    }
}

// MARK: - Panel

struct DeepSeekPanel: View {
    let ctx: DSContext
    var close: () -> Void
    @State private var msgs: [DSMessage] = []
    @State private var input = ""
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var usePage = true
    @State private var useChapter = true
    @State private var useScratch = false
    @State private var grading = false
    @State private var grade: DSGradeResult?
    @State private var showSettings = false
    @State private var showHistory = false
    @AppStorage("ds.model") private var modelRaw = DSModel.flash.rawValue
    @FocusState private var focused: Bool

    private var model: DSModel { DSModel(rawValue: modelRaw) ?? .flash }
    private var busy: Bool { task != nil || grading }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if !DSKey.has { noKey }
                            if msgs.isEmpty && grade == nil { intro }
                            if let g = grade { DSGradeCard(result: g, spec: ctx.grade) }
                            ForEach(msgs) { m in DSBubble(msg: m).id(m.id) }
                            if let e = error {
                                Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding()
                    }
                    .onChange(of: msgs.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: msgs.count) { proxy.scrollTo("end", anchor: .bottom) }
                }
                Divider()
                composer
            }
            .navigationTitle("DeepSeek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { close() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("模型", selection: $modelRaw) {
                            ForEach(DSModel.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                        Button("清空这题的对话", role: .destructive) { task?.cancel(); msgs = []; grade = nil; DSStore.shared.chats[ctx.key] = nil }
                        Button("历史") { showHistory = true }
                        Button("DeepSeek 设置") { showSettings = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .navigationDestination(isPresented: $showSettings) { DeepSeekSettingsView() }
            .navigationDestination(isPresented: $showHistory) { DSHistoryView(scope: ctx.key) }
        }
        .onAppear { msgs = DSStore.shared.chats[ctx.key]?.msgs ?? []; grade = DSStore.shared.history(ctx.key, "grade").first.flatMap { DSGradeResult.parse($0.body, max: ctx.grade?.maxMarks ?? 0) }; useScratch = false }
        .onDisappear { task?.cancel() }
    }

    private var noKey: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("先填 API key").font(.headline)
            Text("在 设置 → DeepSeek 填入你的 key 才能使用。").font(.callout).foregroundStyle(.secondary)
            Button("打开 DeepSeek 设置") { showSettings = true }.buttonStyle(.borderedProminent)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ctx.title).font(.headline)
            Text(ctx.revealed == nil && !ctx.isCard ? "还没交卷，答案不会发给 DeepSeek。" : "会附上本页内容。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var quick: [(String, String)] {
        var q: [(String, String)] = []
        if ctx.isCard {
            q.append(("解释这张卡", "用简单的话解释这张知识卡，再说一个考试常见的考法。"))
            q.append(("再举一个例子", "再举一个和这张卡相关的例子，附完整解答。"))
        } else {
            q.append(("给我提示（不给答案）", "我卡住了。只给我下一步的提示，不要给答案，也不要写出完整解法。"))
            q.append(("讲解这题", "一步一步讲解这道题，按课本方法，指出容易错的地方。"))
            q.append(("再举一个例子", "举一个用同样方法的例子，附完整解答。"))
        }
        q.append(("出一道类似题", "出一道同类型、难度相近的 DSE 风格题目。先只给题目，不要给答案，我做完再问你。"))
        return q
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("本页", on: $usePage)
                    if ctx.chapter != nil { chip("本章", on: $useChapter) }
                    if ctx.sheetID != nil { chip("草稿纸", on: $useScratch, icon: "scribble") }
                    if ctx.grade != nil {
                        Button { runGrade() } label: { Label("DeepSeek 批改", systemImage: "checkmark.seal") }
                            .buttonStyle(.borderedProminent).controlSize(.small).disabled(busy)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(quick, id: \.0) { q in
                        Button(q.0) { send(q.1, shown: q.0) }.buttonStyle(.bordered).controlSize(.small).disabled(busy)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("问点什么…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onSubmit { send(input, shown: input) }
                if task != nil {
                    Button { task?.cancel(); task = nil } label: { Image(systemName: "stop.circle.fill").font(.title) }
                        .accessibilityLabel("停止")
                } else {
                    Button { send(input, shown: input) } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || grading)
                        .accessibilityLabel("发送")
                }
            }
        }
        .padding(10)
    }

    private func chip(_ t: String, on: Binding<Bool>, icon: String? = nil) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon) }
                Text(t)
                Image(systemName: on.wrappedValue ? "xmark" : "plus").font(.caption2.bold())
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(on.wrappedValue ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
            .foregroundStyle(on.wrappedValue ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func contextPart() -> DSPart {
        var s = "科目：\(DSContext.subjectName(ctx.subject))\n"
        var imgs: [UIImage] = []
        if useChapter, let c = ctx.chapter { s += "\n【本章概要】\n" + c + "\n" }
        if usePage {
            s += "\n【本页：\(ctx.title)】\n" + ctx.page + "\n"
            if let r = ctx.revealed { s += "\n【答案 / 解析（学生已看到）】\n" + r + "\n" }
            else if !ctx.isCard { s += "\n（学生还没交卷，你没有答案；不要直接给出最终答案，除非学生明确要求。）\n" }
            imgs += ctx.images
        }
        if useScratch, let img = DSContext.scratchImage(ctx.sheetID) {
            s += "\n（附图：学生的草稿纸手写过程）\n"
            imgs.append(img)
        }
        if !imgs.isEmpty && !model.vision { s += "\n（本页有图片，但当前模型不能看图。）\n" }
        return DSPart(text: s, images: imgs)
    }

    private func send(_ text: String, shown: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, task == nil else { return }
        guard DSKey.has else { error = DSError.noKey.errorDescription; return }
        error = nil
        input = ""
        var notes: [String] = []
        if usePage { notes.append("本页") }
        if useChapter && ctx.chapter != nil { notes.append("本章") }
        if useScratch && ctx.sheetID != nil { notes.append("草稿纸") }
        let history = msgs
        msgs.append(DSMessage(role: "user", text: shown == text ? t : shown, note: notes.isEmpty ? nil : "附：" + notes.joined(separator: " · ")))
        msgs.append(DSMessage(role: "assistant", text: ""))
        let ci = contextPart()
        let m = model
        var payload: [[String: Any]] = [["role": "system", "content": DSClient.systemPrompt]]
        payload.append(DSClient.message("user", DSPart(text: ci.text, images: ci.images), vision: m.vision))
        payload.append(["role": "assistant", "content": "好的，我看到了。请问。"])
        for h in history.suffix(16) where !h.text.isEmpty { payload.append(["role": h.role, "content": h.text]) }
        payload.append(["role": "user", "content": t])
        task = Task {
            do {
                try await DSClient.stream(payload, model: m) { d in
                    if let i = msgs.indices.last { msgs[i].text += d }
                }
            } catch is CancellationError {
            } catch {
                self.error = (error as? DSError)?.errorDescription ?? error.localizedDescription
            }
            if let l = msgs.last, l.role == "assistant", l.text.isEmpty { msgs.removeLast() }
            DSStore.shared.chats[ctx.key] = msgs.isEmpty ? nil : DSChat(title: ctx.title, t: Date().timeIntervalSince1970, msgs: msgs)
            task = nil
        }
    }

    private func runGrade() {
        guard let g = ctx.grade else { return }
        guard DSKey.has else { error = DSError.noKey.errorDescription; return }
        error = nil; grading = true; grade = nil
        let m = model
        var imgs = g.images
        if let s = DSContext.scratchImage(ctx.sheetID) { imgs.append(s) }
        let prompt = """
        请按评分标准批改学生的作答（学生作答在附图的草稿纸上，同一张草稿纸可能有其他题目，只看这一题；如果看不到这一题的作答就在 summary 说明并给 0 分）。\(g.maxMarks > 0 ? "满分 \(g.maxMarks) 分。" : "按 DSE 习惯自行定出各评分点和满分。")
        只输出 JSON，格式：
        {"points":[{"point":"评分点","awarded":0,"max":1,"comment":"简短评语"}],"score":0,"max":\(g.maxMarks > 0 ? g.maxMarks : 4),"summary":"一两句总评，指出最关键的错误"}

        【题目】
        \(g.question)

        【评分标准 / 参考答案】
        \(g.scheme)
        """
        let payload: [[String: Any]] = [
            ["role": "system", "content": DSClient.systemPrompt + "\n你现在是严格但公平的 DSE 阅卷员。"],
            DSClient.message("user", DSPart(text: prompt, images: imgs), vision: m.vision)
        ]
        Task {
            do {
                let s = try await DSClient.complete(payload, model: m, json: true)
                if let r = DSGradeResult.parse(s, max: g.maxMarks) { grade = r; DSStore.shared.add("grade", scope: ctx.key, title: ctx.title, body: s) }
                else { error = "批改结果无法解析，再试一次。" }
            } catch {
                self.error = (error as? DSError)?.errorDescription ?? error.localizedDescription
            }
            grading = false
        }
    }
}

// MARK: - Grading result

struct DSGradeResult {
    struct Point: Identifiable { let id = UUID(); let point: String; let awarded: Double; let max: Double; let comment: String }
    var points: [Point]
    var score: Int
    var max: Int
    var summary: String

    static func parse(_ s: String, max: Int) -> DSGradeResult? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}") { t = String(t[a...b]) }
        guard let o = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any] else { return nil }
        func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? Double(v as? String ?? "") ?? 0 }
        let pts = (o["points"] as? [[String: Any]] ?? []).map {
            Point(point: $0["point"] as? String ?? "", awarded: num($0["awarded"]), max: num($0["max"]), comment: $0["comment"] as? String ?? "")
        }
        var sc = Int(num(o["score"]).rounded())
        if o["score"] == nil { sc = Int(pts.reduce(0) { $0 + $1.awarded }.rounded()) }
        let full = max > 0 ? max : Swift.max(1, Int(num(o["max"]).rounded()), Int(pts.reduce(0) { $0 + $1.max }.rounded()))
        return DSGradeResult(points: pts, score: Swift.max(0, Swift.min(sc, full)), max: full, summary: o["summary"] as? String ?? "")
    }
}

struct DSGradeCard: View {
    let result: DSGradeResult
    let spec: DSGradeSpec?
    @State private var applied = false
    private func f(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("DeepSeek 批改（仅供参考）", systemImage: "checkmark.seal").font(.subheadline.bold())
                Spacer()
                Text("\(result.score)/\(result.max)").font(.title3.bold().monospacedDigit())
            }
            ForEach(result.points) { p in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: p.awarded >= p.max && p.max > 0 ? "checkmark.circle.fill" : (p.awarded > 0 ? "circle.lefthalf.filled" : "xmark.circle"))
                            .foregroundStyle(p.awarded >= p.max && p.max > 0 ? Color.green : (p.awarded > 0 ? Color.orange : Color.red))
                        MathText(text: p.point, size: 15)
                        Spacer()
                        Text("\(f(p.awarded))/\(f(p.max))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if !p.comment.isEmpty { MathText(text: p.comment, size: 14, color: .secondary).padding(.leading, 26) }
                }
            }
            if !result.summary.isEmpty { MathText(text: result.summary, size: 15) }
            if let a = spec?.apply {
                Button { a(result.score); applied = true } label: {
                    Label(applied ? "已填入自评（可以再改）" : "采用这个分数作自评", systemImage: applied ? "checkmark" : "square.and.arrow.down")
                }
                .buttonStyle(.bordered).disabled(applied)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Reply rendering: Markdown + LaTeX + code blocks

struct DSBubble: View {
    let msg: DSMessage
    @State private var copied = false
    var body: some View {
        if msg.role == "user" {
            VStack(alignment: .trailing, spacing: 3) {
                Text(msg.text).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
                if let n = msg.note { Text(n).font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if msg.text.isEmpty { ProgressView().padding(.vertical, 4) }
                else { DSMarkdown(text: msg.text) }
                if !msg.text.isEmpty {
                    Button {
                        UIPasteboard.general.string = msg.text; copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: { Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DSMarkdown: View {
    let text: String
    enum Seg: Hashable { case text(String), code(String, String) }

    static func segments(_ s: String) -> [Seg] {
        var out: [Seg] = []
        let parts = s.components(separatedBy: "```")
        for (i, p) in parts.enumerated() {
            if i % 2 == 1 {
                var lines = p.components(separatedBy: "\n")
                let lang = lines.isEmpty ? "" : lines.removeFirst().trimmingCharacters(in: .whitespaces)
                out.append(.code(lang, lines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
            } else if !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.text(normalize(p)))
            }
        }
        return out
    }

    /// \( \) \[ \] → $ / $$; markdown headings → bold; bullets → •.
    static func normalize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\[", with: "$$").replacingOccurrences(of: "\\]", with: "$$")
            .replacingOccurrences(of: "\\(", with: "$").replacingOccurrences(of: "\\)", with: "$")
        t = t.replacingOccurrences(of: "(?m)^#{1,6}\\s*(.+)$", with: "**$1**", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^(\\s*)[-*]\\s+", with: "$1• ", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^---+\\s*$", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "`([^`\\n]+)`", with: "$1", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, s in
                switch s {
                case .text(let t): MathText(text: t, size: 16)
                case .code(let l, let c): CodeBlock(text: c, lang: l)
                }
            }
        }
    }
}
