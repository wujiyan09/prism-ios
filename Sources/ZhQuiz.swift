import SwiftUI

// Chinese 範文 quiz screens. Sets are named "<UNIT>-<SEC>-<n>" (SEC = YW/ZC/FX/ZH).
// Custom ranges are passed to MathQuizRunner as "z-xxx:SEC" entries in MathQuizSpec.custom.

enum ZhSec {
    static let order = ["YW", "ZC", "FX", "ZH"]
    static func name(_ c: String) -> String {
        switch c {
        case "YW": return "原文"
        case "ZC": return "字詞解釋與翻譯"
        case "FX": return "文章分析"
        default: return "綜合"
        }
    }
    static func code(ofSet id: String) -> String {
        let p = id.split(separator: "-")
        return p.count >= 2 ? String(p[p.count - 2]) : "ZH"
    }
    /// True when a set belongs to a custom-range entry ("z-xxx" or "z-xxx:SEC").
    static func matches(_ entry: String, _ s: MCSet) -> Bool {
        let parts = entry.split(separator: ":").map(String.init)
        guard parts.first == s.ch else { return false }
        return parts.count < 2 || parts[1] == code(ofSet: s.id)
    }
    static func chapter(_ entry: String) -> String { String(entry.split(separator: ":").first ?? "") }
}

/// One 範文: sections, each with a quick-start slider and its sets.
struct ZhSetsView: View {
    let chapterID: String
    @Environment(ProgressStore.self) private var prog
    @State private var counts: [String: Double] = [:]
    var body: some View {
        let c = MathLibrary.shared.chapter(chapterID)
        let sets = c?.sets ?? []
        List {
            ForEach(ZhSec.order, id: \.self) { code in
                let ss = sets.filter { ZhSec.code(ofSet: $0.id) == code }
                if !ss.isEmpty {
                    let total = ss.reduce(0) { $0 + $1.n }
                    let n = Int(counts[code] ?? Double(min(15, total)))
                    Section {
                        ForEach(ss, id: \.id) { s in
                            NavigationLink(value: Route.mathQuiz(.set(s.id))) {
                                HStack {
                                    Image(systemName: "list.number").foregroundStyle(Color.accentColor).frame(width: 24)
                                    Text(s.l).font(.headline)
                                    Spacer()
                                    let st = prog.stat(s.qids.map { MathMC.key($0) })
                                    Text(st.done > 0 ? "\(st.correct)/\(st.total)" : "\(s.n) 題").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if total > 5 {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("隨機抽 \(n) 題").font(.subheadline)
                                Slider(value: Binding(get: { Double(min(max(n, 5), total)) }, set: { counts[code] = $0.rounded() }), in: 5...Double(max(total, 6)), step: 1)
                            }
                        }
                        NavigationLink(value: Route.mathQuiz(.custom(["\(chapterID):\(code)"], max(1, min(n, total)), true))) {
                            Label("開始 \(ZhSec.name(code)) 測驗", systemImage: "play.fill").bold()
                        }
                    } header: {
                        Text("\(ZhSec.name(code)) · \(total) 題")
                    } footer: {
                        Text("先出沒做過的題，再出做錯的題。")
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(c?.t ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await MathContent.shared.ensure(chapterID) }
    }
}

/// Custom range for Chinese: pick 範文 and sections, then a question count.
struct ZhCustomSection: View {
    @AppStorage("zh.quiz.chapters") private var pickedRaw = ""
    @AppStorage("zh.quiz.secs") private var secsRaw = "YW,ZC,FX,ZH"
    @AppStorage("zh.quiz.n") private var n = 20
    private let lib = MathLibrary.shared

    private var picked: Set<String> { Set(pickedRaw.split(separator: ",").map(String.init)) }
    private var secs: Set<String> { Set(secsRaw.split(separator: ",").map(String.init)) }
    private var chs: [MChapter] { lib.chapters("zh").filter { !$0.sets.isEmpty } }
    private var entries: [String] {
        chs.filter { picked.contains($0.id) }.flatMap { c in ZhSec.order.filter { secs.contains($0) }.map { "\(c.id):\($0)" } }
    }
    private var available: Int {
        chs.filter { picked.contains($0.id) }.reduce(0) { acc, c in
            acc + c.sets.filter { secs.contains(ZhSec.code(ofSet: $0.id)) }.reduce(0) { $0 + $1.n }
        }
    }

    var body: some View {
        Section {
            HStack {
                Button(picked.count == chs.count ? "全部取消" : "全選") {
                    pickedRaw = picked.count == chs.count ? "" : chs.map(\.id).joined(separator: ",")
                }
                Spacer()
                Text("已選 \(picked.count) 篇").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .listRowBackground(Color.cardBackground)
            ForEach(lib.books("zh")) { b in
                ForEach(b.chs.filter { !$0.sets.isEmpty }) { c in
                    Button { toggle(c.id) } label: {
                        HStack {
                            Image(systemName: picked.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(picked.contains(c.id) ? Color.accentColor : .secondary)
                            Text(c.t).foregroundStyle(.primary)
                            Spacer()
                            Text(b.nameZh).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
        } header: {
            Text("自訂範圍 · 範文")
        }

        Section {
            ForEach(ZhSec.order, id: \.self) { code in
                Toggle(ZhSec.name(code), isOn: Binding(get: { secs.contains(code) }, set: { on in
                    var s = secs
                    if on { s.insert(code) } else { s.remove(code) }
                    secsRaw = ZhSec.order.filter { s.contains($0) }.joined(separator: ",")
                }))
                .listRowBackground(Color.cardBackground)
            }
            VStack(alignment: .leading, spacing: 4) {
                let maxN = max(5, min(100, available))
                Text("\(min(n, maxN)) 題" + (available > 0 ? "（範圍內共 \(available) 題）" : "")).font(.subheadline)
                if maxN > 5 {
                    Slider(value: Binding(get: { Double(min(max(n, 5), maxN)) }, set: { n = Int($0.rounded()) }), in: 5...Double(maxN), step: 1)
                }
            }
            .listRowBackground(Color.cardBackground)
            NavigationLink(value: Route.mathQuiz(.custom(entries, max(1, min(n, max(available, 1))), true))) {
                Label("開始", systemImage: "play.fill").bold()
            }
            .disabled(entries.isEmpty)
            .listRowBackground(Color.cardBackground)
        } header: {
            Text("自訂範圍 · 部分")
        } footer: {
            Text("先出沒做過的題，再出做錯的題。")
        }
    }

    private func toggle(_ id: String) {
        var s = picked
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        pickedRaw = chs.map(\.id).filter { s.contains($0) }.joined(separator: ",")
    }
}
