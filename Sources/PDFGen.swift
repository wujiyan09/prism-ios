import SwiftUI
import PDFKit

// MARK: - PDF 出题: DeepSeek reads pages of an imported PDF / note and writes new practice questions.
// The result is saved as a new imported paper in AI 答题卡 mode, so it is done and marked like any other.

struct PDFGenSheet: View {
    let title: String
    let subject: String
    var chapters: [String] = []
    let pageCount: Int
    /// Page image + text layer, by index.
    let page: (Int) -> (UIImage?, String)
    /// PDF stored with the new paper (for figures / reference).
    let pdf: () -> PDFDocument?
    var startPage = 0
    var onDone: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var from = 1
    @State private var to = 1
    @State private var count = 8
    @State private var kind = "mix"
    @State private var level = "dse"
    @State private var working: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section("页数范围") {
                Stepper("从第 \(from) 页", value: $from, in: 1...max(1, pageCount))
                    .onChange(of: from) { _, v in if to < v { to = v }; if to - v > 9 { to = v + 9 } }
                Stepper("到第 \(to) 页", value: $to, in: 1...max(1, pageCount))
                    .onChange(of: to) { _, v in if from > v { from = v }; if v - from > 9 { from = v - 9 } }
            }
            Section {
                Stepper("\(count) 题", value: $count, in: 3...20)
                Picker("题型", selection: $kind) {
                    Text("选择题").tag("mc"); Text("长题").tag("long"); Text("混合").tag("mix")
                }
                Picker("难度", selection: $level) {
                    Text("基础").tag("basic"); Text("DSE 程度").tag("dse"); Text("较难").tag("hard")
                }
            } footer: { Text("一次最多 10 页。每题都有答案和评分要点，做完照样批改。") }
            Section {
                Button {
                    Task { await generate() }
                } label: {
                    HStack { Label("开始出题", systemImage: "sparkles"); Spacer(); if working != nil { ProgressView() } }
                }
                .disabled(working != nil || !DSKey.has)
                if let w = working { Text(w).font(.footnote).foregroundStyle(.secondary) }
                if !DSKey.has { Text("先在 设置 › DeepSeek 填 API key").font(.footnote).foregroundStyle(.orange) }
                if let e = error { Text(e).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("根据此 PDF 出题")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onAppear { from = min(max(1, startPage + 1), max(1, pageCount)); to = min(pageCount, from + 2) }
    }

    private func generate() async {
        error = nil
        working = "正在读第 \(from)–\(to) 页…"
        defer { working = nil }
        var text = ""
        var images: [UIImage] = []
        for i in (from - 1)..<to {
            let (im, t) = page(i)
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += "\n【第 \(i + 1) 页】\n" + String(t.prefix(5000)) }
            if let im, images.count < 4, t.count < 200 || images.count < 2 { images.append(im) }
        }
        let kinds = ["mc": "全部是选择题（四个选项）", "long": "全部是长题（可分小题，写分数）", "mix": "大约一半选择题、一半长题"][kind]!
        let lv = ["basic": "基础题，检查概念", "dse": "香港 DSE 程度", "hard": "比 DSE 稍难，需要多步推理"][level]!
        let prompt = """
        你是香港中学老师。根据下面这份资料（标题：\(title)，第 \(from)–\(to) 页）出 \(count) 道新的练习题，\(kinds)，难度：\(lv)。
        题目只考这些页的内容，不要照抄原题；语言跟资料一致（英文资料出英文题）。数学一律用 $...$ LaTeX。
        只输出 JSON：{"questions":[{"text":"题目全文","options":["选项文字（不要字母）"] 或 [],"answer":"选择题写字母 A–D；长题写最终答案","scheme":"评分要点，每行带分数，如 1M、1A","marks":分数,"page":出自第几页}]}
        JSON 字符串里的反斜杠要写成两个。
        \(text.isEmpty ? "（这几页没有文字层，请看图片）" : "资料文字：" + String(text.prefix(24000)))
        """
        do {
            working = "DeepSeek 正在出 \(count) 道题…"
            let s = try await DSClient.complete([DSClient.message("user", DSPart(text: prompt, images: images), vision: !images.isEmpty)], model: images.isEmpty ? .pro : .flash, json: true)
            guard let o = DSJSON.object(s), let arr = o["questions"] as? [[String: Any]], !arr.isEmpty else { throw DSError.server(200, "DeepSeek 没有返回题目，再试一次") }
            let qs: [ImpQ] = arr.enumerated().map { i, q in
                var x = ImpQ(page: max(0, ((q["page"] as? NSNumber)?.intValue ?? from) - 1), n: "\(i + 1)", text: q["text"] as? String ?? "")
                x.options = (q["options"] as? [Any] ?? []).map { "\($0)" }
                x.answer = q["answer"] as? String
                x.scheme = q["scheme"] as? String
                x.marks = (q["marks"] as? NSNumber)?.intValue ?? (x.isMC ? 1 : nil)
                return x
            }
            guard let d = pdf() else { throw DSError.server(200, "读不到 PDF") }
            var p = ImportStore.shared.create(name: "\(title) · 出题 p\(from)–\(to)", subject: subject, chapters: chapters, pdf: d)
            p.mode = "cards"
            p.qs = qs
            p.parsedPages = Array(0..<d.pageCount)
            p.msParsed = Array(0..<d.pageCount)
            p.hasMS = false
            ImportStore.shared.save(p)
            onDone(p.id)
            dismiss()
        } catch {
            self.error = (error as? DSError)?.errorDescription ?? error.localizedDescription
        }
    }
}
