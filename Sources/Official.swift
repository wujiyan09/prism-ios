import SwiftUI

/// Official materials in exam plans: school papers for the same assessment, HKCEE sets on the exam's chapters.
enum OfficialPlan {
    static func tasks(_ e: Exam) -> (mid: [PlanTask], late: [PlanTask]) {
        guard e.subject == "math" || e.subject == "chem", let idx = PP.index() else { return ([], []) }
        let chs = Set(e.chapters)
        let m2 = e.chapters.contains { $0.hasPrefix("m-m2") }
        let name = e.name.uppercased().replacingOccurrences(of: " ", with: "")
        let sj = e.subject == "chem" ? "CHEM" : (m2 ? "M2" : "MA")
        let school = (e.subject == "chem" ? ChemPP.schoolAsPP() : idx.school).filter { !$0.p.isEmpty && $0.sj == sj }
        func score(_ s: PPIndex.School) -> Int {
            let ak = s.ak.uppercased().replacingOccurrences(of: " ", with: "")
            return (!ak.isEmpty && name.contains(ak) ? 4 : 0) + (s.fm == "S5" ? 2 : 0) + (s.fm == "S4" ? 1 : 0)
        }
        let ranked = school.sorted { (score($0), $0.yr) > (score($1), $1.yr) }
        let matched = ranked.filter { score($0) >= 4 }
        let papers = Array((matched.isEmpty ? ranked : matched).prefix(matched.isEmpty ? 1 : 3))
        let ce = e.subject == "chem" ? [] : idx.ce.filter { !Set($0.chs).isDisjoint(with: chs) }.prefix(4)
        let mid = ce.map { PlanTask(id: "of-ce-" + $0.id, kind: .practice, chapterID: nil, topic: $0.id, minutes: 30) }
        // Oldest first so the most recent (most similar) paper lands closest to the exam.
        let late = papers.reversed().map { PlanTask(id: "of-sp-" + $0.id, kind: .mock, chapterID: nil, topic: $0.id, minutes: 60) }
        return (mid, late)
    }

    static func title(_ t: PlanTask) -> String? {
        guard t.id.hasPrefix("of-"), let idx = PP.index(), let id = t.topic else { return nil }
        if t.id.hasPrefix("of-sp-"), let s = (idx.school + ChemPP.schoolAsPP()).first(where: { $0.id == id }) {
            return "限时做学校卷 · \(s.yr) \(s.fm) \(s.sj) \(s.ak)" + (s.pp.isEmpty ? "" : " " + s.pp)
        }
        if let c = idx.ce.first(where: { $0.id == id }) { return "真题 · " + c.t }
        return nil
    }

    @MainActor
    static func start(_ t: PlanTask, _ e: Exam, _ scene: SceneModel, _ store: ExamStore) -> Bool {
        guard t.id.hasPrefix("of-"), let id = t.topic else { return false }
        store.tick(e.id, t.id)
        scene.open(.learn, t.id.hasPrefix("of-sp-") ? .mathPaper(id) : .ppSet(id))
        return true
    }
}

struct OfficialRoute: View {
    let id: String
    let set: Bool
    var body: some View {
        if let idx = PP.index() {
            if set, let c = idx.ce.first(where: { $0.id == id }) { PPSetView(info: c) }
            else if !set, let s = ChemPP.schoolAsPP().first(where: { $0.id == id }) { PPSchoolPaper(info: s, folder: "papers/chem/", group: "pp-c-" + s.id) }
            else if !set, let s = idx.school.first(where: { $0.id == id }) { PPSchoolPaper(info: s) }
            else { ContentUnavailableView("找不到这份试卷", systemImage: "doc.questionmark") }
        } else {
            ContentUnavailableView("先打开一次「真题」下载试卷目录", systemImage: "arrow.down.circle")
        }
    }
}

// MARK: - Chemistry papers (papers/chem/index.json)

struct ChemIndex: Codable {
    struct School: Codable, Hashable, Identifiable { let id: String; let yr: String; let fm: String?; let ak: String?; let tp: String?; let p: String?; let ms: String? }
    struct Topic: Codable, Hashable, Identifiable { let id: String; let t: String; let p: String?; let ms: String? }
    let school: [School]
    let topic: [Topic]?
}

enum ChemPP {
    static func index() -> ChemIndex? {
        MathContent.shared.local("papers/chem/index.json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(ChemIndex.self, from: $0) }
    }
    static func pp(_ s: ChemIndex.School) -> PPIndex.School {
        PPIndex.School(id: s.id, yr: s.yr, fm: s.fm ?? "", sj: "CHEM", ak: s.ak ?? "", pp: "", p: s.p ?? "", ms: s.ms ?? "", tp: s.tp)
    }
    static func schoolAsPP() -> [PPIndex.School] { (index()?.school ?? []).map(pp) }
}

struct ChemPapersHome: View {
    @Environment(\.tr) private var T
    @State private var idx: ChemIndex?
    @State private var failed = false
    var body: some View {
        List {
            Section { ImportLibraryLink() }.listRowBackground(Color.cardBackground)
            if let idx {
                let years = Array(Set(idx.school.map(\.yr))).sorted(by: >)
                ForEach(years, id: \.self) { y in
                    Section(T("School papers ", "学校卷 ") + y) {
                        ForEach(idx.school.filter { $0.yr == y }) { s in
                            NavigationLink { PPSchoolPaper(info: ChemPP.pp(s), folder: "papers/chem/", group: "pp-c-" + s.id) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text([s.fm, s.ak].compactMap { $0 }.joined(separator: " ")).font(.headline)
                                    if let t = s.tp, !t.isEmpty { Text(t).font(.caption).foregroundStyle(.secondary) }
                                    if (s.ms ?? "").isEmpty { Text(T("No marking scheme", "没有评分标准")).font(.caption).foregroundStyle(.orange) }
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
                if let tp = idx.topic, !tp.isEmpty {
                    Section(T("By topic", "按课题")) {
                        ForEach(tp) { t in
                            NavigationLink {
                                PPSchoolPaper(info: PPIndex.School(id: t.id, yr: "", fm: "", sj: "CHEM", ak: t.t, pp: "", p: t.p ?? "", ms: t.ms ?? "", tp: nil),
                                              folder: "papers/chem/", group: "pp-c-" + t.id)
                            } label: { Text(t.t) }
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            } else if failed {
                ContentUnavailableView(T("Not downloaded yet", "还没下载"), systemImage: "icloud.and.arrow.down")
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(T("Chemistry Past Papers", "化学真题"))
        .task {
            idx = ChemPP.index()
            if idx == nil { await MathContent.shared.ensure("meta"); idx = ChemPP.index(); failed = idx == nil }
        }
    }
}
