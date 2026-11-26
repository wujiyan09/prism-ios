import SwiftUI

// A small HTML subset renderer (b, i, u, code, sup, sub, br, p, pre, ul/ol, table…)
// that turns the course content into native SwiftUI text, code blocks, lists and grids.

indirect enum RichBlock {
    case para(AttributedString)
    case heading(AttributedString)
    case code(String, lang: String)
    case list(ordered: Bool, items: [[RichBlock]])
    case table([[TableCell]])
}

struct TableCell {
    var text: AttributedString
    var header: Bool
}

// MARK: - Parser

private final class HNode {
    let name: String          // "" = text node
    var text: String = ""
    var attrs: [String: String] = [:]
    var children: [HNode] = []
    init(name: String) { self.name = name }
}

enum HTML {
    private static let voidTags: Set<String> = ["br", "img", "input", "hr", "meta", "link", "col", "wbr", "source"]
    private static let tagRE = try! NSRegularExpression(pattern: #"<(br|b|i|table|tr|td|pre|code|ul|li|p|span|sub|sup|u)\b"#, options: [.caseInsensitive])

    static func hasTag(_ s: String) -> Bool {
        tagRE.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(10).firstIndex(of: ";") {
                let ent = String(s[s.index(after: i)..<semi])
                var rep: String? = nil
                switch ent {
                case "lt": rep = "<"
                case "gt": rep = ">"
                case "amp": rep = "&"
                case "quot": rep = "\""
                case "apos", "#39": rep = "'"
                case "nbsp": rep = "\u{00A0}"
                case "times": rep = "×"
                case "divide": rep = "÷"
                case "le": rep = "≤"
                case "ge": rep = "≥"
                case "ne": rep = "≠"
                case "rarr": rep = "→"
                case "larr": rep = "←"
                case "hellip": rep = "…"
                case "mdash": rep = "—"
                case "ndash": rep = "–"
                default:
                    if ent.hasPrefix("#x") || ent.hasPrefix("#X"), let v = UInt32(ent.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
                    else if ent.hasPrefix("#"), let v = UInt32(ent.dropFirst()), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
                }
                if let rep { out += rep; i = s.index(after: semi); continue }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    fileprivate static func parse(_ s: String) -> HNode {
        let root = HNode(name: "#root")
        var stack: [HNode] = [root]
        var i = s.startIndex
        var buf = ""
        func flush() {
            if !buf.isEmpty {
                let t = HNode(name: ""); t.text = decodeEntities(buf)
                stack.last!.children.append(t); buf = ""
            }
        }
        var rawUntil: String? = nil   // inside <script>/<style>
        while i < s.endIndex {
            let c = s[i]
            if c == "<" {
                let next = s.index(after: i)
                if next < s.endIndex, let close = s[next...].firstIndex(of: ">") {
                    let inner = String(s[next..<close])
                    let first = inner.first
                    let isTag = first.map { $0.isLetter || $0 == "/" || $0 == "!" } ?? false
                    if isTag {
                        if let r = rawUntil {
                            if inner.lowercased().hasPrefix("/" + r) { rawUntil = nil; stack.removeLast() }
                            i = s.index(after: close); continue
                        }
                        flush()
                        if inner.hasPrefix("!") { i = s.index(after: close); continue }
                        if inner.hasPrefix("/") {
                            let name = inner.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
                            if let idx = stack.lastIndex(where: { $0.name == name }), idx > 0 {
                                stack.removeSubrange(idx...)
                            }
                        } else {
                            var body = inner
                            let selfClose = body.hasSuffix("/")
                            if selfClose { body.removeLast() }
                            let parts = body.split(separator: " ", maxSplits: 1)
                            let name = String(parts.first ?? "").lowercased()
                            let node = HNode(name: name)
                            if parts.count > 1 { node.attrs = parseAttrs(String(parts[1])) }
                            // implicit closes
                            if ["li", "tr", "td", "th", "p"].contains(name) {
                                let stopper: Set<String> = name == "li" ? ["ul", "ol"] : (name == "tr" ? ["table", "tbody", "thead"] : (name == "p" ? ["div", "td", "li"] : ["tr"]))
                                let same: Set<String> = name == "td" || name == "th" ? ["td", "th"] : [name]
                                if let idx = stack.lastIndex(where: { same.contains($0.name) || stopper.contains($0.name) }),
                                   same.contains(stack[idx].name), idx > 0 {
                                    stack.removeSubrange(idx...)
                                }
                            }
                            stack.last!.children.append(node)
                            if !voidTags.contains(name) && !selfClose {
                                stack.append(node)
                                if name == "script" || name == "style" { rawUntil = name }
                            }
                        }
                        i = s.index(after: close); continue
                    }
                }
            }
            if rawUntil == nil { buf.append(c) }
            i = s.index(after: i)
        }
        flush()
        return root
    }

    private static func parseAttrs(_ s: String) -> [String: String] {
        var d: [String: String] = [:]
        let re = try! NSRegularExpression(pattern: #"([a-zA-Z-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#)
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let k = Range(m.range(at: 1), in: s) else { continue }
            var v = ""
            for g in 3...5 { if let r = Range(m.range(at: g), in: s) { v = String(s[r]); break } }
            d[s[k].lowercased()] = v
        }
        return d
    }

    // MARK: Render to blocks

    private struct Style {
        var bold = false, italic = false, underline = false, code = false
        var sup = false, sub = false
        var link: URL? = nil
    }

    private final class Builder {
        var blocks: [RichBlock] = []
        var cur = AttributedString()
        let preserveNewlines: Bool
        init(preserveNewlines: Bool) { self.preserveNewlines = preserveNewlines }

        func append(_ text: String, _ st: Style) {
            var t = text
            if !preserveNewlines {
                t = t.replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
                if t == " " && (cur.characters.isEmpty || cur.characters.last == "\n" || cur.characters.last == " ") { return }
            }
            guard !t.isEmpty else { return }
            var a = AttributedString(t)
            var intent: InlinePresentationIntent = []
            if st.bold { intent.insert(.stronglyEmphasized) }
            if st.italic { intent.insert(.emphasized) }
            if st.code { intent.insert(.code) }
            if !intent.isEmpty { a.inlinePresentationIntent = intent }
            if st.underline { a[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single }
            if st.sup { a[AttributeScopes.SwiftUIAttributes.BaselineOffsetAttribute.self] = 6; a[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .caption2 }
            if st.sub { a[AttributeScopes.SwiftUIAttributes.BaselineOffsetAttribute.self] = -3; a[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .caption2 }
            if let l = st.link { a.link = l }
            cur += a
        }

        func flush(heading: Bool = false) {
            let trimmed = Builder.trim(cur)
            if !trimmed.characters.isEmpty { blocks.append(heading ? .heading(trimmed) : .para(trimmed)) }
            cur = AttributedString()
        }

        static func trim(_ a: AttributedString) -> AttributedString {
            var a = a
            while let f = a.characters.first, f == " " || f == "\n" { a.removeSubrange(a.startIndex..<a.characters.index(after: a.startIndex)) }
            while let l = a.characters.last, l == " " || l == "\n" {
                let e = a.characters.index(before: a.endIndex)
                a.removeSubrange(e..<a.endIndex)
            }
            return a
        }
    }

    private static func textContent(_ n: HNode) -> String {
        if n.name.isEmpty { return n.text }
        if n.name == "br" { return "\n" }
        return n.children.map(textContent).joined()
    }

    private static func inline(_ n: HNode, _ b: Builder, _ st: Style) {
        if n.name.isEmpty { b.append(n.text, st); return }
        var s = st
        switch n.name {
        case "br": b.cur += AttributedString("\n"); return
        case "b", "strong", "th": s.bold = true
        case "i", "em": s.italic = true
        case "u", "ins": s.underline = true
        case "code", "tt", "kbd", "samp": s.code = true
        case "sup": s.sup = true
        case "sub": s.sub = true
        case "a": s.link = n.attrs["href"].flatMap(URL.init(string:))
        case "img", "input", "script", "style", "head", "title", "select", "button", "iframe": return
        default: break
        }
        for c in n.children { inline(c, b, s) }
    }

    private static let blockTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "section", "blockquote", "pre", "ul", "ol", "table", "form", "dl", "hr"]

    private static func render(_ nodes: [HNode], preserveNewlines: Bool) -> [RichBlock] {
        let b = Builder(preserveNewlines: preserveNewlines)
        walk(nodes, b, Style())
        b.flush()
        return b.blocks
    }

    private static func walk(_ nodes: [HNode], _ b: Builder, _ st: Style) {
        for n in nodes {
            switch n.name {
            case "pre":
                b.flush()
                var code = textContent(n)
                while code.hasPrefix("\n") { code.removeFirst() }
                while code.hasSuffix("\n") { code.removeLast() }
                let cls = (n.attrs["class"] ?? "") + " " + (n.attrs["data-lang"] ?? "") + " " + (n.children.first { $0.name == "code" }?.attrs["class"] ?? "")
                let lang = cls.components(separatedBy: .whitespaces).compactMap { c -> String? in
                    if c.hasPrefix("language-") { return String(c.dropFirst(9)) }
                    if c.hasPrefix("lang-") { return String(c.dropFirst(5)) }
                    return ["python", "py", "sql", "js", "javascript", "html", "php", "pascal", "pseudo", "css"].contains(c) ? c : nil
                }.first ?? ""
                b.blocks.append(.code(code, lang: lang))
            case "ul", "ol":
                b.flush()
                var items: [[RichBlock]] = []
                for li in n.children where !li.name.isEmpty || !li.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let kids = li.name == "li" ? li.children : [li]
                    let inner = render(kids, preserveNewlines: false)
                    if !inner.isEmpty { items.append(inner) }
                }
                b.blocks.append(.list(ordered: n.name == "ol", items: items))
            case "table":
                b.flush()
                var rows: [[TableCell]] = []
                func collectRows(_ x: HNode) {
                    for c in x.children {
                        if c.name == "tr" {
                            var cells: [TableCell] = []
                            for td in c.children where td.name == "td" || td.name == "th" {
                                let cb = Builder(preserveNewlines: false)
                                var s = Style(); if td.name == "th" { s.bold = true }
                                for k in td.children {
                                    if blockTags.contains(k.name) && k.name != "pre" { inline(k, cb, s); cb.cur += AttributedString("\n") }
                                    else if k.name == "pre" { var cs = s; cs.code = true; cb.append(textContent(k), cs) }
                                    else { inline(k, cb, s) }
                                }
                                cells.append(TableCell(text: Builder.trim(cb.cur), header: td.name == "th"))
                            }
                            rows.append(cells)
                        } else if ["thead", "tbody", "tfoot"].contains(c.name) {
                            collectRows(c)
                        }
                    }
                }
                collectRows(n)
                if !rows.isEmpty { b.blocks.append(.table(rows)) }
            case "hr":
                b.flush()
            case "h1", "h2", "h3", "h4", "h5", "h6":
                b.flush()
                var s = st; s.bold = true
                for c in n.children { inline(c, b, s) }
                b.flush(heading: true)
            case "p", "div", "section", "blockquote", "form", "dl", "li", "body", "html":
                b.flush()
                walk(n.children, b, st)
                b.flush()
            case "head", "script", "style", "title":
                continue
            default:
                if n.children.contains(where: { blockTags.contains($0.name) }) {
                    walk(n.children, b, st)
                } else {
                    inline(n, b, st)
                }
            }
        }
    }

    private static let cache = NSCache<NSString, BlockBox>()
    final class BlockBox { let blocks: [RichBlock]; init(_ b: [RichBlock]) { blocks = b } }

    /// - Parameter code: treat a plain (tag-free) string as a code block.
    static func blocks(_ s: String, code: Bool = false) -> [RichBlock] {
        let key = ((code ? "1" : "0") + s) as NSString
        if let c = cache.object(forKey: key) { return c.blocks }
        let tagged = hasTag(s)
        let out: [RichBlock]
        if code && !tagged {
            out = [.code(decodeEntities(s), lang: "")]
        } else {
            out = render(parse(s).children, preserveNewlines: !tagged)
        }
        cache.setObject(BlockBox(out), forKey: key)
        return out
    }

    /// Plain text (for titles, menus, search).
    static func plain(_ s: String) -> String {
        let n = parse(s)
        return textContent(n).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Views

struct RichText: View {
    let html: String
    var code: Bool = false
    @AppStorage(Reading.paraKey) private var para = Reading.paraDefault
    var body: some View {
        let blocks = HTML.blocks(html, code: code)
        VStack(alignment: .leading, spacing: para) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                RichBlockView(block: b)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readingText()
    }
}

struct RichBlockView: View {
    let block: RichBlock
    var body: some View {
        switch block {
        case .para(let a):
            Text(a).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .heading(let a):
            Text(a).font(.headline).fixedSize(horizontal: false, vertical: true)
        case .code(let s, let lang):
            CodeBlock(text: s, lang: lang)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(i + 1)." : "•").foregroundStyle(.secondary).monospacedDigit()
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(item.enumerated()), id: \.offset) { _, b in RichBlockView(block: b) }
                        }
                    }
                }
            }
        case .table(let rows):
            TableBlock(rows: rows)
        }
    }
}

struct CodeBlock: View {
    let text: String
    var lang: String = ""
    var annotations: [Int: String] = [:]   // 1-based line → note
    @State private var copied = false

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Highlighter.label(lang, text)).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        GridRow {
                            if lines.count > 1 {
                                Text("\(i + 1)").foregroundStyle(.tertiary).gridColumnAlignment(.trailing)
                            }
                            HStack(spacing: 12) {
                                Text(Highlighter.highlight(l, lang: Highlighter.guess(lang, text)))
                                if let note = annotations[i + 1] {
                                    Text("← " + note).font(.system(.caption)).foregroundStyle(Color.accentColor)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(annotations[i + 1] != nil ? Color.accentColor.opacity(0.12) : .clear)
                        }
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Lightweight regex syntax highlighter for the course languages.
enum Highlighter {
    static func guess(_ lang: String, _ text: String) -> String {
        let l = lang.lowercased()
        if !l.isEmpty { return ["py": "python", "javascript": "js"][l] ?? l }
        let t = text.lowercased()
        if t.contains("select ") && t.contains(" from ") { return "sql" }
        if t.contains("def ") || t.contains("print(") || t.contains("elif ") { return "python" }
        if t.contains("<?php") { return "php" }
        if t.contains("</") || t.contains("<html") { return "html" }
        if t.contains("function ") || t.contains("console.log") || t.contains("let ") { return "js" }
        return "pseudo"
    }
    static func label(_ lang: String, _ text: String) -> String {
        let g = guess(lang, text)
        return ["python": "Python", "js": "JavaScript", "sql": "SQL", "html": "HTML", "php": "PHP", "css": "CSS", "pascal": "Pascal"][g] ?? "Code"
    }
    static let keywords: [String: [String]] = [
        "python": ["def", "return", "if", "elif", "else", "for", "while", "in", "and", "or", "not", "import", "from", "as", "True", "False", "None", "print", "input", "range", "len", "int", "str", "float", "break", "continue", "class", "try", "except", "with", "lambda", "append"],
        "js": ["function", "return", "if", "else", "for", "while", "let", "const", "var", "true", "false", "null", "undefined", "new", "document", "console", "of", "in", "break"],
        "php": ["echo", "if", "else", "foreach", "for", "while", "function", "return", "as", "isset", "array", "true", "false", "null"],
        "sql": ["SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "ORDER", "BY", "GROUP", "HAVING", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "JOIN", "LEFT", "INNER", "ON", "AS", "DISTINCT", "COUNT", "SUM", "AVG", "MAX", "MIN", "LIKE", "IN", "BETWEEN", "IS", "NULL", "ASC", "DESC", "PRIMARY", "KEY", "INTEGER", "TEXT", "ALTER", "ADD", "DROP", "UNION"],
        "pseudo": ["IF", "THEN", "ELSE", "END", "ENDIF", "FOR", "TO", "NEXT", "WHILE", "DO", "REPEAT", "UNTIL", "INPUT", "OUTPUT", "PRINT", "RETURN", "AND", "OR", "NOT", "MOD", "DIV", "begin", "end", "if", "then", "else", "for", "to", "do", "while", "var", "integer", "writeln", "readln"],
    ]
    static func highlight(_ line: String, lang: String) -> AttributedString {
        var a = AttributedString(line.isEmpty ? " " : line)
        let ns = line as NSString
        func paint(_ pattern: String, _ color: Color, opts: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return }
            for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                guard let r = Range(m.range, in: line),
                      let lo = AttributedString.Index(r.lowerBound, within: a),
                      let hi = AttributedString.Index(r.upperBound, within: a) else { continue }
                a[lo..<hi].foregroundColor = color
            }
        }
        if lang == "html" {
            paint(#"</?[A-Za-z0-9]+"#, .pink)
            paint(#"\b[a-z-]+(?==)"#, .orange)
        } else {
            let kw = keywords[lang] ?? keywords["pseudo"]!
            paint(#"\b(\#(kw.joined(separator: "|")))\b"#, .pink, opts: lang == "sql" ? .caseInsensitive : [])
            paint(#"\b\d+(\.\d+)?\b"#, .blue)
        }
        paint(#""[^"]*"|'[^']*'"#, .green)
        let comment = lang == "sql" ? "--.*$" : (lang == "python" ? "#.*$" : (lang == "html" ? "<!--.*?-->" : "//.*$"))
        paint(comment, .gray)
        return a
    }
}

struct TableBlock: View {
    let rows: [[TableCell]]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minWidth: 44, maxWidth: 320, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                                .background(cell.header ? Color(uiColor: .tertiarySystemFill) : Color.clear)
                                .overlay(Rectangle().stroke(Color(uiColor: .separator), lineWidth: 0.5))
                        }
                    }
                }
            }
            .padding(1)
        }
    }
}
