import SwiftUI

struct ToolsView: View {
    @Environment(\.tr) private var T
    var body: some View {
        List {
            RecentSection(section: .tools)
            ForEach(ToolKind.allCases) { k in
                NavigationLink(value: Route.tool(k)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.title(T))
                            Text(k.subtitle(T)).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: k.icon) }
                }
                .listRowBackground(Color.cardBackground)
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(T("Tools", "工具"))
        .sectionToolbar()
    }
}

struct ToolView: View {
    let kind: ToolKind
    @Environment(\.tr) private var T
    var body: some View {
        Group {
            switch kind {
            case .base: BaseTool()
            case .twos: TwosTool()
            case .subnet: SubnetTool()
            case .sql: SQLTool()
            case .trace: TraceTool()
            }
        }
        .appList()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(kind.title(T))
        .noteRecent(.tool(kind.rawValue), kind.title(T))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ValueRow: View {
    let label: String
    let value: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.body.monospaced()).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.monospaced()).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Number bases

struct BaseTool: View {
    @Environment(\.tr) private var T
    @State private var input = "200"
    @State private var base = 10

    var body: some View {
        let v = Int(input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: ""), radix: base)
        Form {
            Section {
                Picker(T("From", "原进制"), selection: $base) {
                    Text("10").tag(10); Text("2").tag(2); Text("8").tag(8); Text("16").tag(16)
                }
                .pickerStyle(.segmented)
                TextField(T("Value", "数值"), text: $input)
                    .font(.body.monospaced())
                    .keyboardType(base == 16 ? .asciiCapable : .numberPad)
                    .autocorrectionDisabled().textInputAutocapitalization(.characters)
            }
            .listRowBackground(Color.cardBackground)
            Section {
                if let v, v >= 0 {
                    ValueRow(label: T("Decimal", "十进制"), value: String(v))
                    ValueRow(label: T("Binary", "二进制"), value: group(String(v, radix: 2)))
                    ValueRow(label: T("Octal", "八进制"), value: String(v, radix: 8))
                    ValueRow(label: T("Hex", "十六进制"), value: String(v, radix: 16).uppercased())
                    ValueRow(label: T("Bits needed", "所需位数"), value: String(max(1, String(v, radix: 2).count)))
                } else {
                    Text(T("Not a valid base-\(base) number.", "不是有效的 \(base) 进制数。")).foregroundStyle(Color.bad)
                }
            }
            .listRowBackground(Color.cardBackground)
        }
    }

    private func group(_ s: String) -> String {
        let pad = String(repeating: "0", count: (4 - s.count % 4) % 4) + s
        return stride(from: 0, to: pad.count, by: 4).map { i in
            String(pad[pad.index(pad.startIndex, offsetBy: i)..<pad.index(pad.startIndex, offsetBy: i + 4)])
        }.joined(separator: " ")
    }
}

// MARK: Two's complement

struct TwosTool: View {
    @Environment(\.tr) private var T
    @State private var dec = "-45"
    @State private var bin = "11010011"
    @State private var a = "01100100"
    @State private var b = "00111100"

    static func toBits(_ v: Int) -> String {
        let u = v < 0 ? 256 + v : v
        let s = String(u, radix: 2)
        return String(repeating: "0", count: max(0, 8 - s.count)) + s
    }
    static func fromBits(_ s: String) -> Int? {
        guard s.count == 8, let u = Int(s, radix: 2) else { return nil }
        return u >= 128 ? u - 256 : u
    }

    var body: some View {
        Form {
            Section(T("Decimal → 8-bit", "十进制 → 8 位补码")) {
                TextField("-128…127", text: $dec).font(.body.monospaced()).keyboardType(.numbersAndPunctuation)
                if let v = Int(dec.trimmingCharacters(in: .whitespaces)), (-128...127).contains(v) {
                    ValueRow(label: T("Two's complement", "补码"), value: Self.toBits(v))
                    if v < 0 {
                        let pos = Self.toBits(-v)
                        let inv = String(pos.map { $0 == "0" ? "1" : "0" })
                        ValueRow(label: T("+\(-v) in binary", "+\(-v) 的二进制"), value: pos)
                        ValueRow(label: T("Invert bits", "取反"), value: inv)
                        ValueRow(label: T("Add 1", "加 1"), value: Self.toBits(v))
                    }
                } else {
                    Text(T("Enter a whole number from -128 to 127.", "请输入 -128 到 127 的整数。")).foregroundStyle(Color.bad)
                }
            }
            .listRowBackground(Color.cardBackground)
            Section(T("8-bit → decimal", "8 位补码 → 十进制")) {
                TextField("8 bits", text: $bin).font(.body.monospaced()).keyboardType(.numberPad)
                if let v = Self.fromBits(bin) {
                    ValueRow(label: T("Value", "数值"), value: String(v))
                    if bin.first == "1" { ValueRow(label: T("Working", "过程"), value: "-128 + \(v + 128)") }
                } else {
                    Text(T("Enter exactly 8 bits.", "请输入 8 位二进制。")).foregroundStyle(Color.bad)
                }
            }
            .listRowBackground(Color.cardBackground)
            Section {
                TextField("A", text: $a).font(.body.monospaced()).keyboardType(.numberPad)
                TextField("B", text: $b).font(.body.monospaced()).keyboardType(.numberPad)
                if let x = Self.fromBits(a), let y = Self.fromBits(b) {
                    let raw = (Int(a, radix: 2)! + Int(b, radix: 2)!)
                    let sum = Self.toBits(((raw % 256) + 256) % 256 >= 128 ? raw % 256 - 256 : raw % 256)
                    let real = x + y
                    let overflow = real < -128 || real > 127
                    ValueRow(label: "A + B", value: sum)
                    ValueRow(label: T("Decimal", "十进制"), value: "\(x) + \(y) = \(Self.fromBits(sum) ?? 0)")
                    ValueRow(label: T("Carry out", "最高位进位"), value: raw > 255 ? "1" : "0")
                    Label(overflow ? T("Overflow: the true answer \(real) does not fit in 8 bits.", "溢出：正确答案 \(real) 超出 8 位范围。")
                                   : T("No overflow.", "没有溢出。"),
                          systemImage: overflow ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .foregroundStyle(overflow ? Color.bad : Color.good)
                } else {
                    Text(T("Enter two 8-bit numbers.", "请输入两个 8 位二进制数。")).foregroundStyle(.secondary)
                }
            } header: {
                Text(T("Addition and overflow", "加法与溢出"))
            } footer: {
                Text(T("Overflow happens when two numbers with the same sign give a result with the other sign.", "两个同号数相加，结果符号变了，就是溢出。"))
            }
            .listRowBackground(Color.cardBackground)
        }
    }
}

// MARK: Subnet

struct SubnetTool: View {
    @Environment(\.tr) private var T
    @State private var ip = "192.168.10.77"
    @State private var prefix = 26

    var body: some View {
        Form {
            Section {
                TextField(T("IPv4 address", "IPv4 地址"), text: $ip).font(.body.monospaced()).keyboardType(.decimalPad)
                Stepper("/\(prefix)", value: $prefix, in: 0...32)
            }
            .listRowBackground(Color.cardBackground)
            Section {
                if let a = parse(ip) {
                    let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - UInt32(prefix))
                    let net = a & mask, bc = net | ~mask
                    ValueRow(label: T("Subnet mask", "子网掩码"), value: str(mask))
                    ValueRow(label: T("Network", "网络地址"), value: str(net) + "/\(prefix)")
                    ValueRow(label: T("Broadcast", "广播地址"), value: str(bc))
                    if prefix <= 30 {
                        ValueRow(label: T("Hosts", "可用主机"), value: "\(str(net + 1)) – \(str(bc - 1))")
                        ValueRow(label: T("Usable hosts", "可用主机数"), value: "2^\(32 - prefix) − 2 = \((1 << (32 - prefix)) - 2)")
                    }
                    ValueRow(label: T("Class (classful)", "类别（有类）"), value: cls(a))
                    ValueRow(label: T("Mask in binary", "掩码二进制"), value: bin(mask))
                } else {
                    Text(T("Not a valid IPv4 address.", "不是有效的 IPv4 地址。")).foregroundStyle(Color.bad)
                }
            }
            .listRowBackground(Color.cardBackground)
        }
    }

    private func parse(_ s: String) -> UInt32? {
        let p = s.trimmingCharacters(in: .whitespaces).split(separator: ".").compactMap { UInt32($0) }
        guard p.count == 4, p.allSatisfy({ $0 <= 255 }) else { return nil }
        return p.reduce(0) { $0 << 8 | $1 }
    }
    private func str(_ v: UInt32) -> String { (0..<4).map { String((v >> (24 - 8 * UInt32($0))) & 255) }.joined(separator: ".") }
    private func bin(_ v: UInt32) -> String {
        (0..<4).map { i -> String in
            let s = String((v >> (24 - 8 * UInt32(i))) & 255, radix: 2)
            return String(repeating: "0", count: 8 - s.count) + s
        }.joined(separator: ".")
    }
    private func cls(_ a: UInt32) -> String {
        let f = a >> 24
        return f < 128 ? "A" : f < 192 ? "B" : f < 224 ? "C" : f < 240 ? "D" : "E"
    }
}

// MARK: SQL playground

struct SQLTool: View {
    static let seed = """
    CREATE TABLE CLUB(CID TEXT PRIMARY KEY, CNAME TEXT, TEACHER TEXT);
    INSERT INTO CLUB VALUES('C1','Robotics','Mr Lam'),('C2','Orchestra','Ms Lee'),('C3','Coding','Mr Chan');
    CREATE TABLE STUDENT(SID TEXT PRIMARY KEY, NAME TEXT, CLASS TEXT, CID TEXT REFERENCES CLUB(CID));
    INSERT INTO STUDENT VALUES('S01','Tom Ho','5A','C3'),('S02','Amy Chan','5A','C2'),('S03','Ben Lau','5B','C1'),('S04','Cathy Ho','5B','C3'),('S05','David Ng','5C',NULL),('S06','Eva Lam','5A','C1'),('S07','Kelvin Yip','5C','C2');
    CREATE TABLE RESULT(SID TEXT, SUBJECT TEXT, SCORE INTEGER, PRIMARY KEY(SID,SUBJECT));
    INSERT INTO RESULT VALUES('S01','ICT',88),('S01','M2',75),('S02','ICT',64),('S02','M2',81),('S03','ICT',52),('S04','ICT',91),('S04','M2',60),('S05','ICT',47),('S06','ICT',73),('S07','ICT',69),('S07','M2',58);
    """
    static let examples = [
        "SELECT * FROM STUDENT;",
        "SELECT CLASS, COUNT(*) AS N FROM STUDENT GROUP BY CLASS;",
        "SELECT S.NAME, C.CNAME FROM STUDENT S, CLUB C WHERE S.CID = C.CID;",
        "SELECT NAME FROM STUDENT WHERE SID IN (SELECT SID FROM RESULT WHERE SUBJECT = 'ICT' AND SCORE > 70);",
        "SELECT S.NAME, C.CNAME FROM STUDENT S LEFT JOIN CLUB C ON S.CID = C.CID;",
    ]
    @Environment(\.tr) private var T
    @State private var db: SQLDatabase = SQLTool.fresh()
    @State private var sql = "SELECT * FROM STUDENT;"
    @State private var result: [ResultSet] = []
    @State private var error = ""
    @State private var ran = false

    static func fresh() -> SQLDatabase { let d = SQLDatabase(); _ = try? d.exec(seed); return d }

    var body: some View {
        Form {
            Section {
                CodeEditor(text: $sql, minHeight: 120)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                ViewThatFits(in: .horizontal) {
                    HStack { buttons }
                    VStack(alignment: .leading) { buttons }
                }
            } footer: {
                Text(T("Tables: CLUB(CID, CNAME, TEACHER), STUDENT(SID, NAME, CLASS, CID), RESULT(SID, SUBJECT, SCORE). Changes stay until you reset.", "数据表：CLUB(CID, CNAME, TEACHER)、STUDENT(SID, NAME, CLASS, CID)、RESULT(SID, SUBJECT, SCORE)。改动会保留，直到重置。"))
            }
            .listRowBackground(Color.cardBackground)
            if ran {
                Section(T("Result", "结果")) {
                    if !error.isEmpty {
                        Text(error).font(.callout.monospaced()).foregroundStyle(Color.bad)
                    } else {
                        ResultTables(sets: result)
                    }
                }
                .listRowBackground(Color.cardBackground)
            }
            Section(T("Examples", "例子")) {
                ForEach(Self.examples, id: \.self) { e in
                    Button { sql = e; run() } label: {
                        Text(e).font(.callout.monospaced()).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    }
                }
            }
            .listRowBackground(Color.cardBackground)
        }
    }

    @ViewBuilder private var buttons: some View {
        Button { run() } label: { Label(T("Run", "运行"), systemImage: "play.fill") }
            .glassButton(prominent: true)
            .keyboardShortcut("r", modifiers: .command)
        Button(role: .destructive) {
            db = Self.fresh(); result = []; error = ""; ran = false
        } label: { Label(T("Reset database", "重置数据库"), systemImage: "arrow.counterclockwise") }
            .glassButton()
    }

    private func run() {
        ran = true
        do { result = try db.exec(sql); error = "" } catch { self.error = error.localizedDescription; result = [] }
    }
}

// MARK: Algorithm tracer

struct TraceTool: View {
    enum Algo: String, CaseIterable, Identifiable { case bin, bub, bs, ls; var id: String { rawValue } }
    @Environment(\.tr) private var T
    @State private var algo: Algo = .bub
    @State private var input = "5, 1, 4, 2, 8"
    @State private var target = "4"

    var body: some View {
        Form {
            Section {
                Picker(T("Algorithm", "算法"), selection: $algo) {
                    Text(T("Decimal → binary", "十进制转二进制")).tag(Algo.bin)
                    Text(T("Bubble sort", "冒泡排序")).tag(Algo.bub)
                    Text(T("Binary search", "二分查找")).tag(Algo.bs)
                    Text(T("Linear search", "线性查找")).tag(Algo.ls)
                }
                TextField(algo == .bin ? T("Number", "数字") : T("List, comma separated", "数列，用逗号分隔"), text: $input)
                    .font(.body.monospaced()).keyboardType(.numbersAndPunctuation)
                if algo == .bs || algo == .ls {
                    TextField(T("Target", "目标"), text: $target).font(.body.monospaced()).keyboardType(.numbersAndPunctuation)
                }
            }
            .listRowBackground(Color.cardBackground)
            let r = trace()
            Section {
                if !r.note.isEmpty { Text(r.note).font(.callout).foregroundStyle(.secondary) }
                TableBlock(rows: [r.head.map { TableCell(text: AttributedString($0), header: true) }]
                           + r.rows.map { $0.map { TableCell(text: AttributedString($0), header: false) } })
                Text(r.summary).bold()
            }
            .listRowBackground(Color.cardBackground)
        }
    }

    private func trace() -> (head: [String], rows: [[String]], note: String, summary: String) {
        if algo == .bin {
            var x = Int(input.trimmingCharacters(in: .whitespaces)) ?? 0
            var rows: [[String]] = [], s = ""
            if x <= 0 { rows.append(["0", "0", "0"]) }
            while x > 0 { rows.append(["\(x)", "\(x % 2)", "\(x / 2)"]); s = "\(x % 2)" + s; x /= 2 }
            return (["X", T("X mod 2 (output)", "X mod 2（输出）"), "X ← X div 2"], rows, "",
                    T("Remainders in order: \(rows.map { $0[1] }.joined()). Read backwards: \(s.isEmpty ? "0" : s)",
                      "余数按顺序输出：\(rows.map { $0[1] }.joined())；倒过来读才是二进制：\(s.isEmpty ? "0" : s)"))
        }
        var a = input.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let t = Int(target.trimmingCharacters(in: .whitespaces)) ?? 0
        switch algo {
        case .bub:
            var rows: [[String]] = []
            let n = a.count
            var passes = 0
            if n > 1 {
                for p in 1..<n {
                    passes = p
                    var sw = false
                    for i in 0..<(n - p) {
                        let c = "\(a[i]) > \(a[i + 1])?"
                        if a[i] > a[i + 1] { a.swapAt(i, i + 1); sw = true; rows.append(["\(p)", "\(i + 1)", c + T(" swap", " 交换"), a.map(String.init).joined(separator: ", ")]) }
                        else { rows.append(["\(p)", "\(i + 1)", c + T(" keep", " 不换"), a.map(String.init).joined(separator: ", ")]) }
                    }
                    if !sw { rows.append(["\(p)", "-", T("No swaps in this pass, stop early", "这一轮没有交换，提早结束"), a.map(String.init).joined(separator: ", ")]); break }
                }
            }
            return (["Pass", T("Position", "比较位置"), T("Compare", "比较"), T("List", "数列")], rows, "",
                    T("Sorted after \(passes) passes: ", "\(passes) 轮后排好：") + a.map(String.init).joined(separator: ", "))
        case .bs:
            a.sort()
            var lo = 0, hi = a.count - 1, rows: [[String]] = [], f = -1
            while lo <= hi {
                let m = (lo + hi) / 2
                let act = a[m] == t ? T("found", "找到") : a[m] < t ? T("target bigger → low = mid+1", "目标较大 → low = mid+1") : T("target smaller → high = mid−1", "目标较小 → high = mid−1")
                rows.append(["\(lo + 1)", "\(hi + 1)", "\(m + 1)", "\(a[m])", act])
                if a[m] == t { f = m; break }
                if a[m] < t { lo = m + 1 } else { hi = m - 1 }
            }
            return (["low", "high", "mid", "A[mid]", T("Action", "动作")], rows,
                    T("Sorted first: \(a.map(String.init).joined(separator: ", ")) (positions start at 1)", "已先排序：\(a.map(String.init).joined(separator: ", "))（位置从 1 开始）"),
                    f >= 0 ? T("Found at position \(f + 1) after \(rows.count) comparisons", "在位置 \(f + 1) 找到，比较 \(rows.count) 次") : T("Not found after \(rows.count) comparisons", "找不到，比较 \(rows.count) 次"))
        default:
            var rows: [[String]] = [], f = -1
            for (i, x) in a.enumerated() {
                rows.append(["\(i + 1)", "\(x)", x == t ? T("found", "找到") : T("next", "继续")])
                if x == t { f = i; break }
            }
            return (["i", "A[i]", T("Action", "动作")], rows, "",
                    f >= 0 ? T("Position \(f + 1), \(rows.count) comparisons", "位置 \(f + 1)，比较 \(rows.count) 次") : T("Not found", "找不到"))
        }
    }
}
