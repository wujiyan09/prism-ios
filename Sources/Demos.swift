import SwiftUI
import WebKit

// MARK: - Step player shared by all animated demos

struct StepPlayer<Content: View>: View {
    let count: Int
    @Binding var step: Int
    @ViewBuilder var content: (Int) -> Content
    @Environment(\.tr) private var T
    @State private var playing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content(min(step, max(count - 1, 0)))
                .animation(.easeInOut(duration: 0.35), value: step)
            if count > 1 {
                HStack(spacing: 8) {
                    Button { playing = false; step = 0 } label: { Label(T("Reset", "重置"), systemImage: "backward.end.fill") }
                    Button { playing = false; step = max(0, step - 1) } label: { Label(T("Back", "上一步"), systemImage: "chevron.left") }
                        .disabled(step == 0)
                    Button {
                        if step >= count - 1 { step = 0 }
                        playing.toggle()
                    } label: { Label(playing ? T("Pause", "暂停") : T("Play", "播放"), systemImage: playing ? "pause.fill" : "play.fill") }
                        .glassButton(prominent: true)
                    Button { playing = false; step = min(count - 1, step + 1) } label: { Label(T("Step", "下一步"), systemImage: "chevron.right") }
                        .disabled(step >= count - 1)
                    Spacer()
                    Text("\(step + 1)/\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .labelStyle(.iconOnly)
                .glassButton()
                .controlSize(.small)
            }
        }
        .task(id: playing) {
            while playing {
                try? await Task.sleep(for: .seconds(1.1))
                if !playing { break }
                if step < count - 1 { step += 1 } else { playing = false }
            }
        }
    }
}

struct DemoView: View {
    let demo: Demo
    @Environment(\.tr) private var T
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "play.rectangle").font(.headline)
            switch demo.type {
            case "base_convert": BaseConvertDemo(d: demo, step: $step)
            case "twos_complement": TwosDemo(d: demo, step: $step)
            case "binary_add": BinaryAddDemo(d: demo, step: $step)
            case "sort": SortDemo(d: demo, step: $step)
            case "search": SearchDemo(d: demo, step: $step)
            case "sql": SQLDemo(d: demo, step: $step)
            case "live_html": LiveHTMLDemo(d: demo)
            case "run": RunDemo(lang: demo.lang, src: demo.src, stdin: demo.stdin)
            case "trace": TraceDemo(d: demo, step: $step)
            case "caesar": CaesarDemo(d: demo, step: $step)
            case "steps": StepsDemo(d: demo, step: $step)
            default: EmptyView()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.accentColor.opacity(0.3)))
    }

    private var title: String {
        switch demo.type {
        case "base_convert": return T("Base \(demo.from) → base \(demo.to)", "\(demo.from) 进制 → \(demo.to) 进制")
        case "twos_complement": return T("Two's complement", "补码")
        case "binary_add": return T("Binary addition", "二进制加法")
        case "sort": return T("\(demo.algo.capitalized) sort", "\(demo.algo.capitalized) sort 排序")
        case "search": return T("\(demo.algo.capitalized) search", "\(demo.algo.capitalized) search 查找")
        case "sql": return "SQL"
        case "live_html": return T("Live preview", "实时预览")
        case "run": return T("Try it", "动手试试")
        case "trace": return T("Trace table", "追踪表")
        case "caesar": return T("Caesar cipher", "凯撒密码")
        case "steps": return demo.title.isEmpty ? T("Step by step", "分步演示") : demo.title
        default: return demo.type
        }
    }
}

private struct Cell: View {
    let text: String
    var color: Color? = nil
    var bold = false
    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced).weight(bold ? .bold : .regular))
            .frame(minWidth: 28, minHeight: 32)
            .padding(.horizontal, 4)
            .background((color ?? Color(uiColor: .tertiarySystemFill)).opacity(color == nil ? 1 : 0.3),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct Caption: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
    }
}

// MARK: base_convert

struct BaseConvertDemo: View {
    let d: Demo
    @Binding var step: Int
    @Environment(\.tr) private var T

    struct Row: Hashable { let a: String; let b: String; let c: String }

    var body: some View {
        let digits = "0123456789ABCDEF"
        let v = Int(d.value.uppercased(), radix: d.from) ?? 0
        let src = d.value.uppercased()
        // Part 1: to decimal by place values (if not already decimal)
        var rows: [(String, Row?)] = []
        var hdr1 = ""
        if d.from != 10 {
            hdr1 = T("Place values", "位值")
            var sum = 0
            for (i, ch) in src.enumerated() {
                let p = src.count - 1 - i
                let dv = Int(String(ch), radix: d.from) ?? 0
                sum += dv * Int(pow(Double(d.from), Double(p)))
                rows.append((T("\(ch) × \(d.from)^\(p) = \(dv * Int(pow(Double(d.from), Double(p))))", "\(ch) × \(d.from)^\(p) = \(dv * Int(pow(Double(d.from), Double(p))))"),
                             Row(a: "\(ch)", b: "\(d.from)^\(p)", c: "\(dv * Int(pow(Double(d.from), Double(p))))")))
            }
            rows.append((T("Add them: \(sum)", "相加：\(sum)"), nil))
        }
        var divRows: [Row] = []
        if d.to != 10 {
            var x = v
            if x == 0 { divRows.append(Row(a: "0", b: "0", c: "0")) }
            while x > 0 {
                let r = x % d.to
                divRows.append(Row(a: "\(x) ÷ \(d.to)", b: "\(x / d.to)", c: String(digits[digits.index(digits.startIndex, offsetBy: r)])))
                x /= d.to
            }
        }
        let result = String(v, radix: d.to).uppercased()
        let total = rows.count + divRows.count + 1
        return StepPlayer(count: total, step: $step) { s in
            VStack(alignment: .leading, spacing: 8) {
                if !rows.isEmpty {
                    Text(hdr1).font(.subheadline.bold())
                    ForEach(Array(rows.prefix(min(s + 1, rows.count)).enumerated()), id: \.offset) { _, r in
                        Text(r.0).font(.body.monospaced())
                    }
                }
                if !divRows.isEmpty && s >= rows.count {
                    Text(T("Divide by \(d.to), keep the remainders", "不断除以 \(d.to)，记下余数")).font(.subheadline.bold())
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow { Text(T("Division", "除法")); Text(T("Quotient", "商")); Text(T("Remainder", "余数")) }
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(divRows.prefix(min(s - rows.count + 1, divRows.count)).enumerated()), id: \.offset) { _, r in
                            GridRow { Text(r.a); Text(r.b); Text(r.c).bold().foregroundStyle(Color.accentColor) }
                                .font(.body.monospaced())
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
                if s == total - 1 {
                    HStack {
                        Text("\(src)\(sub(d.from)) = ").font(.title3.monospaced())
                        Text("\(result)\(sub(d.to))").font(.title3.monospaced().bold()).foregroundStyle(Color.good)
                    }
                    if d.to != 10 { Caption(text: T("Read the remainders from bottom to top.", "余数从下往上读。")) }
                }
            }
        }
    }
    private func sub(_ b: Int) -> String {
        let m: [Character: Character] = ["0": "₀", "1": "₁", "2": "₂", "6": "₆", "8": "₈"]
        return String(String(b).map { m[$0] ?? $0 })
    }
}

// MARK: twos_complement

struct TwosDemo: View {
    let d: Demo
    @Binding var step: Int
    @Environment(\.tr) private var T

    var body: some View {
        let v = Int(d.value) ?? 0
        let n = max(2, min(32, d.bits))
        let lo = -(1 << (n - 1)), hi = (1 << (n - 1)) - 1
        let fits = v >= lo && v <= hi
        func bits(_ x: Int) -> String {
            let u = x & ((1 << n) - 1)
            let s = String(u, radix: 2)
            return String(repeating: "0", count: max(0, n - s.count)) + s
        }
        let pos = bits(abs(v))
        let inv = String(pos.map { $0 == "0" ? "1" : "0" })
        let res = bits(v)
        var frames: [(String, String)] = [(T("Write +\(abs(v)) in \(n)-bit binary", "把 +\(abs(v)) 写成 \(n) 位二进制"), pos)]
        if v < 0 {
            frames.append((T("Invert every bit (0↔1)", "每一位取反（0↔1）"), inv))
            frames.append((T("Add 1", "加 1"), res))
        }
        frames.append((T("Result: \(v) = \(res)", "结果：\(v) = \(res)"), res))
        return StepPlayer(count: fits ? frames.count : 1, step: $step) { s in
            VStack(alignment: .leading, spacing: 8) {
                if !fits {
                    Label(T("Overflow: \(v) is outside \(lo)…\(hi) for \(n) bits.", "溢出：\(v) 超出 \(n) 位范围 \(lo)…\(hi)。"),
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.bad)
                } else {
                    ForEach(0...s, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(frames[i].0).font(.subheadline)
                            HStack(spacing: 3) {
                                ForEach(Array(frames[i].1.enumerated()), id: \.offset) { j, ch in
                                    let changed = i > 0 && j < frames[i - 1].1.count && Array(frames[i - 1].1)[j] != ch
                                    Cell(text: String(ch), color: changed ? .accentColor : (j == 0 && i == frames.count - 1 ? .orange : nil), bold: i == s)
                                }
                            }
                        }
                        .transition(.opacity)
                    }
                    if s == frames.count - 1 {
                        Caption(text: T("The first bit is the sign bit: 1 means negative. Range for \(n) bits: \(lo) to \(hi).", "最高位是符号位：1 表示负数。\(n) 位的范围是 \(lo) 到 \(hi)。"))
                    }
                }
            }
        }
    }
}

// MARK: binary_add

struct BinaryAddDemo: View {
    let d: Demo
    @Binding var step: Int
    @Environment(\.tr) private var T

    var body: some View {
        let n = max(d.bits, max(d.a.count, d.b.count))
        let A = Array(String(repeating: "0", count: max(0, n - d.a.count)) + d.a).map { $0 == "1" ? 1 : 0 }
        let B = Array(String(repeating: "0", count: max(0, n - d.b.count)) + d.b).map { $0 == "1" ? 1 : 0 }
        var sum = Array(repeating: -1, count: n)
        var carry = Array(repeating: 0, count: n + 1)  // carry into column i (from right)
        var states: [(sum: [Int], carry: [Int], col: Int)] = []
        var c = 0
        for k in 0..<n {
            let i = n - 1 - k
            let t = A[i] + B[i] + c
            sum[i] = t % 2; c = t / 2
            if i > 0 { carry[i - 1] = c } else { carry[n] = c }
            states.append((sum, carry, i))
        }
        let sa = A[0], sb = B[0], ss = sum[0]
        let overflow = sa == sb && ss != sa
        return StepPlayer(count: states.count + 1, step: $step) { s in
            let st = states[min(s, states.count - 1)]
            VStack(alignment: .leading, spacing: 6) {
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    GridRow {
                        Text(T("carry", "进位")).font(.caption).foregroundStyle(.secondary)
                        ForEach(0..<n, id: \.self) { i in
                            Text(st.carry[i] == 1 && i < n - 1 && n - 1 - i <= s ? "1" : " ").font(.caption.monospaced()).foregroundStyle(.orange)
                        }
                    }
                    GridRow { Text("A").font(.caption); ForEach(0..<n, id: \.self) { i in Cell(text: "\(A[i])", color: i == st.col && s < states.count ? .accentColor : nil) } }
                    GridRow { Text("+ B").font(.caption); ForEach(0..<n, id: \.self) { i in Cell(text: "\(B[i])", color: i == st.col && s < states.count ? .accentColor : nil) } }
                    GridRow {
                        Text("=").font(.caption)
                        ForEach(0..<n, id: \.self) { i in Cell(text: st.sum[i] < 0 ? " " : "\(st.sum[i])", color: st.sum[i] < 0 ? nil : .good, bold: true) }
                    }
                }
                if s < states.count {
                    let i = st.col
                    let t = A[i] + B[i] + (s == 0 ? 0 : states[s - 1].carry[i])
                    Caption(text: T("Column \(n - i): \(A[i]) + \(B[i])\(s == 0 ? "" : " + carry \(states[s - 1].carry[i])") = \(t) → write \(t % 2), carry \(t / 2)",
                                    "第 \(n - i) 列：\(A[i]) + \(B[i])\(s == 0 ? "" : " + 进位 \(states[s - 1].carry[i])") = \(t) → 写 \(t % 2)，进 \(t / 2)"))
                } else {
                    if carry[n] == 1 { Caption(text: T("A carry comes out of the last column and is discarded.", "最高位还有进位，被丢弃。")) }
                    Label(overflow ? T("Overflow: two numbers with the same sign gave a result with the other sign.", "溢出：两个同号数相加，结果符号相反。")
                                   : T("No overflow (signed).", "没有溢出（有符号数）。"),
                          systemImage: overflow ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .foregroundStyle(overflow ? Color.bad : Color.good)
                }
            }
        }
    }
}

// MARK: sort

struct SortState { var a: [Int]; var hl: Set<Int>; var done: Set<Int>; var note: String }

enum SortTrace {
    static func run(_ algo: String, _ input: [Int], _ T: Tr) -> [SortState] {
        var a = input
        var out = [SortState(a: a, hl: [], done: [], note: T("Start", "开始"))]
        let n = a.count
        switch algo {
        case "selection":
            var done = Set<Int>()
            for i in 0..<max(0, n - 1) {
                var m = i
                for j in (i + 1)..<n {
                    out.append(SortState(a: a, hl: [m, j], done: done, note: T("Compare \(a[j]) with smallest so far \(a[m])", "比较 \(a[j]) 和目前最小的 \(a[m])")))
                    if a[j] < a[m] { m = j }
                }
                a.swapAt(i, m); done.insert(i)
                out.append(SortState(a: a, hl: [i, m], done: done, note: T("Swap the smallest into position \(i + 1)", "把最小值换到第 \(i + 1) 位")))
            }
        case "insertion":
            if n > 1 {
                for i in 1..<n {
                    var j = i
                    out.append(SortState(a: a, hl: [i], done: Set(0..<i), note: T("Insert \(a[i]) into the sorted part", "把 \(a[i]) 插入前面已排序部分")))
                    while j > 0 && a[j - 1] > a[j] {
                        a.swapAt(j, j - 1); j -= 1
                        out.append(SortState(a: a, hl: [j], done: [], note: T("Shift left", "向左移")))
                    }
                }
            }
        case "merge":
            var w = 1
            while w < n {
                var lo = 0
                while lo < n - w {
                    let mid = lo + w, hi = min(lo + 2 * w, n)
                    let merged = Array(a[lo..<mid] + a[mid..<hi]).sorted()
                    a.replaceSubrange(lo..<hi, with: merged)
                    out.append(SortState(a: a, hl: Set(lo..<hi), done: [], note: T("Merge two sorted runs of size \(w)", "合并两段长度 \(w) 的有序序列")))
                    lo += 2 * w
                }
                w *= 2
            }
        case "quick":
            func qs(_ lo: Int, _ hi: Int) {
                guard lo < hi else { return }
                let p = a[hi]; var i = lo
                out.append(SortState(a: a, hl: [hi], done: [], note: T("Pivot = \(p)", "基准值 = \(p)")))
                for j in lo..<hi where a[j] < p {
                    a.swapAt(i, j)
                    out.append(SortState(a: a, hl: [i, j], done: [], note: T("\(a[i]) < \(p): move left", "\(a[i]) < \(p)：放左边")))
                    i += 1
                }
                a.swapAt(i, hi)
                out.append(SortState(a: a, hl: [i], done: [], note: T("Pivot \(p) in its final place", "基准值 \(p) 放到最终位置")))
                qs(lo, i - 1); qs(i + 1, hi)
            }
            qs(0, n - 1)
        default: // bubble
            var done = Set<Int>()
            for p in 0..<max(0, n - 1) {
                var swapped = false
                for j in 0..<(n - 1 - p) {
                    if a[j] > a[j + 1] {
                        a.swapAt(j, j + 1); swapped = true
                        out.append(SortState(a: a, hl: [j, j + 1], done: done, note: T("Pass \(p + 1): \(a[j + 1]) > \(a[j]), swap", "第 \(p + 1) 轮：\(a[j + 1]) > \(a[j])，交换")))
                    } else {
                        out.append(SortState(a: a, hl: [j, j + 1], done: done, note: T("Pass \(p + 1): \(a[j]) ≤ \(a[j + 1]), keep", "第 \(p + 1) 轮：\(a[j]) ≤ \(a[j + 1])，不换")))
                    }
                }
                done.insert(n - 1 - p)
                if !swapped { out.append(SortState(a: a, hl: [], done: done, note: T("No swaps in this pass: stop early", "这一轮没有交换：提早结束"))); break }
            }
        }
        out.append(SortState(a: a, hl: [], done: Set(0..<n), note: T("Sorted", "排好了")))
        return out
    }
}

struct Bars: View {
    let a: [Int]
    let hl: Set<Int>
    let done: Set<Int>
    var dim: Set<Int> = []
    var body: some View {
        let mx = max(1, a.map { abs($0) }.max() ?? 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(a.enumerated()), id: \.offset) { i, v in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hl.contains(i) ? Color.orange : (done.contains(i) ? Color.good : Color.accentColor))
                        .opacity(dim.contains(i) ? 0.25 : 1)
                        .frame(height: 16 + 100 * CGFloat(abs(v)) / CGFloat(mx))
                    Text("\(v)").font(.caption.monospacedDigit())
                }
                .frame(maxWidth: 44)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a.map(String.init).joined(separator: ", "))
    }
}

struct SortDemo: View {
    let d: Demo
    @Binding var step: Int
    @Environment(\.tr) private var T
    var body: some View {
        let states = SortTrace.run(d.algo.lowercased(), d.data.compactMap { Int($0) ?? Double($0).map { Int($0) } }, T)
        StepPlayer(count: states.count, step: $step) { s in
            VStack(alignment: .leading, spacing: 8) {
                Bars(a: states[s].a, hl: states[s].hl, done: states[s].done)
                Caption(text: states[s].note)
            }
        }
    }
}

// MARK: search

struct SearchDemo: View {
    let d: Demo
    @Binding var step: Int
    @Environment(\.tr) private var T
    var body: some View {
        let binary = d.algo.lowercased().hasPrefix("bin")
        var a = d.data.compactMap { Int($0) ?? Double($0).map { Int($0) } }
        if binary { a.sort() }
        let t = Int(d.target) ?? 0
        var frames: [(hl: Set<Int>, dim: Set<Int>, found: Set<Int>, note: String)] = []
        if binary {
            var lo = 0, hi = a.count - 1
            var excluded = Set<Int>()
            while lo <= hi {
                let m = (lo + hi) / 2
                if a[m] == t {
                    frames.append(([], excluded, [m], T("low=\(lo + 1), high=\(hi + 1), mid=\(m + 1): A[mid] = \(a[m]) → found", "low=\(lo + 1)，high=\(hi + 1)，mid=\(m + 1)：A[mid] = \(a[m]) → 找到")))
                    break
                }
                frames.append(([m], excluded, [], T("low=\(lo + 1), high=\(hi + 1), mid=\(m + 1): \(a[m]) \(a[m] < t ? "<" : ">") \(t) → search the \(a[m] < t ? "right" : "left") half",
                                                    "low=\(lo + 1)，high=\(hi + 1)，mid=\(m + 1)：\(a[m]) \(a[m] < t ? "<" : ">") \(t) → 查\(a[m] < t ? "右" : "左")半边")))
                if a[m] < t { excluded.formUnion(lo...m); lo = m + 1 } else { excluded.formUnion(m...hi); hi = m - 1 }
            }
            if frames.last?.found.isEmpty ?? true { frames.append(([], Set(a.indices), [], T("low > high → not found", "low > high → 找不到"))) }
        } else {
            for (i, v) in a.enumerated() {
                if v == t { frames.append(([], Set(0..<i), [i], T("A[\(i + 1)] = \(v) → found after \(i + 1) comparisons", "A[\(i + 1)] = \(v) → 比较 \(i + 1) 次后找到"))); break }
                frames.append(([i], Set(0..<i), [], T("A[\(i + 1)] = \(v) ≠ \(t), next", "A[\(i + 1)] = \(v) ≠ \(t)，下一个")))
            }
            if frames.last?.found.isEmpty ?? true { frames.append(([], Set(a.indices), [], T("End of list → not found", "到了末尾 → 找不到"))) }
        }
        return StepPlayer(count: frames.count, step: $step) { s in
            VStack(alignment: .leading, spacing: 8) {
                Text(T("Target: \(t)", "目标：\(t)")).font(.subheadline.bold())
                Bars(a: a, hl: frames[s].hl, done: frames[s].found, dim: frames[s].dim)
                Caption(text: frames[s].note)
            }
        }
    }
}

// MARK: sql

struct SQLDemo: View {
    let d: Demo
    @Binding var step: Int
    @Environment(\.tr) private var T
    @State private var tables: [(String, ResultSet)] = []
    @State private var result: [ResultSet] = []
    @State private var error = ""
    @State private var query = ""

    var body: some View {
        StepPlayer(count: 2, step: $step) { s in
            VStack(alignment: .leading, spacing: 10) {
                if s == 0 {
                    ForEach(tables, id: \.0) { name, rs in
                        Text(name).font(.subheadline.bold())
                        ResultTables(sets: [rs])
                    }
                } else {
                    CodeEditor(text: $query, minHeight: 70)
                    Button(T("Run", "运行")) { run() }.glassButton()
                    if !error.isEmpty { Text(error).font(.callout.monospaced()).foregroundStyle(Color.bad) }
                    else { ResultTables(sets: result) }
                    if !d.note.isEmpty { Caption(text: d.note) }
                }
            }
        }
        .onAppear {
            guard tables.isEmpty else { return }
            query = d.query
            let db = SQLDatabase()
            _ = try? db.exec(d.setup)
            let names = ((try? db.exec("SELECT name FROM sqlite_master WHERE type='table' ORDER BY rowid")) ?? []).first?.rows.map { $0[0] } ?? []
            tables = names.compactMap { n in ((try? db.exec("SELECT * FROM \"\(n)\"")) ?? []).first.map { (n, $0) } }
            run()
        }
    }

    private func run() {
        let db = SQLDatabase()
        _ = try? db.exec(d.setup)
        do { result = try db.exec(query); error = "" } catch { self.error = error.localizedDescription; result = [] }
    }
}

// MARK: live_html

struct HTMLPreview: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.isOpaque = false
        w.backgroundColor = .white
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {
        if context.coordinator.last != html {
            context.coordinator.last = html
            w.loadHTMLString(html, baseURL: nil)
        }
    }
    func makeCoordinator() -> C { C() }
    final class C { var last = "" }
}

struct LiveHTMLDemo: View {
    let d: Demo
    @Environment(\.tr) private var T
    @State private var html = ""
    @State private var css = ""
    @State private var js = ""
    @State private var tab = 0
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $tab) {
                Text("HTML").tag(0)
                if !d.css.isEmpty || !css.isEmpty { Text("CSS").tag(1) }
                if !d.js.isEmpty || !js.isEmpty { Text("JS").tag(2) }
            }
            .pickerStyle(.segmented)
            CodeEditor(text: tab == 0 ? $html : (tab == 1 ? $css : $js), minHeight: 120)
            Text(T("Preview", "预览")).font(.caption).foregroundStyle(.secondary)
            HTMLPreview(html: "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>\(css)</style></head><body>\(html)<script>\(js)</script></body></html>")
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button(T("Reset", "重置")) { html = d.html; css = d.css; js = d.js }.glassButton().controlSize(.small)
        }
        .onAppear { if !loaded { html = d.html; css = d.css; js = d.js; loaded = true } }
    }
}

// MARK: run (Try it)

struct RunDemo: View {
    let lang: String
    let src: String
    var stdin = ""
    @Environment(\.tr) private var T
    @State private var code: String?
    @State private var output = ""
    @State private var error = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CodeEditor(text: Binding(get: { code ?? src }, set: { code = $0 }), minHeight: 100)
            HStack {
                Button { Task { await run() } } label: { Label(T("Run", "运行"), systemImage: "play.fill") }
                    .glassButton(prominent: true).disabled(running)
                Button(T("Reset", "重置")) { code = src; output = ""; error = "" }.glassButton()
                if running { ProgressView() }
            }
            .controlSize(.small)
            if !output.isEmpty || !error.isEmpty {
                Text(T("Output", "输出")).font(.caption).foregroundStyle(.secondary)
                if !output.isEmpty { CodeBlock(text: output, lang: "text") }
                if !error.isEmpty { Text(error).font(.callout.monospaced()).foregroundStyle(Color.bad).textSelection(.enabled) }
            }
        }
    }

    private func run() async {
        running = true
        let r = await Runner.free(lang: lang, code: code ?? src, stdin: stdin)
        output = r.out; error = r.err
        running = false
    }
}

// MARK: trace

struct TraceDemo: View {
    let d: Demo
    @Binding var step: Int
    @Environment(\.tr) private var T
    var body: some View {
        let lines = d.src.components(separatedBy: "\n")
        StepPlayer(count: max(1, d.rows.count), step: $step) { s in
            let row = d.rows.isEmpty ? nil : d.rows[s]
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        HStack(spacing: 8) {
                            Text("\(i + 1)").foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                            Text(Highlighter.highlight(l, lang: Highlighter.guess("", d.src)))
                            Spacer(minLength: 0)
                        }
                        .font(.callout.monospaced())
                        .padding(.vertical, 1)
                        .background(row?.line == i + 1 ? Color.orange.opacity(0.25) : .clear)
                    }
                }
                .padding(8)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        GridRow {
                            Text(T("Line", "行"))
                            ForEach(d.vars, id: \.self) { Text($0) }
                            Text(T("Output", "输出"))
                        }
                        .font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(Array(d.rows.prefix(s + 1).enumerated()), id: \.offset) { i, r in
                            GridRow {
                                Text("\(r.line)")
                                ForEach(d.vars, id: \.self) { v in
                                    let changed = i == 0 || d.rows[i - 1].vals[v] != r.vals[v]
                                    Text(r.vals[v] ?? "").foregroundStyle(changed ? Color.primary : Color.secondary)
                                }
                                Text(r.out)
                            }
                            .font(.callout.monospaced())
                            .fontWeight(i == s ? .bold : .regular)
                        }
                    }
                }
                let outs = d.rows.prefix(s + 1).map(\.out).filter { !$0.isEmpty }
                if !outs.isEmpty { Caption(text: T("Output so far: ", "目前输出：") + outs.joined(separator: " ")) }
            }
        }
    }
}

// MARK: caesar

struct CaesarDemo: View {
    let d: Demo
    @Binding var step: Int
    @Environment(\.tr) private var T
    var body: some View {
        let text = Array(d.text.uppercased())
        let k = ((d.shift % 26) + 26) % 26
        func enc(_ c: Character) -> Character {
            guard let a = c.asciiValue, a >= 65, a <= 90 else { return c }
            return Character(UnicodeScalar((Int(a) - 65 + k) % 26 + 65)!)
        }
        let alpha = (0..<26).map { Character(UnicodeScalar(65 + $0)!) }
        return StepPlayer(count: text.count + 1, step: $step) { s in
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 2) { ForEach(alpha, id: \.self) { c in Cell(text: String(c), color: s < text.count && text[s] == c ? .orange : nil) } }
                        HStack(spacing: 2) { ForEach(alpha, id: \.self) { c in Cell(text: String(enc(c)), color: s < text.count && enc(text[s]) == enc(c) && text[s] == c ? .good : nil) } }
                    }
                }
                HStack(spacing: 3) {
                    Text(T("Plain", "明文")).font(.caption).frame(width: 44, alignment: .leading)
                    ForEach(Array(text.enumerated()), id: \.offset) { i, c in Cell(text: String(c), color: i == s ? .orange : nil) }
                }
                HStack(spacing: 3) {
                    Text(T("Cipher", "密文")).font(.caption).frame(width: 44, alignment: .leading)
                    ForEach(Array(text.enumerated()), id: \.offset) { i, c in Cell(text: i < s || s == text.count ? String(enc(c)) : " ", color: i == s - 1 ? .good : nil, bold: true) }
                }
                Caption(text: s < text.count
                        ? T("\(text[s]) shifts \(k) places → \(enc(text[s]))", "\(text[s]) 向后移 \(k) 位 → \(enc(text[s]))")
                        : T("Key = \(k). The same key decrypts (shift back), so this is symmetric encryption.", "密钥 = \(k)。用同一个密钥往回移就能解密，所以这是对称加密。"))
            }
        }
    }
}

// MARK: steps (generic diagram)

struct StepsDemo: View {
    let d: Demo
    @Binding var step: Int
    @Environment(\.tr) private var T
    var body: some View {
        StepPlayer(count: max(1, d.frames.count), step: $step) { s in
            if d.frames.isEmpty { EmptyView() } else {
                let f = d.frames[s]
                VStack(alignment: .leading, spacing: 10) {
                    if let t = f.t, !t.isEmpty { Text(t).font(.subheadline.bold()) }
                    if let dg = f.diagram, !dg.nodes.isEmpty { DiagramView(diagram: dg, highlight: Set(f.hl ?? [])) }
                    if let hl = f.hl, !hl.isEmpty, f.diagram == nil {
                        HStack { ForEach(hl, id: \.self) { Text($0).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4).background(Color.orange.opacity(0.25), in: Capsule()) } }
                    }
                    RichText(html: T.en ? (f.en ?? f.zh ?? "") : (f.zh ?? f.en ?? ""))
                        .id(s)
                        .transition(.opacity)
                }
            }
        }
    }
}

struct DiagramView: View {
    let diagram: Diagram
    let highlight: Set<String>
    var body: some View {
        GeometryReader { geo in
            let pos = layout(geo.size)
            ZStack {
                ForEach(Array(diagram.edges.enumerated()), id: \.offset) { _, e in
                    if e.count >= 2, let a = pos[e[0]], let b = pos[e[1]] {
                        let on = diagram.active.contains(e[0]) && diagram.active.contains(e[1])
                        Path { p in p.move(to: a); p.addLine(to: b) }
                            .stroke(on ? Color.orange : Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: on ? 3 : 1.5, dash: on ? [] : [4, 3]))
                        if e.count >= 3, !e[2].isEmpty {
                            Text(e[2]).font(.caption2).padding(2)
                                .background(Color.cardBackground.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                                .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                        }
                    }
                }
                ForEach(diagram.nodes, id: \.id) { n in
                    let on = diagram.active.contains(n.id) || highlight.contains(n.label)
                    Text(n.label)
                        .font(.caption.bold())
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: 120)
                        .background(on ? Color.accentColor : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .shadow(color: on ? Color.accentColor.opacity(0.7) : .clear, radius: on ? 10 : 0)
                        .scaleEffect(on ? 1.06 : 1)
                        .position(pos[n.id] ?? .zero)
                }
            }
        }
        .frame(height: diagram.nodes.count > 4 ? 240 : 170)
        .accessibilityElement(children: .combine)
    }

    /// Nodes in a row when few, otherwise on an ellipse.
    private func layout(_ size: CGSize) -> [String: CGPoint] {
        let n = diagram.nodes.count
        var out: [String: CGPoint] = [:]
        if n <= 4 {
            for (i, node) in diagram.nodes.enumerated() {
                out[node.id] = CGPoint(x: size.width * (CGFloat(i) + 0.5) / CGFloat(max(n, 1)), y: size.height / 2)
            }
        } else {
            let rx = size.width / 2 - 60, ry = size.height / 2 - 26
            for (i, node) in diagram.nodes.enumerated() {
                let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
                out[node.id] = CGPoint(x: size.width / 2 + rx * CGFloat(cos(a)), y: size.height / 2 + ry * CGFloat(sin(a)))
            }
        }
        return out
    }
}

// MARK: - Code snippet with notes, input → output, Try it

struct CodeSnippetView: View {
    let snip: CodeSnip
    @Environment(\.tr) private var T
    @State private var tryIt = false
    @State private var showNotes = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CodeBlock(text: snip.src, lang: snip.lang)
            if !snip.notes.isEmpty {
                DisclosureGroup(isExpanded: $showNotes) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(snip.notes.enumerated()), id: \.offset) { _, n in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(n.l)").font(.caption.monospacedDigit().bold())
                                    .frame(minWidth: 22, minHeight: 20)
                                    .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                                RichText(html: T.en ? n.t : (n.tz ?? n.t))
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text(T("Line by line", "逐行解释")).font(.subheadline.bold())
                }
            }
            if !snip.input.isEmpty || !snip.output.isEmpty {
                let lines = snip.output.components(separatedBy: "\n")
                let errLast = lines.last.map { $0.range(of: #"(Error|Exception|Traceback)"#, options: .regularExpression) != nil } ?? false
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) { io(lines, errLast) }
                    VStack(alignment: .leading, spacing: 10) { io(lines, errLast) }
                }
            }
            if snip.run, ["python", "js", "javascript", "sql", "html"].contains(snip.lang.lowercased()) {
                Button { tryIt = true } label: { Label(T("Try it", "动手试试"), systemImage: "play.circle") }
                    .glassButton()
                    .sheet(isPresented: $tryIt) { TrySheet(snip: snip).environment(\.tr, T) }
            }
        }
    }

    @ViewBuilder private func io(_ lines: [String], _ errLast: Bool) -> some View {
        if !snip.input.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(T("Input", "输入")).font(.caption).foregroundStyle(.secondary)
                Text(snip.input).font(.callout.monospaced()).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }
            Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 26).accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(T("Output", "输出")).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                    Text(l.isEmpty ? " " : l).font(.callout.monospaced())
                        .foregroundStyle(errLast && i == lines.count - 1 ? Color.bad : Color.primary)
                }
            }
            .textSelection(.enabled)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background((errLast ? Color.bad.opacity(0.1) : Color(uiColor: .tertiarySystemFill)), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct TrySheet: View {
    let snip: CodeSnip
    @Environment(\.tr) private var T
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    switch snip.lang.lowercased() {
                    case "html":
                        LiveHTMLDemo(d: { var d = Demo.empty; d.html = snip.src; return d }())
                    case "sql":
                        SQLDemo(d: { var d = Demo.empty; d.query = snip.src; d.setup = snip.setup; return d }(), step: .constant(1))
                    default:
                        RunDemo(lang: snip.lang, src: snip.src, stdin: snip.input)
                    }
                }
                .padding()
            }
            .softEdges()
            .navigationTitle(T("Try it", "动手试试"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(T("Done", "完成")) { dismiss() } } }
        }
    }
}

extension Demo {
    static var empty: Demo {
        try! JSONDecoder().decode(Demo.self, from: Data("{}".utf8))
    }
}
