import SwiftUI

// MARK: - 中文 範文 long-answer questions (zhlong/<unit>.json, produced by the content pipeline)

struct ZLPoint: Codable, Hashable { let t: String; let mk: Int?; let lv: Bool? }
struct ZLQ: Codable, Hashable, Identifiable {
    let id: String
    let ty: String?
    let l: String?
    let ctx: String?
    let q: String
    let mk: Int?
    let pts: [ZLPoint]?
    let ans: String?
    let note: String?
    let lbl: String?
    let also: String?
    let fi: [String]?
    let src: String?
    let na: Bool?
    let tg: [String]?
    let asg: String?
    var figImages: [UIImage] { (fi ?? []).compactMap { MathLibrary.resource($0, "fig").flatMap { UIImage(contentsOfFile: $0.path) } } }

    var schemeText: String {
        var s = (pts ?? []).map { $0.t + (($0.mk ?? 0) > 0 ? "（\($0.mk!) 分）" : "") + ($0.lv == true ? "［等級］" : "") }.joined(separator: "\n")
        if let a = ans, !a.isEmpty { s += (s.isEmpty ? "" : "\n") + "參考答案：" + a }
        if let n = note, !n.isEmpty { s += "\n評分說明：" + n }
        if let a = also, !a.isEmpty { s += "\n" + a }
        if na == true { s = "（这题没有官方评分标准。请你根据题目自己定出合理的得分点和分数再批改。）" + (s.isEmpty ? "" : "\n" + s) }
        return s
    }
    /// Ticked points; level/band descriptors become one point whose max is the top band.
    var points: [LMPoint] {
        guard lbl != "參考答案", na != true else { return [] }
        let p = pts ?? []
        var out = p.filter { $0.lv != true }.map { LMPoint(text: $0.t, max: max(1, $0.mk ?? 1), got: nil) }
        let bands = p.filter { $0.lv == true }
        if !bands.isEmpty {
            let text = "按等級評分（選一個等級）：\n" + bands.map { "• " + $0.t + "（\($0.mk ?? 0) 分）" }.joined(separator: "\n")
            out.append(LMPoint(text: text, max: max(1, bands.compactMap { $0.mk }.max() ?? 1), got: nil))
        }
        return out
    }
}
struct ZLFile: Codable { let v: Int; let ch: String; let qs: [ZLQ] }

enum ZhLong {
    static func load(_ ch: String) -> ZLFile? {
        MathContent.shared.local((ch.hasPrefix("c-") ? "chemlong/" : "zhlong/") + "\(ch).json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(ZLFile.self, from: $0) }
    }
    static func typed(_ id: String) -> String { UserDefaults.standard.string(forKey: "zl.t." + id) ?? "" }
}

extension ZhLongSetView {
    func pick(_ x: String?) {
        chip = x; index = 0
        if let f = file { file = ZLFile(v: f.v, ch: f.ch, qs: x == nil ? all : all.filter { ($0.tg ?? []).contains(x!) || $0.asg == x }) }
    }
}

struct ZhLongSetView: View {
    let chapterID: String
    var src: String? = nil
    @State private var chip: String?
    @State private var all: [ZLQ] = []
    @Environment(\.tr) private var T
    @AppStorage("math.split.on") private var splitOn = true
    @State private var file: ZLFile?
    @State private var index = 0
    @State private var confirmHandIn = false
    @State private var confirmDone = false
    private var sheet: String { "zl-" + chapterID + (src.map { "-" + $0 } ?? "") }
    private var review: Bool { ReviewStore.shared.inReview(sheet) }
    private var chapter: MChapter? { MathLibrary.shared.chapter(chapterID) }

    var body: some View {
        Group {
            if let f = file, !f.qs.isEmpty {
                let q = f.qs[min(index, f.qs.count - 1)]
                WorkSplit(on: splitOn && ZLInput.mode(q.id) == "hand", sheetID: sheet, figs: [], ratio: 0.5) {
                    ZhLongQuestion(q: q, chapter: chapter, review: review, sheetID: sheet).id(q.id)
                        .environment(\.zhSerif, chapter?.isZh ?? true)
                        .deepSeek(ctx(q))
                } bar: {
                    let fs = src == "award" ? ChemKind.filters(all.map { ($0.tg, $0.asg) }) : []
                    if !fs.isEmpty {
                        Menu {
                            Button("全部") { pick(nil) }
                            ForEach(fs, id: \.self) { x in Button(ChemKind.chip(x)) { pick(x) } }
                        } label: { Label(chip.map(ChemKind.chip) ?? "全部", systemImage: "line.3.horizontal.decrease.circle") }
                    }
                    PageCluster(index: index, count: f.qs.count,
                                prev: index > 0 ? { index -= 1 } : nil,
                                next: index < f.qs.count - 1 ? { index += 1 } : nil)
                }
            } else if file != nil {
                ContentUnavailableView(T("No long questions yet", "这一课还没有长答题"), systemImage: "text.alignleft")
            } else {
                DownloadOverlay()
            }
        }
        .appScreen()
        .navigationTitle((chapter?.t ?? "") + ((chapter?.isChem ?? false) ? " · Long questions" : " · 長答"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation { splitOn.toggle() } } label: { Image(systemName: splitOn ? "rectangle.split.2x1.fill" : "rectangle.split.2x1") }
            }
            ToolbarItem(placement: .confirmationAction) {
                if review { Button(T("Done", "結算")) { confirmDone = true }.bold() }
                else { Button(T("Submit", "交卷")) { confirmHandIn = true } }
            }
        }
        .confirmationDialog(T("Hand in?", "確定交卷？"), isPresented: $confirmHandIn, titleVisibility: .visible) {
            Button(T("Submit", "交卷")) { ReviewStore.shared.handIn(sheet, title: "長答 · " + (chapter?.t ?? ""), route: "zlong:" + chapterID) }
            Button(T("Cancel", "取消"), role: .cancel) {}
        } message: { Text("交卷後可以看評分準則，逐點自評或讓 DeepSeek 批改。") }
        .confirmationDialog(settleText, isPresented: $confirmDone, titleVisibility: .visible) {
            Button(T("Done", "結算")) { ReviewStore.shared.finish(sheet) }
            Button(T("Cancel", "取消"), role: .cancel) {}
        }
        .workingSession(sheet)
        .task {
            await MathContent.shared.ensure(chapterID)
            let f = ZhLong.load(chapterID) ?? ZLFile(v: 1, ch: chapterID, qs: [])
            all = src == nil ? f.qs : f.qs.filter { ChemKind.key($0.src) == src }
            file = ZLFile(v: f.v, ch: f.ch, qs: all)
        }
    }

    private var settleText: String {
        let qs = file?.qs ?? []
        var got = 0, tot = 0, un = 0
        for q in qs {
            if let s = ProgressStore.shared.scores["zl:" + q.id] { got += s; tot += q.mk ?? q.points.reduce(0) { $0 + $1.max } } else { un += 1 }
        }
        return "得分 \(got)/\(tot)" + (un > 0 ? "（\(un) 題未評分）" : "") + "。草稿紙會被刪除，打字作答會保留。"
    }

    private func ctx(_ q: ZLQ) -> DSContext {
        var page = (q.l.map { $0 + "\n" } ?? "") + (q.ctx.map { "引文：" + $0 + "\n" } ?? "") + q.q
        let typed = ZhLong.typed(q.id)
        if !typed.isEmpty { page += "\n\n【學生打字作答】\n" + typed }
        let s = q.schemeText
        return DSContext(key: "zl-" + q.id, subject: chapter?.subjectID ?? "zh", title: (chapter?.t ?? "") + " · " + (q.l ?? "長答"), page: page,
                         revealed: review ? s : nil, answer: review ? nil : s,
                         chapter: chapter.map { DSContext.mathChapter($0) }, sheetID: ZLInput.mode(q.id) == "hand" ? sheet : nil)
    }
}

enum ZLInput {
    static func mode(_ id: String) -> String { UserDefaults.standard.string(forKey: "zl.m." + id) ?? "type" }
}

struct ZhLongQuestion: View {
    let q: ZLQ
    let chapter: MChapter?
    let review: Bool
    let sheetID: String
    @Environment(\.tr) private var T
    @AppStorage private var mode: String
    @AppStorage private var text: String

    init(q: ZLQ, chapter: MChapter?, review: Bool, sheetID: String) {
        self.q = q; self.chapter = chapter; self.review = review; self.sheetID = sheetID
        _mode = AppStorage(wrappedValue: "type", "zl.m." + q.id)
        _text = AppStorage(wrappedValue: "", "zl.t." + q.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(q.l ?? "").font(.subheadline.bold()).foregroundStyle(.secondary)
                    if let a = q.asg, !a.isEmpty { Text(a).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3).background(Color.orange.opacity(0.18), in: Capsule()) }
                    Spacer()
                    if let m = q.mk { Text("\(m) 分").font(.caption).foregroundStyle(.secondary) }
                }
                if let c = q.ctx, !c.isEmpty {
                    MathText(text: c, size: 17).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                MathText(text: q.q, size: 18)
                FigureStack(images: q.figImages)
                Picker("", selection: $mode) {
                    Text("打字").tag("type")
                    Text("手寫").tag("hand")
                }
                .pickerStyle(.segmented).frame(maxWidth: 240)
                if mode == "type" {
                    TextEditor(text: $text)
                        .font(Reading.font(17, serif: chapter?.isZh ?? true))
                        .frame(minHeight: 180)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .disabled(review)
                } else {
                    Text("在旁邊的草稿紙上作答（打開分屏）。").font(.footnote).foregroundStyle(.secondary)
                }
                if review {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(q.lbl ?? "評分準則").font(.headline)
                        ForEach(Array((q.pts ?? []).enumerated()), id: \.offset) { _, p in
                            HStack(alignment: .firstTextBaseline) {
                                Text(p.lv == true ? "▸" : "•")
                                MathText(text: p.t, size: 16)
                                Spacer(minLength: 0)
                                if let m = p.mk { Text("\(m)").font(.caption.monospacedDigit().bold()).foregroundStyle(.secondary) }
                            }
                        }
                        if let a = q.ans, !a.isEmpty { Divider(); Text("參考答案").font(.subheadline.bold()).foregroundStyle(.secondary); MathText(text: a, size: 16) }
                        if let n = q.note, !n.isEmpty { Text(n).font(.footnote).foregroundStyle(.secondary) }
                        if let a = q.also, !a.isEmpty { Text(a).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .card()
                    if q.na == true {
                        HStack(spacing: 8) {
                            ForEach([("不会", 0.0), ("部分对", 0.5), ("全对", 1.0)], id: \.0) { o in
                                let m = q.mk ?? 2
                                Button(o.0) { ProgressStore.shared.setScore("zl:" + q.id, Int((Double(m) * o.1).rounded()), max: m) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    LongMarkCard(key: "zl:" + q.id, question: q.q, scheme: q.schemeText, sheetID: mode == "hand" ? sheetID : nil,
                                 max: q.mk, score: Binding(get: { ProgressStore.shared.scores["zl:" + q.id] },
                                                           set: { ProgressStore.shared.setScore("zl:" + q.id, $0, max: q.mk ?? 0) }),
                                 points: q.points, answerText: mode == "type" ? text : nil,
                                 context: chapter.map { ($0.isChem ? "【本章资料】\n" : "【本章範文資料】\n") + DSContext.mathChapter($0) })
                }
            }
            .padding(.vertical)
            .readingMargin()
        }
        .softEdges()
    }
}

/// Chemistry source groups: 校内 / 公开试真题 / Award Scheme (unknown kinds → 其他).
enum ChemKind {
    static let order = ["school", "pastpaper", "award", "other"]
    static func key(_ k: String?) -> String { let k = (k ?? "school").lowercased(); return order.contains(k) ? k : "other" }
    static func name(_ k: String) -> String {
        switch k { case "school": return "校内"; case "pastpaper": return "公开试真题"; case "award": return "Award Scheme"; default: return "其他" }
    }
    /// Chip filters present: "@", "#", then assignments in order.
    static func filters(_ xs: [([String]?, String?)]) -> [String] {
        var out: [String] = []
        for t in ["@", "#"] where xs.contains(where: { ($0.0 ?? []).contains(t) }) { out.append(t) }
        for a in xs.compactMap({ $0.1 }) where !a.isEmpty && !out.contains(a) { out.append(a) }
        return out
    }
    static func chip(_ f: String) -> String {
        switch f { case "@": return "UT3 Award Scheme (@)"; case "#": return "Ch28–30 (#)"; default: return f }
    }
    static func groups<T>(_ xs: [T], chem: Bool, kind: KeyPath<T, String>) -> [(String, [T])] {
        guard chem else { return [("", xs)] }
        return order.compactMap { k in
            let g = xs.filter { key($0[keyPath: kind]) == k }
            return g.isEmpty ? nil : (name(k), g)
        }
    }
}

/// Long-question rows for a Chem chapter, one per source group present.
struct ChemLongRows: View {
    let chapterID: String
    @State private var srcs: [String] = []
    var body: some View {
        Group {
            if srcs.isEmpty {
                NavigationLink { ZhLongSetView(chapterID: chapterID) } label: { Label("长题（结构 / 论述）", systemImage: "text.alignleft") }
            }
            ForEach(srcs, id: \.self) { k in
                NavigationLink { ZhLongSetView(chapterID: chapterID, src: k) } label: { Label("长题 · " + ChemKind.name(k), systemImage: "text.alignleft") }
            }
        }
        // Recompute after the chapter download finishes (first open used to show only one mixed row).
        .task(id: MathContent.shared.loading.count) {
            let qs = ZhLong.load(chapterID)?.qs ?? []
            srcs = ChemKind.order.filter { k in qs.contains { ChemKind.key($0.src) == k } }
        }
    }
}
