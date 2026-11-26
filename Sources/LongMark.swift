import SwiftUI

/// Self-marking for a long (non-MC) question after 交卷.
/// The marking scheme is split into 得分点 (lines with 1M / 1A / (2) …); each point gets a 0…n stepper.
/// "DeepSeek 按草稿纸批改" grades the scratch sheet against the scheme; each suggested point can be adopted.
/// Nothing is scored until Sam marks it: unmarked shows "未评分", never 0.
struct LongMarkCard: View {
    let key: String              // stable id for saved per-point marks
    let question: String
    let scheme: String
    var images: [UIImage] = []
    var sheetID: String? = nil
    let max: Int?                // nil = paper doesn't say
    @Binding var score: Int?
    var points: [LMPoint]? = nil       // pre-split points (中文 評分準則); nil = parse `scheme`
    var answerText: String? = nil      // typed answer, sent to DeepSeek instead of / with the scratch image
    var context: String? = nil         // e.g. 本章 範文 content

    @Environment(\.tr) private var T
    @State private var pts: [LMPoint] = []
    @State private var ds: DSGradeResult?
    @State private var grading = false
    @State private var error: String?

    private var full: Int { max ?? (pts.isEmpty ? 0 : pts.reduce(0) { $0 + $1.max }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(T("Self-mark", "自评"), systemImage: "pencil.and.list.clipboard").font(.headline)
                Spacer()
                if let s = score {
                    Text(full > 0 ? "\(s) / \(full)" : "\(s)").font(.title3.monospacedDigit().bold())
                        .foregroundStyle(full > 0 && s >= full ? Color.good : (s == 0 ? Color.bad : Color.orange))
                } else {
                    Text(T("Not marked", "未评分")).font(.subheadline.bold()).foregroundStyle(.secondary)
                }
            }
            if !pts.isEmpty {
                Text(T("Points in the marking scheme", "得分点")).font(.subheadline.bold()).foregroundStyle(.secondary)
                ForEach($pts) { $p in pointRow($p) }
            } else if full > 0 {
                chips(0...full, selected: score) { v in score = v }
            } else {
                // No marks given: three levels.
                HStack(spacing: 8) {
                    level(T("Wrong", "不会"), 0); level(T("Partly", "部分对"), 1); level(T("All right", "全对"), 2)
                }
            }
            HStack(spacing: 8) {
                Button { runDS() } label: {
                    if grading { ProgressView().controlSize(.small) } else { Label(T("DeepSeek: mark my scratch", "DeepSeek 按草稿纸批改"), systemImage: "sparkles") }
                }
                .glassButton().disabled(grading)
                if score != nil {
                    Button(T("Clear", "清除")) { score = nil; for i in pts.indices { pts[i].got = nil }; save() }
                        .glassButton()
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            if let ds, !ds.summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("DeepSeek · \(ds.score)/\(ds.max)").font(.subheadline.bold())
                        Spacer()
                        Button(T("Adopt all", "全部采用")) { adoptAll() }.glassButton().controlSize(.small)
                    }
                    MathText(text: ds.summary, size: 15)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .card()
        .onAppear(perform: load)
    }

    // MARK: rows

    private func pointRow(_ p: Binding<LMPoint>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MathText(text: p.wrappedValue.text, size: 15)
            if let c = p.wrappedValue.comment, !c.isEmpty { MathText(text: c, size: 13, color: .secondary) }
            HStack(spacing: 6) {
                chips(0...Swift.max(1, p.wrappedValue.max), selected: p.wrappedValue.got) { v in
                    p.wrappedValue.got = p.wrappedValue.got == v ? nil : v
                    recompute()
                }
                if let s = p.wrappedValue.suggested {
                    Button(T("Adopt \(s)", "采用 \(s) 分")) { p.wrappedValue.got = s; recompute() }
                        .glassButton().controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func chips(_ r: ClosedRange<Int>, selected: Int?, _ set: @escaping (Int) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(r), id: \.self) { v in
                    Button { set(v) } label: {
                        Text("\(v)").font(.subheadline.monospacedDigit().bold())
                            .frame(minWidth: 34, minHeight: 30)
                            .background(selected == v ? Color.accentColor : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .foregroundStyle(selected == v ? Color.white : Color.primary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func level(_ t: String, _ v: Int) -> some View {
        Button { score = score == v ? nil : v; save() } label: { Text(t) }
            .glassButton(prominent: score == v)
    }

    // MARK: logic

    private func recompute() {
        score = pts.contains { $0.got != nil } ? pts.reduce(0) { $0 + ($1.got ?? 0) } : nil
        if let s = score, full > 0 { score = Swift.min(s, full) }
        save()
    }

    private func adoptAll() {
        guard let ds else { return }
        if pts.contains(where: { $0.suggested != nil }) {
            for i in pts.indices { pts[i].got = pts[i].suggested ?? pts[i].got ?? 0 }
            recompute()
        } else { score = ds.score; save() }
    }

    private func runDS() {
        guard DSKey.has else { error = DSError.noKey.errorDescription; return }
        error = nil; grading = true
        var imgs = images
        if let s = DSContext.scratchImage(sheetID) { imgs.append(s) }
        var q = question
        if let c = context, !c.isEmpty { q = c + "\n\n【题目】\n" + q }
        if let a = answerText, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { q += "\n\n【学生作答（打字，以此为准）】\n" + a }
        let spec = DSGradeSpec(question: q, scheme: scheme, maxMarks: full, images: imgs)
        Task {
            do {
                let r = try await DSGrader.grade(spec)
                ds = r
                // Map DeepSeek's points onto the scheme's points by order; if the scheme had none, use DeepSeek's.
                if pts.isEmpty {
                    pts = r.points.map { LMPoint(text: $0.point, max: Swift.max(1, Int($0.max.rounded())), got: nil,
                                                 suggested: Int($0.awarded.rounded()), comment: $0.comment) }
                } else {
                    for (i, p) in r.points.enumerated() where i < pts.count {
                        pts[i].suggested = Swift.min(pts[i].max, Int(p.awarded.rounded())); pts[i].comment = p.comment
                    }
                }
                save(keepScore: true)
            } catch {
                self.error = (error as? DSError)?.errorDescription ?? error.localizedDescription
            }
            grading = false
        }
    }

    private func load() {
        if let d = UserDefaults.standard.data(forKey: "lm." + key), let p = try? JSONDecoder().decode([LMPoint].self, from: d), !p.isEmpty { pts = p }
        else { pts = points ?? LMPoint.split(scheme) }
    }
    private func save(keepScore: Bool = false) {
        if let d = try? JSONEncoder().encode(pts) { UserDefaults.standard.set(d, forKey: "lm." + key) }
    }
}

struct LMPoint: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var max: Int
    var got: Int?
    var suggested: Int? = nil
    var comment: String? = nil

    /// HK marking schemes put marks at the end of a line: "1M", "1A", "2M+1A", "(2)", "1".
    static func split(_ ms: String) -> [LMPoint] {
        let re = try! NSRegularExpression(pattern: #"(?:(\d)\s*[MAB]\b(?:\s*\+\s*(\d)\s*[MAB]\b)*)|\((\d)\)\s*$"#)
        var out: [LMPoint] = []
        for raw in ms.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            let ms = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
            var n = 0
            for m in ms {
                for g in 1...3 where m.range(at: g).location != NSNotFound { n += Int(ns.substring(with: m.range(at: g))) ?? 0 }
            }
            if n > 0 { out.append(LMPoint(text: line, max: Swift.min(n, 6), got: nil)) }
            else if !out.isEmpty, out.count < 30 { out[out.count - 1].text += "\n" + line }
        }
        return out.count >= 1 ? out : []
    }
}

enum DSGrader {
    static func prompt(_ g: DSGradeSpec) -> String {
        """
        请按评分标准批改学生的作答（学生作答在附图的草稿纸上，同一张草稿纸可能有其他题目，只看这一题；如果看不到这一题的作答就在 summary 说明并给 0 分）。\(g.maxMarks > 0 ? "满分 \(g.maxMarks) 分。" : "按 DSE 习惯自行定出各评分点和满分。")
        评分点按评分标准的顺序逐条列出（每个 1M / 1A 一条）。
        只输出 JSON。数学式用 $...$（行内）或 $$...$$，在 JSON 字符串里反斜杠要写成两个，例如 "$\\\\frac{1}{2}$"。格式：
        {"points":[{"point":"评分点","awarded":0,"max":1,"comment":"简短评语"}],"score":0,"max":\(g.maxMarks > 0 ? g.maxMarks : 4),"summary":"一两句总评，指出最关键的错误"}

        【题目】
        \(g.question)

        【评分标准 / 参考答案】
        \(g.scheme)
        """
    }
    static func grade(_ g: DSGradeSpec) async throws -> DSGradeResult {
        let m = DSModel.current
        let payload: [[String: Any]] = [
            ["role": "system", "content": DSClient.systemPrompt + "\n你现在是严格但公平的 DSE 阅卷员。"],
            DSClient.message("user", DSPart(text: prompt(g), images: g.images), vision: m.vision)
        ]
        let s = try await DSClient.complete(payload, model: m, json: true)
        guard let r = DSGradeResult.parse(s, max: g.maxMarks) else { throw DSError.server(0, "批改结果无法解析，再试一次") }
        return r
    }
}
