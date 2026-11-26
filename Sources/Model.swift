import Foundation

// MARK: - Flexible decoding helpers

struct FlexString: Decodable, Hashable {
    let value: String
    init(_ v: String) { value = v }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else if let b = try? c.decode(Bool.self) { value = b ? "True" : "False" }
        else { value = "" }
    }
}

struct FlexInts: Decodable, Hashable {
    let values: [Int]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let a = try? c.decode([Int].self) { values = a }
        else if let i = try? c.decode(Int.self) { values = [i] }
        else { values = [] }
    }
}

/// MC answer: an index (0-3) or a letter ("A"-"D"); "*" means the question was cancelled.
struct FlexAnswer: Decodable, Hashable {
    let index: Int
    let cancelled: Bool
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { index = i; cancelled = false; return }
        let s = (try? c.decode(String.self)) ?? ""
        if s == "*" { index = -1; cancelled = true; return }
        index = ["A", "B", "C", "D"].firstIndex(of: s.uppercased()) ?? -1
        cancelled = false
    }
}

// MARK: - Raw JSON (same files the website reads)

struct Catalog: Codable {
    let v: Int
    let books: [CBook]
    struct CBook: Codable { let id: String; let name: String; let elective: Bool?; let chs: [CCh] }
    struct CCh: Codable { let id: String; let n: Int; let t: String; let tz: String?; let sec: [String]?; let nc: Int; let nm: Int; let ns: Int; let np: Int; let h: String; let size: Int }
}

struct RawBook: Decodable {
    let id: String
    let name: String
    let elective: Bool?
    let chs: [RawChapter]
}

struct RawChapter: Decodable {
    let id: String
    let n: Int
    let t: String
    let tz: String?
    let sec: [String]?
    let cards: [Card]?
    let mc: [RawMC]?
    let sq: [RawSQ]?
    let pr: [Practical]?
}

struct Card: Decodable, Hashable {
    let t: String
    let tz: String?
    let ty: String?
    let sec: String?
    let en: String?
    let zh: String?
    let ex: [Example]?
    let code: [CodeSnip]?
    let demo: Demo?

    enum K: String, CodingKey { case t, tz, ty, sec, en, zh, ex, code, demo }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        t = (try? c.decode(FlexString.self, forKey: .t).value) ?? ""
        tz = try? c.decodeIfPresent(String.self, forKey: .tz)
        ty = try? c.decodeIfPresent(String.self, forKey: .ty)
        sec = try? c.decodeIfPresent(FlexString.self, forKey: .sec)?.value
        en = try? c.decodeIfPresent(String.self, forKey: .en)
        zh = try? c.decodeIfPresent(String.self, forKey: .zh)
        ex = (try? c.decodeIfPresent([Lenient<Example>].self, forKey: .ex))?.compactMap { $0.value }
        code = (try? c.decodeIfPresent([Lenient<CodeSnip>].self, forKey: .code))?.compactMap { $0.value }
        demo = try? c.decodeIfPresent(Demo.self, forKey: .demo)
    }
}

/// Decodes an element if possible, otherwise nil (so one bad entry never breaks a whole book).
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from d: Decoder) throws { value = try? T(from: d) }
}

struct Example: Decodable, Hashable {
    let q: String
    let a: String
    let az: String?
    let mistake: Bool?
}

struct CodeNote: Decodable, Hashable {
    let l: Int
    let t: String
    let tz: String?
    enum K: String, CodingKey { case l, t, tz }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        l = Int((try? c.decode(FlexString.self, forKey: .l).value) ?? "") ?? 0
        t = (try? c.decode(String.self, forKey: .t)) ?? ""
        tz = try? c.decodeIfPresent(String.self, forKey: .tz)
    }
}

struct CodeSnip: Decodable, Hashable {
    let lang: String
    let src: String
    let notes: [CodeNote]
    let input: String
    let output: String
    let run: Bool
    let setup: String
    enum K: String, CodingKey { case lang, src, notes, input = "in", output = "out", run, setup }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        lang = (try? c.decode(String.self, forKey: .lang)) ?? ""
        src = try c.decode(String.self, forKey: .src)
        notes = ((try? c.decodeIfPresent([Lenient<CodeNote>].self, forKey: .notes)) ?? nil)?.compactMap { $0.value } ?? []
        input = (try? c.decodeIfPresent(FlexString.self, forKey: .input))??.value ?? ""
        output = (try? c.decodeIfPresent(FlexString.self, forKey: .output))??.value ?? ""
        run = ((try? c.decodeIfPresent(Bool.self, forKey: .run)) ?? nil) ?? false
        setup = ((try? c.decodeIfPresent(String.self, forKey: .setup)) ?? nil) ?? ""
    }
}

struct DiagramNode: Decodable, Hashable { let id: String; let label: String }
struct Diagram: Decodable, Hashable {
    let nodes: [DiagramNode]
    let edges: [[String]]
    let active: [String]
    enum K: String, CodingKey { case nodes, edges, active }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        nodes = ((try? c.decodeIfPresent([Lenient<DiagramNode>].self, forKey: .nodes)) ?? nil)?.compactMap { $0.value } ?? []
        edges = ((try? c.decodeIfPresent([[FlexString]].self, forKey: .edges)) ?? nil)?.map { $0.map(\.value) } ?? []
        active = ((try? c.decodeIfPresent([String].self, forKey: .active)) ?? nil) ?? []
    }
}
struct DemoFrameData: Decodable, Hashable {
    let t: String?
    let en: String?
    let zh: String?
    let hl: [String]?
    let diagram: Diagram?
}
struct TraceRow: Decodable, Hashable {
    let line: Int
    let vals: [String: String]
    let out: String
    enum K: String, CodingKey { case line, vals, out }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        line = Int((try? c.decode(FlexString.self, forKey: .line).value) ?? "") ?? 0
        vals = (((try? c.decodeIfPresent([String: FlexString].self, forKey: .vals)) ?? nil) ?? [:]).mapValues(\.value)
        out = ((try? c.decodeIfPresent(FlexString.self, forKey: .out)) ?? nil)?.value ?? ""
    }
}

struct Demo: Decodable, Hashable {
    var type = ""
    var value = ""
    var from = 10
    var to = 2
    var bits = 8
    var a = ""
    var b = ""
    var algo = ""
    var data: [String] = []
    var target = ""
    var setup = ""
    var query = ""
    var note = ""
    var html = ""
    var css = ""
    var js = ""
    var lang = ""
    var src = ""
    var stdin = ""
    var vars: [String] = []
    var rows: [TraceRow] = []
    var text = ""
    var shift = 3
    var title = ""
    var frames: [DemoFrameData] = []

    enum K: String, CodingKey { case type, value, from, to, bits, a, b, algo, data, target, setup, query, note, html, css, js, lang, src, stdin, vars, rows, text, shift, title, frames }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func s(_ k: K) -> String? { ((try? c.decodeIfPresent(FlexString.self, forKey: k)) ?? nil)?.value }
        func i(_ k: K) -> Int? { s(k).flatMap { Int($0) ?? Double($0).map { Int($0) } } }
        type = s(.type) ?? ""
        value = s(.value) ?? ""
        from = i(.from) ?? 10; to = i(.to) ?? 2; bits = i(.bits) ?? 8
        a = s(.a) ?? ""; b = s(.b) ?? ""; algo = s(.algo) ?? ""
        data = (((try? c.decodeIfPresent([FlexString].self, forKey: .data)) ?? nil) ?? []).map(\.value)
        target = s(.target) ?? ""
        setup = s(.setup) ?? ""; query = s(.query) ?? ""; note = s(.note) ?? ""
        html = s(.html) ?? ""; css = s(.css) ?? ""; js = s(.js) ?? ""
        lang = s(.lang) ?? ""; src = s(.src) ?? ""; stdin = s(.stdin) ?? ""
        vars = ((try? c.decodeIfPresent([String].self, forKey: .vars)) ?? nil) ?? []
        rows = (((try? c.decodeIfPresent([Lenient<TraceRow>].self, forKey: .rows)) ?? nil) ?? []).compactMap { $0.value }
        text = s(.text) ?? ""; shift = i(.shift) ?? 3; title = s(.title) ?? ""
        frames = (((try? c.decodeIfPresent([Lenient<DemoFrameData>].self, forKey: .frames)) ?? nil) ?? []).compactMap { $0.value }
    }
}

struct RawMC: Decodable {
    let q: String
    let o: [String]
    let a: FlexAnswer
    let e: String?
    let ez: String?
    let sec: String?
    let code: Bool?
    let src: String?
}

struct Part: Decodable, Hashable {
    let l: String?
    let q: String?
    let m: Int?
    let ms: String?
    let figs: [String]?
    var marks: Int { max(1, m ?? 1) }
}

struct RawSQ: Decodable {
    let sec: String?
    let src: String?
    let q: String?
    let parts: [Part]?
}

struct TestCase: Decodable, Hashable {
    let call: String
    let expect: FlexString
}

struct DomCheck: Decodable, Hashable {
    let sel: String
    let count: Int?
    let text: String?
    let attr: String?
    let value: FlexString?
    let style: String?
}

struct Check: Decodable, Hashable {
    let type: String?
    let tests: [TestCase]?
    let stdin: String?
    let expect: String?
    let checks: [DomCheck]?
    let model: String?
    let expected_sql: String?
}

struct Practical: Decodable, Hashable {
    let t: String
    let tz: String?
    let lang: String?
    let sec: String?
    let task: String
    let taskz: String?
    let setup: String?
    let starter: String?
    let check: Check?
    let solution: String?
    let src: String?

    /// Exercises that can't be run on device: show a model answer instead.
    var isSelfCheck: Bool {
        let l = (lang ?? "").lowercased()
        return check?.type == "self" || l == "self" || l == "php"
    }
    var modelAnswer: String { check?.model ?? solution ?? "" }
}

struct RawDSE: Decodable {
    let year: FlexString
    let mc: [RawDMC]?
    let lq: [RawLQ]?
}

struct RawDMC: Decodable {
    let n: Int
    let q: String
    let o: [String]
    let a: FlexAnswer
    let pct: String?
    let topic: String?
    let exp: String?
    let pg: Int?
    let fig: FlexString?
    let img: String?
    let figs: [String]?
    let code: Bool?
    let st: [String]?
}

struct RawLQ: Decodable {
    let n: Int
    let topic: String?
    let pg: FlexInts?
    let stem: String?
    let figs: [String]?
    let parts: [Part]?
}

struct Meta: Decodable {
    struct Year: Decodable { let y: String; let note: String?; let paper: String?; let ms: String? }
    let keys: [String: String]
    let pct: [String: [String]]
    let years: [Year]
    struct P2: Decodable { let paper: String; let ms: String? }
    let p2: [String: [String: P2]]?
}

/// One HKDSE ICT Paper 2 (elective) paper.
struct Paper2: Identifiable, Hashable {
    let year: String
    let code: String        // A, B, C, D
    let paper: URL
    let ms: URL?
    var id: String { year + code }
}

enum Electives {
    static let codes = ["A", "B", "C", "D"]
    /// Paper 2 elective names (2012–2024 curriculum) and the closest textbook elective in the current curriculum.
    static func name(_ c: String) -> String {
        switch c {
        case "A": return "2A Databases"
        case "B": return "2B Data Communications and Networking"
        case "C": return "2C Multimedia Production and Website Development"
        default: return "2D Software Development"
        }
    }
    static func book(_ c: String) -> String? {
        switch c { case "A": return "EA"; case "C": return "EB"; case "D": return "EC"; default: return nil }
    }
}

struct Manifest: Decodable {
    let v: Int
    let books: [String]
    let years: [String]
}

// MARK: - App model

enum ItemType: String, Codable { case mc, sq, lq, pr }

struct Item: Identifiable, Hashable {
    let key: String
    let type: ItemType
    var src: String = ""
    var q: String = ""
    var st: [String] = []
    var o: [String] = []
    var a: Int = -1
    var cancel = false
    var pct = ""
    var e = ""
    var ez = ""
    var code = false
    var fig: URL? = nil
    var figs: [URL] = []
    var parts: [Part] = []
    var pages: [URL] = []
    var chapterID: String? = nil
    var bookID: String? = nil
    var topic: String? = nil
    var year: String? = nil
    var n = 0
    var sec = ""
    var isReal = false
    var practical: Practical? = nil

    var id: String { key }
    static func == (l: Item, r: Item) -> Bool { l.key == r.key }
    func hash(into h: inout Hasher) { h.combine(key) }

    var totalMarks: Int {
        switch type {
        case .mc, .pr: return 1
        case .sq, .lq: return parts.reduce(0) { $0 + $1.marks }
        }
    }
}

struct Chapter: Identifiable, Hashable {
    let id: String
    let n: Int
    let t: String
    let tz: String
    let sections: [String]
    let bookID: String
    let elective: Bool
    let cards: [Card]
    let mc: [String]
    let sq: [String]
    let pr: [String]
    /// Counts from the catalogue, so lists work before the chapter is downloaded.
    var counts: (cards: Int, mc: Int, sq: Int, pr: Int)? = nil
    var isStub: Bool { counts != nil }
    var nCards: Int { counts?.cards ?? cards.count }
    var nMC: Int { counts?.mc ?? mc.count }
    var nSQ: Int { counts?.sq ?? sq.count }
    var nPR: Int { counts?.pr ?? pr.count }
    var name: String { "\(bookID) Ch\(n) \(t)" }
    static func == (l: Chapter, r: Chapter) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct Book: Identifiable, Hashable {
    let id: String
    let name: String
    let elective: Bool
    let chapters: [Chapter]
    static func == (l: Book, r: Book) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct PaperYear: Identifiable, Hashable {
    let y: String
    let label: String
    let note: String?
    let paper: URL?
    let ms: URL?
    let key: [String]   // answer letters, "*" = cancelled
    let pct: [String]
    var mc: [String] = []
    var lq: [String] = []
    var id: String { y }
    static func == (l: PaperYear, r: PaperYear) -> Bool { l.y == r.y }
    func hash(into h: inout Hasher) { h.combine(y) }
}

enum Topics {
    static let order = ["A1", "A2", "B", "C1", "C2", "D1", "D2", "E"]
    static let names: [String: String] = [
        "A1": "A Information Processing: Data Representation & Office Software",
        "A2": "A Information Processing: Spreadsheet & Database",
        "B": "B Computer System Fundamentals",
        "C1": "C Internet and its Applications: Networking & Internet Basics",
        "C2": "C Internet and its Applications: Web Authoring, Security & Privacy",
        "D1": "D Basic Programming Concepts: Problem Solving & Algorithm Design",
        "D2": "D Basic Programming Concepts: Programming, Testing & Debugging",
        "E": "E Social Implications",
    ]
    /// Which DSE topic each textbook maps to (electives map to their closest compulsory topic).
    static let bookTopic: [String: String] = [
        "A1": "A1", "A2": "A2", "B": "B", "C1": "C1", "C2": "C2", "D1": "D1", "D2": "D2", "E": "E",
        "EA": "A2", "EB": "C2", "EC": "D2",
    ]
    static func name(_ t: String) -> String { names[t] ?? t }
}

func yearLabel(_ y: String) -> String {
    y == "SP" ? "Sample Paper" : y == "PP" ? "Practice Paper" : "DSE \(y)"
}
