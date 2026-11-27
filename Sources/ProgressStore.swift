import Foundation
import Observation

struct HistEntry: Codable { var r: [Int] = []; var last: Double = 0 }
struct RunQ: Codable, Hashable { var l: String; var ok: Bool?; var key: String? = nil }
struct RunRecord: Codable, Identifiable {
    var t: Double; var title: String; var got: Int; var tot: Int
    /// Per-question results (new records only; older ones just have the score).
    var qs: [RunQ]? = nil
    var id: Double { t }
}
struct SheetState: Codable { var a: [Int: String] = [:]; var done = false; var score = 0 }
struct QuizPrefs: Codable {
    var n = 20
    var scope: [String] = []
    var types: [String] = ["mc"]
    var mix = 50.0
}

private struct SavedState: Codable {
    var hist: [String: HistEntry] = [:]
    var runs: [RunRecord] = []
    var sheets: [String: SheetState] = [:]
    var seen: [String] = []
    var quiz = QuizPrefs()
    var learned: [String]? = nil
    var marks: [String: Bool]? = nil
    var scores: [String: Int]? = nil
}

/// Study progress, shared by every window. Saved on device.
@Observable
final class ProgressStore {
    static let shared = ProgressStore()

    var hist: [String: HistEntry] = [:] { didSet { save() } }
    var runs: [RunRecord] = [] { didSet { save() } }
    var sheets: [String: SheetState] = [:] { didSet { save() } }
    var seen: Set<String> = [] { didSet { save() } }
    var quiz = QuizPrefs() { didSet { save() } }
    /// Chapters the student marked as learned.
    var learned: Set<String> = [] { didSet { save() } }
    /// Per-question ✓/✗ the student set (MC: auto, can be overridden). Synced as "mark/<key>".
    var marks: [String: Bool] = [:] { didSet { save() } }
    func mark(_ key: String) -> Bool? { marks[key] }
    func setMark(_ key: String, _ ok: Bool?) {
        let had = marks[key] != nil
        marks[key] = ok
        var e = hist[key] ?? HistEntry()
        if had, !e.r.isEmpty { e.r.removeLast() }
        if let ok { e.r.append(ok ? 1 : 0); e.r = Array(e.r.suffix(5)); e.last = Date().timeIntervalSince1970 }
        hist[key] = e.r.isEmpty ? nil : e
    }
    /// Self-awarded marks for long questions (nil = 未评分). Synced as "sc/<key>". Also feeds ✓/✗ history (≥ half = ✓).
    var scores: [String: Int] = [:] { didSet { save() } }
    func setScore(_ key: String, _ v: Int?, max: Int) {
        scores[key] = v
        setMark(key, v.map { max > 0 ? $0 * 2 >= max : $0 > 0 })
    }
    func toggleLearned(_ id: String) { if learned.contains(id) { learned.remove(id) } else { learned.insert(id) } }

    private var loading = false
    private let url: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("progress.json")
    }()

    init() {
        loading = true
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(SavedState.self, from: d) {
            hist = s.hist; runs = s.runs; sheets = s.sheets; seen = Set(s.seen); quiz = s.quiz; learned = Set(s.learned ?? []); marks = s.marks ?? [:]; scores = s.scores ?? [:]
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = SavedState(hist: hist, runs: runs, sheets: sheets, seen: Array(seen), quiz: quiz, learned: Array(learned), marks: marks, scores: scores)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
    }

    func record(_ key: String, ok: Bool) {
        var e = hist[key] ?? HistEntry()
        e.r.append(ok ? 1 : 0)
        e.r = Array(e.r.suffix(5))
        e.last = Date().timeIntervalSince1970
        hist[key] = e
    }

    /// nil = never done, true = last attempt right, false = last attempt wrong
    func lastResult(_ key: String) -> Bool? {
        guard let e = hist[key], let l = e.r.last else { return nil }
        return l == 1
    }

    /// Unseen first, then wrong, then right; random within each group.
    func prioritised(_ keys: [String]) -> [String] {
        let rank: (String) -> Int = { k in
            switch self.lastResult(k) { case nil: return 0; case false?: return 1; case true?: return 2 }
        }
        return keys.shuffled().enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map { $0.element }
    }

    func stat(_ keys: [String]) -> (done: Int, correct: Int, total: Int) {
        var d = 0, c = 0
        for k in keys { if let r = lastResult(k) { d += 1; if r { c += 1 } } }
        return (d, c, keys.count)
    }

    func saveRun(_ r: RunRecord) {
        var list = runs
        if let i = list.firstIndex(where: { $0.t == r.t }) { list[i] = r } else { list.insert(r, at: 0) }
        runs = Array(list.prefix(200))
    }

    func wrongMC(in lib: Library) -> [String] {
        hist.keys.filter { lib.items[$0]?.type == .mc && lastResult($0) == false }
    }

    func reset() {
        hist = [:]; runs = []; sheets = [:]; seen = []; learned = []
    }
}

import SwiftUI

// MARK: - 练习记录 (every 交卷 / 结算 result, newest first)

struct RunHistoryView: View {
    @State private var prog = ProgressStore.shared
    var filter: String? = nil
    private var runs: [RunRecord] { filter.map { f in prog.runs.filter { $0.title == f } } ?? prog.runs }
    var body: some View {
        List {
            if runs.isEmpty {
                ContentUnavailableView("还没有练习记录", systemImage: "checklist", description: Text("交卷或结算后，成绩和每题对错会记在这里。"))
                    .listRowBackground(Color.clear)
            }
            ForEach(runs) { r in
                NavigationLink { RunDetailView(run: r) } label: { RunRow(run: r) }
                    .listRowBackground(Color.cardBackground)
            }
        }
        .appScreen()
        .navigationTitle(filter == nil ? "练习记录" : "成绩")
    }
}

struct RunRow: View {
    let run: RunRecord
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title).lineLimit(2)
                Text(Date(timeIntervalSince1970: run.t).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(run.got)/\(run.tot)").font(.headline.monospacedDigit())
                .foregroundStyle(run.tot > 0 && run.got * 2 >= run.tot ? Color.green : Color.orange)
        }
    }
}

struct RunDetailView: View {
    let run: RunRecord
    var body: some View {
        List {
            Section {
                HStack { Text("得分"); Spacer(); Text("\(run.got)/\(run.tot)").font(.title3.bold().monospacedDigit()) }
                Text(Date(timeIntervalSince1970: run.t).formatted(date: .complete, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            .listRowBackground(Color.cardBackground)
            Section("每题") {
                if let qs = run.qs, !qs.isEmpty {
                    ForEach(Array(qs.enumerated()), id: \.offset) { _, q in
                        HStack(alignment: .top) {
                            Image(systemName: q.ok == true ? "checkmark.circle.fill" : (q.ok == false ? "xmark.circle.fill" : "minus.circle"))
                                .foregroundStyle(q.ok == true ? Color.green : (q.ok == false ? Color.red : Color.secondary))
                            Text(q.l.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)).font(.callout).lineLimit(3)
                        }
                    }
                } else {
                    Text("这条记录是旧版本存的，只有总分。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.cardBackground)
        }
        .appScreen()
        .navigationTitle(run.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
