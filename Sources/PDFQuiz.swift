import SwiftUI
import PDFKit

// MARK: - 把 PDF 题目转成可作答
// Turns the questions ALREADY on the PDF into interactive ones (MC options / long questions with parts, figures
// cropped from the page), reading answer / marking-scheme pages in the same PDF when there are any.
// Runs in the background over every page (no page limit), in batches, with progress on the new paper.

@MainActor @Observable
final class ImpConvert {
    static let shared = ImpConvert()
    /// paper id → progress text (nil when done)
    var progress: [String: String] = [:]
    var errors: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func start(_ id: String) {
        guard tasks[id] == nil else { return }
        errors[id] = nil
        tasks[id] = Task { [weak self] in
            await self?.run(id)
            self?.tasks[id] = nil; self?.progress[id] = nil
        }
    }
    func cancel(_ id: String) { tasks[id]?.cancel(); tasks[id] = nil; progress[id] = nil }

    private func run(_ id: String) async {
        let store = ImportStore.shared
        progress[id] = "正在打开 PDF…"
        guard let d = await Task.detached(priority: .userInitiated, operation: { store.doc(id) }).value else { errors[id] = "读不到 PDF"; return }
        let n = d.pageCount
        var answerPages: [(Int, UIImage, String)] = []
        guard let start = store.papers[id] else { return }
        for i in 0..<n where !start.parsedPages.contains(i) {
            if Task.isCancelled { return }
            progress[id] = "正在转换第 \(i + 1)/\(n) 页…"
            let (im, text) = await Task.detached(priority: .utility) { (ImpPDF.pageImage(d, i), d.page(at: i)?.string ?? "") }.value
            guard let im else { continue }
            do {
                let (kind, qs) = try await ImpParse.classify(page: im, text: text, index: i, count: n)
                guard var x = store.papers[id] else { return }
                if kind == "answers" { answerPages.append((i, im, text)) } else { ImpParse.merge(&x.qs, qs) }
                x.parsedPages.append(i)
                store.save(x)
            } catch {
                errors[id] = "第 \(i + 1) 页：" + ((error as? DSError)?.errorDescription ?? error.localizedDescription) + "（可以再点继续）"
                return
            }
        }
        // Answers / marking scheme found inside the same PDF.
        for (k, (i, im, text)) in answerPages.enumerated() {
            if Task.isCancelled { return }
            progress[id] = "正在读答案页 \(k + 1)/\(answerPages.count)…"
            guard let nums = store.papers[id]?.qs.map(\.n),
                  let items = try? await ImpParse.scheme(page: im, text: text, index: i, numbers: nums), var x = store.papers[id] else { continue }
            for (qn, a, sc) in items {
                guard let j = x.qs.firstIndex(where: { ImpParse.norm($0.n) == ImpParse.norm(qn) }) else { continue }
                if !a.isEmpty { x.qs[j].answer = a }
                if !sc.isEmpty { x.qs[j].scheme = ((x.qs[j].scheme ?? "").isEmpty ? "" : x.qs[j].scheme! + "\n") + sc }
            }
            x.hasMS = x.qs.contains { $0.answer != nil }
            store.save(x)
        }
    }
}

struct PDFQuizSheet: View {
    let title: String
    let subject: String
    var chapters: [String] = []
    let pageCount: Int
    /// Page image + text layer, by index (unused now; kept for callers).
    let page: (Int) -> (UIImage?, String)
    /// PDF stored with the new paper.
    let pdf: () -> PDFDocument?
    var startPage = 0
    var onDone: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("把这份 PDF 上已有的题目逐页拆成可以直接作答的题：选择题带选项，长题保留小题和分数，附图从页面裁出。PDF 里如果有答案或评分标准页，会自动对上；没有的话答案留空，你可以自己填。")
                    .font(.callout)
                Text("共 \(pageCount) 页，全部在后台转换，可以先去做别的。预计约 US$\(String(format: "%.3f", Double(pageCount) * ImpParse.perPage))。").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button { convert() } label: { Label("开始转换", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard") }
                    .disabled(!DSKey.has)
                if !DSKey.has { Text("先在 设置 › DeepSeek 填 API key").font(.footnote).foregroundStyle(.orange) }
                if let e = error { Text(e).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("把 PDF 题目转成可作答")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }

    private func convert() {
        guard let d = pdf() else { error = "读不到 PDF"; return }
        var p = ImportStore.shared.create(name: "\(title) · 可作答", subject: subject, chapters: chapters, pdf: d)
        p.mode = "cards"
        p.hasMS = false
        ImportStore.shared.save(p)
        ImpConvert.shared.start(p.id)
        onDone(p.id)
        dismiss()
    }
}
