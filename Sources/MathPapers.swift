import SwiftUI
import PDFKit

// MARK: - Maths 真题: HKCEE by-topic sets (text + LaTeX), school UT/exam PDFs, DSE (when added)

struct PPIndex: Codable {
    struct CE: Codable, Hashable, Identifiable { let id: String; let t: String; let pa: String; let yr: String; let n: Int; let mc: Int; let lq: Int; let chs: [String] }
    struct School: Codable, Hashable, Identifiable { let id: String; let yr: String; let fm: String; let sj: String; let ak: String; let pp: String; let p: String; let ms: String; let tp: String? }
    let ce: [CE]
    let school: [School]
}
struct PPQ: Codable, Hashable, Identifiable {
    let id: String; let ref: String; let ty: String; let mk: Int?; let q: String
    let o: [String]?; let fi: [String]?; let a: String; let ms: String; let ch: [String]?; let ob: Bool?
    var figImages: [UIImage] { (fi ?? []).compactMap { MathContent.shared.local("papers/fig/" + $0).flatMap { UIImage(contentsOfFile: $0.path) } } }
}
struct PPSet: Codable { let id: String; let t: String; let pa: String; let yr: String; let al: String; let qs: [PPQ] }

enum PP {
    static func index() -> PPIndex? {
        MathContent.shared.local("papers/index.json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(PPIndex.self, from: $0) }
    }
    static func set(_ id: String) -> PPSet? {
        MathContent.shared.local("papers/ce/\(id).json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(PPSet.self, from: $0) }
    }
    static func chapterName(_ id: String) -> String {
        if id == "m-junior" { return "初中" }
        if let c = MathLibrary.shared.chapters.first(where: { $0.id == id }) { return (id.hasPrefix("m-m2") ? "M2 " : "") + "Ch\(c.n)" }
        return id
    }
}

struct MathPapersHome: View {
    @Environment(\.tr) private var T
    @State private var idx: PPIndex?
    @State private var failed = false
    var body: some View {
        List {
            if let idx {
                Section {
                    Label(T("Official DSE papers appear here once added to your Drive folder.", "DSE 历届真题：放进 Drive 文件夹后会出现在这里。"), systemImage: "tray")
                        .font(.subheadline).foregroundStyle(.secondary)
                } header: { Text("HKDSE") }
                .listRowBackground(Color.cardBackground)
                Section {
                    ForEach(idx.ce) { s in
                        NavigationLink { PPSetView(info: s) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.t).font(.headline)
                                Text("\(s.yr) · " + (s.mc > 0 ? T("\(s.mc) MC ", "\(s.mc) 道选择 ") : "") + (s.lq > 0 ? T("\(s.lq) long", "\(s.lq) 道长题") : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text(T("HKCEE by topic", "HKCEE 会考 · 按课题")) } footer: {
                    Text(T("Answers are worked out, not official.", "答案为推导答案，非官方。"))
                }
                .listRowBackground(Color.cardBackground)
                let years = Array(Set(idx.school.map { $0.yr })).sorted(by: >)
                Section(T("School papers", "学校卷")) {
                    ForEach(years, id: \.self) { y in
                        NavigationLink { PPSchoolYear(year: y, items: idx.school.filter { $0.yr == y }) } label: {
                            LabeledContent("20" + y.prefix(2) + "–" + y.suffix(2), value: T("\(idx.school.filter { $0.yr == y }.count) papers", "\(idx.school.filter { $0.yr == y }.count) 份"))
                        }
                    }
                }
                .listRowBackground(Color.cardBackground)
            } else if failed {
                ContentUnavailableView(T("Not downloaded yet", "还没下载"), systemImage: "icloud.and.arrow.down")
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(T("Maths Past Papers", "数学真题"))
        .task {
            idx = PP.index()
            if idx == nil { await MathContent.shared.ensure("meta"); idx = PP.index(); failed = idx == nil }
        }
    }
}

struct PPSchoolYear: View {
    let year: String
    let items: [PPIndex.School]
    @Environment(\.tr) private var T
    var body: some View {
        List {
            ForEach(["S5", "S4"], id: \.self) { f in
                ForEach(["MA", "M2"], id: \.self) { sj in
                    let xs = items.filter { $0.fm == f && $0.sj == sj }
                    if !xs.isEmpty {
                        Section(f + " " + (sj == "MA" ? T("Maths", "数学") : "M2")) {
                            ForEach(xs) { s in
                                NavigationLink { PPSchoolPaper(info: s) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(s.ak + (s.pp.isEmpty ? "" : " " + s.pp)).font(.headline)
                                        if let t = s.tp, !t.isEmpty { Text(t).font(.caption).foregroundStyle(.secondary) }
                                        if s.p.isEmpty { Text(T("Marking scheme only", "只有评分标准")).font(.caption).foregroundStyle(.orange) }
                                        else if s.ms.isEmpty { Text(T("No marking scheme", "没有评分标准")).font(.caption).foregroundStyle(.orange) }
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(T("School papers ", "学校卷 ") + year)
    }
}

/// School paper PDF with the shared scratch sheet. 交卷 opens the marking scheme; 完成 deletes the sheet.
struct PPSchoolPaper: View {
    let info: PPIndex.School
    @Environment(\.tr) private var T
    @AppStorage("math.split.on") private var splitOn = true
    @State private var paper: PDFDocument?
    @State private var ms: PDFDocument?
    @State private var showMS = false
    @State private var confirmHandIn = false
    @State private var confirmDone = false
    private var sheet: String { "pp-" + info.id }
    private var title: String { "\(info.yr) \(info.fm) \(info.sj) \(info.ak)" + (info.pp.isEmpty ? "" : " " + info.pp) }
    private var review: Bool { ReviewStore.shared.inReview(sheet) || info.p.isEmpty }

    var body: some View {
        WorkSplit(on: splitOn, sheetID: sheet, figs: [], ratio: 0.5) {
            Group {
                if let d = (showMS && review) ? ms : paper ?? ms {
                    PDFKitView(doc: d, onPage: { _ in }).id(showMS)
                } else {
                    DownloadOverlay()
                }
            }
        } bar: { EmptyView() }
        .appScreen()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if review, !info.ms.isEmpty, !info.p.isEmpty {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $showMS) {
                        Text(T("Paper", "试卷")).tag(false)
                        Text(T("Marking scheme", "评分标准")).tag(true)
                    }.pickerStyle(.segmented).frame(width: 220)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation { splitOn.toggle() } } label: { Image(systemName: splitOn ? "rectangle.split.2x1.fill" : "rectangle.split.2x1") }
            }
            if !info.p.isEmpty {
                ToolbarItem(placement: .confirmationAction) {
                    if ReviewStore.shared.inReview(sheet) {
                        Button(T("Done", "完成")) { confirmDone = true }.bold()
                    } else {
                        Button(T("Submit", "交卷")) { confirmHandIn = true }
                    }
                }
            }
        }
        .confirmationDialog(T("Hand in?", "确定交卷？"), isPresented: $confirmHandIn, titleVisibility: .visible) {
            Button(T("Submit", "交卷")) { ReviewStore.shared.handIn(sheet, title: T("School paper · ", "学校卷 · ") + title, route: "paper:" + info.id); showMS = true }
            Button(T("Cancel", "取消"), role: .cancel) {}
        } message: { Text(T("Then the marking scheme opens. Your scratch sheet stays until you tap Done.", "交卷后可以看评分标准。草稿纸会保留到你按「完成」。")) }
        .confirmationDialog(T("Finish marking?", "自评完成？"), isPresented: $confirmDone, titleVisibility: .visible) {
            Button(T("Done", "完成")) { ReviewStore.shared.finish(sheet) }
            Button(T("Cancel", "取消"), role: .cancel) {}
        } message: { Text(T("The scratch sheet will be deleted.", "草稿纸会被删除。")) }
        .workingSession(sheet)
        .task {
            await MathContent.shared.ensure("pp-s-" + info.id)
            if !info.p.isEmpty { paper = MathContent.shared.local("papers/school/" + info.p).flatMap { PDFDocument(url: $0) } }
            if !info.ms.isEmpty { ms = MathContent.shared.local("papers/school/" + info.ms).flatMap { PDFDocument(url: $0) } }
        }
    }
}

/// HKCEE by-topic set: all questions on one sheet; 交卷 → answers + ✓/✗ → 完成.
struct PPSetView: View {
    let info: PPIndex.CE
    @Environment(\.tr) private var T
    @AppStorage("math.split.on") private var splitOn = true
    @State private var set: PPSet?
    @State private var index = 0
    @State private var picked: [String: Int] = [:]
    @State private var confirmHandIn = false
    @State private var confirmDone = false
    private var sheet: String { "pp-" + info.id }
    private var review: Bool { ReviewStore.shared.inReview(sheet) }

    var body: some View {
        Group {
            if let set, !set.qs.isEmpty {
                let q = set.qs[min(index, set.qs.count - 1)]
                WorkSplit(on: splitOn, sheetID: sheet, figs: splitOn ? q.figImages : [], ratio: 0.45) {
                    PPQuestionView(q: q, label: set.al, splitOn: splitOn, review: review, picked: Binding(get: { picked[q.id] }, set: { picked[q.id] = $0 }))
                        .id(q.id)
                } bar: {
                    PageCluster(index: index, count: set.qs.count,
                                prev: index > 0 ? { index -= 1 } : nil,
                                next: index < set.qs.count - 1 ? { index += 1 } : nil)
                }
            } else {
                DownloadOverlay()
            }
        }
        .appScreen()
        .navigationTitle(info.t)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation { splitOn.toggle() } } label: { Image(systemName: splitOn ? "rectangle.split.2x1.fill" : "rectangle.split.2x1") }
            }
            ToolbarItem(placement: .confirmationAction) {
                if review { Button(T("Done", "完成")) { confirmDone = true }.bold() }
                else { Button(T("Submit", "交卷")) { confirmHandIn = true } }
            }
        }
        .confirmationDialog(T("Hand in?", "确定交卷？"), isPresented: $confirmHandIn, titleVisibility: .visible) {
            Button(T("Submit", "交卷")) {
                ReviewStore.shared.handIn(sheet, title: T("Past paper · ", "真题 · ") + info.t, route: "ppset:" + info.id)
                for q in set?.qs ?? [] where q.ty == "mc" {
                    if let p = picked[q.id] { ProgressStore.shared.setMark("pp:" + q.id, ["A", "B", "C", "D", "E", "F"][min(p, 5)] == q.a.trimmingCharacters(in: .whitespaces)) }
                }
            }
            Button(T("Cancel", "取消"), role: .cancel) {}
        } message: { Text(T("Then answers open so you can mark each question ✓ or ✗. Your scratch sheet stays until you tap Done.", "交卷后可以看答案，逐题标 ✓ / ✗。草稿纸会保留到你按「完成」。")) }
        .confirmationDialog(T("Finish self-marking?", "自评完成？"), isPresented: $confirmDone, titleVisibility: .visible) {
            Button(T("Done", "完成")) { ReviewStore.shared.finish(sheet); picked = [:] }
            Button(T("Cancel", "取消"), role: .cancel) {}
        } message: { Text(T("The scratch sheet will be deleted.", "草稿纸会被删除。")) }
        .workingSession(sheet)
        .task {
            set = PP.set(info.id)
            if set == nil { await MathContent.shared.ensure("pp-" + info.id); set = PP.set(info.id) }
        }
    }
}

struct PPQuestionView: View {
    let q: PPQ
    let label: String
    var splitOn = false
    let review: Bool
    @Binding var picked: Int?
    @Environment(\.tr) private var T
    private let L = ["A", "B", "C", "D", "E", "F"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(q.ref).font(.subheadline.bold()).foregroundStyle(.secondary)
                    if let m = q.mk { Text(T("\(m) marks", "\(m) 分")).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if let c = q.ch { Text(c.map(PP.chapterName).joined(separator: " · ")).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3).background(Color.secondary.opacity(0.15), in: Capsule()) }
                }
                MathText(text: q.q, size: 18)
                if !splitOn { FigureStack(images: q.figImages) }
                if let o = q.o {
                    ForEach(Array(o.enumerated()), id: \.offset) { i, t in
                        let correct = review && L[min(i, 5)] == q.a.trimmingCharacters(in: .whitespaces)
                        Button { if !review { picked = i } } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                MCLetter(l: L[min(i, 5)])
                                MathText(text: t, size: 17)
                                Spacer(minLength: 0)
                                if correct { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                else if review && picked == i { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .mcGlass(review ? (correct ? .correct : (picked == i ? .wrong : .idle)) : (picked == i ? .selected : .idle))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if review {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(T("Answer", "答案")).font(.headline)
                            Spacer()
                            if !label.isEmpty { Text(label).font(.caption.bold()).foregroundStyle(.orange) }
                        }
                        MathText(text: q.a, size: 17)
                        if !q.ms.isEmpty {
                            Divider()
                            Text(T("Worked solution", "解析")).font(.subheadline.bold()).foregroundStyle(.secondary)
                            MathText(text: q.ms, size: 17)
                        }
                        MarkControl(key: "pp:" + q.id).padding(.top, 6)
                    }
                    .card()
                } else {
                    Text(T("Answers open after 交卷.", "交卷后才能看答案。")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical)
            .readingMargin()
        }
        .softEdges()
    }
}
