import SwiftUI
import UIKit
import SwiftMath

/// Native LaTeX rendering (SwiftMath). Text uses the site's light markup:
/// $inline$, $$display$$, **bold**, ==highlight==, __underline__, *italic*, newlines.
enum TeX {
    /// Maps KaTeX-only commands to ones SwiftMath knows.
    private static let setup: Void = {
        for (k, v) in [("therefore", "\u{2234}"), ("because", "\u{2235}"), ("spadesuit", "\u{2660}"), ("heartsuit", "\u{2661}"),
                       ("clubsuitx", "\u{2663}"), ("diamondsuitx", "\u{2662}")] {
            if let a = MTMathAtomFactory.atom(forLatexSymbol: "emptyset") {
                a.nucleus = v
                MTMathAtomFactory.add(latexSymbol: k, value: a)
            }
        }
    }()

    static func normalize(_ s: String) -> String {
        _ = setup
        var t = s
        let simple: [(String, String)] = [
            (#"\leqslant"#, #"\leq"#), (#"\geqslant"#, #"\geq"#), (#"\varnothing"#, #"\emptyset"#),
            (#"\dfrac"#, #"\frac"#), (#"\tfrac"#, #"\frac"#), (#"\implies"#, #"\Rightarrow"#),
            (#"\displaystyle"#, ""), (#"\textstyle"#, ""), (#"\,"#, #"\ "#), (#"\;"#, #"\ "#), (#"\!"#, ""),
            (#"\operatorname"#, #"\mathrm"#), (#"\lvert"#, "|"), (#"\rvert"#, "|"), (#"\dots"#, #"\ldots"#),
            (#"\mathbb{R}"#, "ℝ"), (#"\mathbb{N}"#, "ℕ"), (#"\mathbb{Z}"#, "ℤ"), (#"\mathbb{Q}"#, "ℚ"),
            (#"\tbinom"#, #"\binom"#), (#"\dbinom"#, #"\binom"#), 
            (#"\clubsuit"#, #"\clubsuitx"#), (#"\diamondsuit"#, #"\diamondsuitx"#), (#"\%"#, "%"),
            (#"\bigl"#, ""), (#"\bigr"#, ""), (#"\Bigl"#, ""), (#"\Bigr"#, ""), (#"\big"#, ""), (#"\Big"#, ""),
        ]
        for (a, b) in simple { t = t.replacingOccurrences(of: a, with: b) }
        // mhchem \ce{…} isn't in SwiftMath: convert to plain TeX (upright formulas, subscripts, charges, arrows).
        t = replaceBraced(t, command: #"\ce"#) { Chem.tex($0) }
        // \text{a b} -> \mathrm{a\ b} (keeps spaces)
        t = replaceBraced(t, command: #"\text"#) { #"\mathrm{"# + $0.replacingOccurrences(of: " ", with: #"\ "#) + "}" }
        t = replaceBraced(t, command: #"\textbf"#) { #"\mathbf{"# + $0.replacingOccurrences(of: " ", with: #"\ "#) + "}" }
        return t
    }

    /// Replaces `\cmd{...}` (balanced braces) using `f(inner)`.
    static func replaceBraced(_ s: String, command: String, _ f: (String) -> String) -> String {
        var out = ""
        var rest = Substring(s)
        while let r = rest.range(of: command + "{") {
            out += rest[..<r.lowerBound]
            var depth = 1
            var i = r.upperBound
            while i < rest.endIndex && depth > 0 {
                if rest[i] == "{" { depth += 1 } else if rest[i] == "}" { depth -= 1 }
                if depth > 0 { i = rest.index(after: i) }
            }
            let inner = String(rest[r.upperBound..<min(i, rest.endIndex)])
            out += f(inner)
            rest = i < rest.endIndex ? rest[rest.index(after: i)...] : ""
        }
        return out + rest
    }

    struct Rendered { let image: UIImage; let descent: CGFloat }
    private static let cache = NSCache<NSString, Box>()
    final class Box { let r: Rendered?; init(_ r: Rendered?) { self.r = r } }

    /// Renders LaTeX to an image (nil if SwiftMath can't parse it).
    static func render(_ latex: String, size: CGFloat, color: UIColor, display: Bool) -> Rendered? {
        let key = "\(display ? "D" : "T")|\(size)|\(color.hexKey)|\(latex)" as NSString
        if let b = cache.object(forKey: key) { return b.r }
        let r = make(latex, size: size, color: color, display: display)
        cache.setObject(Box(r), forKey: key)
        return r
    }

    private static func make(_ latex: String, size: CGFloat, color: UIColor, display: Bool) -> Rendered? {
        let label = MTMathUILabel()
        label.displayErrorInline = false
        label.labelMode = display ? .display : .text
        label.textAlignment = .left
        label.fontSize = size
        label.textColor = color
        label.latex = normalize(latex)
        if label.error != nil {
            // Try once more with any \mathrm text turned into plain letters.
            label.latex = normalize(latex).replacingOccurrences(of: #"\mathrm"#, with: "")
            if label.error != nil { return nil }
        }
        let sz = label.intrinsicContentSize
        guard sz.width > 0, sz.height > 0, sz.width < 6000 else { return nil }
        label.frame = CGRect(origin: .zero, size: CGSize(width: ceil(sz.width), height: ceil(sz.height)))
        label.layoutSubviews()
        let descent = label.displayList?.descent ?? 0
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        fmt.opaque = false
        guard let list = label.displayList else { return nil }
        let h = label.bounds.height
        let img = UIGraphicsImageRenderer(size: label.bounds.size, format: fmt).image { ctx in
            // Draw the typeset list ourselves in a y-up space (CoreText's), instead of layer.render,
            // which ignores the label's geometry flip and produced upside-down glyphs.
            let cg = ctx.cgContext
            cg.saveGState()
            cg.translateBy(x: 0, y: h)
            cg.scaleBy(x: 1, y: -1)
            cg.textMatrix = .identity
            list.draw(cg)
            cg.restoreGState()
        }
        return Rendered(image: img, descent: descent)
    }
}

private extension UIColor {
    var hexKey: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
    }
}

/// A block of mixed text + LaTeX.
struct MathText: View {
    let text: String
    var size: CGFloat = 17
    var weight: Font.Weight = .regular
    var color: Color = .primary
    @Environment(\.colorScheme) private var scheme
    @Environment(\.zhSerif) private var zhSerif

    @AppStorage(Reading.lineKey) private var line = Reading.lineDefault
    @AppStorage(Reading.paraKey) private var para = Reading.paraDefault
    @AppStorage(Reading.sizeKey) private var scale = Reading.sizeDefault

    var body: some View {
        let blocks = MathText.blocks(text)
        VStack(alignment: .leading, spacing: para) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .para(let s):
                    inline(s)
                        .lineSpacing(line)
                        .fixedSize(horizontal: false, vertical: true)
                case .display(let tex) where CJKMath.has(tex):
                    inline("$" + tex + "$").fixedSize(horizontal: false, vertical: true)
                case .display(let tex):
                    DisplayMath(tex: tex, size: size + 1, color: uiColor)
                case .table(let rows):
                    MathTable(rows: rows, head: "row", size: size - 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var uiColor: UIColor {
        let base = UIColor(color)
        return base.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
    }

    enum Block { case para(String), display(String), table([[String]]) }

    /// Splits text into paragraphs, display-maths blocks and markdown tables.
    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = []
        var rest = s
        while let r = rest.range(of: "$$") {
            let before = String(rest[..<r.lowerBound])
            let after = rest[r.upperBound...]
            guard let e = after.range(of: "$$") else { break }
            paras(before, into: &out)
            out.append(.display(String(after[..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)))
            rest = String(after[e.upperBound...])
        }
        paras(rest, into: &out)
        return out
    }

    private static func paras(_ s: String, into out: inout [Block]) {
        var table: [[String]] = []
        var para: [String] = []
        func flushPara() { let p = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines); if !p.isEmpty { out.append(.para(p)) }; para = [] }
        func flushTable() { if !table.isEmpty { out.append(.table(table)) }; table = [] }
        for line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") && t.hasSuffix("|") && t.count > 1 {
                flushPara()
                let cells = t.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                table.append(cells)
            } else {
                flushTable()
                para.append(line)
            }
        }
        flushTable(); flushPara()
    }

    /// One paragraph as a single wrapping Text with maths images inline.
    func inline(_ s: String) -> Text {
        MathText.inlineText(s, size: size, weight: weight, color: uiColor, serif: zhSerif)
    }

    static func inlineText(_ s: String, size: CGFloat, weight: Font.Weight = .regular, color: UIColor, serif: Bool = false) -> Text {
        var result = Text("")
        var i = s.startIndex
        var buf = ""
        func flush() { if !buf.isEmpty { result = result + styled(buf, size: size, weight: weight, serif: serif); buf = "" } }
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\\", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "$" {
                buf.append("$"); i = s.index(i, offsetBy: 2); continue
            }
            if ch == "\\", s.index(after: i) < s.endIndex, "_%&#{}".contains(s[s.index(after: i)]) {
                buf.append(s[s.index(after: i)]); i = s.index(i, offsetBy: 2); continue
            }
            if ch == "$", let close = s[s.index(after: i)...].firstIndex(of: "$") {
                flush()
                let tex = String(s[s.index(after: i)..<close])
                if CJKMath.has(tex) {
                    result = result + CJKMath.text(tex, size: size, color: color, serif: serif)
                } else if let r = TeX.render(tex, size: size, color: color, display: false) {
                    result = result + Text(Image(uiImage: r.image)).baselineOffset(-r.descent)
                } else {
                    result = result + Text(tex).font(.system(size: size, design: .serif)).italic()
                }
                i = s.index(after: close)
                continue
            }
            buf.append(ch)
            i = s.index(after: i)
        }
        flush()
        return result
    }

    /// **bold**, ==highlight==, __underline__, *italic* for plain text runs; curly quotes like the site.
    private static func styled(_ s: String, size: CGFloat, weight: Font.Weight, serif: Bool = false) -> Text {
        var a = AttributedString()
        let pattern = #"\*\*(.+?)\*\*|==(.+?)==|__(.+?)__|(?<![*\w])\*([^*\s][^*]*?)\*(?!\*)"#
        let re = try? NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        var last = 0
        func plain(_ t: String) -> AttributedString {
            var x = AttributedString(t)
            x.font = Reading.font(size, weight: weight, serif: serif)
            return x
        }
        for m in re?.matches(in: s, range: NSRange(location: 0, length: ns.length)) ?? [] {
            if m.range.location > last { a += plain(ns.substring(with: NSRange(location: last, length: m.range.location - last))) }
            if m.range(at: 1).location != NSNotFound {
                var x = AttributedString(ns.substring(with: m.range(at: 1))); x.font = Reading.font(size, weight: .bold, serif: serif); a += x
            } else if m.range(at: 2).location != NSNotFound {
                var x = AttributedString(ns.substring(with: m.range(at: 2))); x.font = Reading.font(size, weight: .semibold, serif: serif)
                x.backgroundColor = Color.yellow.opacity(0.28); a += x
            } else if m.range(at: 3).location != NSNotFound {
                var x = AttributedString(ns.substring(with: m.range(at: 3))); x.font = Reading.font(size, weight: weight, serif: serif)
                x.underlineStyle = .single; a += x
            } else if m.range(at: 4).location != NSNotFound {
                var x = AttributedString(ns.substring(with: m.range(at: 4))); x.font = Reading.font(size, weight: weight, serif: serif).italic(); a += x
            }
            last = m.range.location + m.range.length
        }
        if last < ns.length { a += plain(ns.substring(from: last)) }
        return Text(a)
    }
}

/// Display maths, centred; scrolls sideways if wider than the screen.
struct DisplayMath: View {
    let tex: String
    let size: CGFloat
    let color: UIColor
    var body: some View {
        if let r = TeX.render(tex, size: size, color: color, display: true) {
            ScrollView(.horizontal, showsIndicators: false) {
                Image(uiImage: r.image)
                    .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: r.image.size.height + 4)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        } else {
            Text(tex).font(.system(size: size, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

/// Table with LaTeX cells. head: "row" | "col" | "both" | "".
struct MathTable: View {
    let rows: [[String]]
    let head: String
    var size: CGFloat = 15
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let color = UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                            let isHead = ((head == "row" || head == "both") && r == 0) || ((head == "col" || head == "both") && c == 0)
                            MathText.inlineText(cell, size: size, weight: isHead ? .semibold : .regular, color: color)
                                .fixedSize()
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(isHead ? Color.secondary.opacity(0.15) : Color.clear)
                                .overlay(Rectangle().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

/// Maths with Chinese inside (e.g. $P(\text{两人都在}\mid\text{至少一人})$): SwiftMath drops CJK,
/// so the formula is split — maths pieces as images, Chinese as ordinary text.
enum CJKMath {
    static let cjk = try! NSRegularExpression(pattern: #"\\(?:text|mathrm|textbf|mbox|operatorname)\s*\{([^{}]*)\}|([\p{Han}\x{3000}-\x{303F}\x{FF00}-\x{FFEF}]+)"#)
    static func has(_ t: String) -> Bool { t.range(of: #"\p{Han}"#, options: .regularExpression) != nil }

    static func text(_ tex: String, size: CGFloat, color: UIColor, serif: Bool) -> Text {
        var result = Text("")
        let ns = tex as NSString
        var last = 0
        func math(_ m: String) {
            let t = m.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return }
            if let r = TeX.render(t, size: size, color: color, display: false) { result = result + Text(Image(uiImage: r.image)).baselineOffset(-r.descent) }
            else { result = result + Text(t).font(.system(size: size, design: .serif)).italic() }
        }
        for m in cjk.matches(in: tex, range: NSRange(location: 0, length: ns.length)) {
            let inner = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ns.substring(with: m.range)
            if m.range(at: 1).location != NSNotFound && !has(inner) { continue }   // plain \text{abc}: leave to the maths engine
            if m.range.location > last { math(ns.substring(with: NSRange(location: last, length: m.range.location - last))) }
            result = result + Text(inner).font(Reading.font(size, serif: serif)).foregroundColor(Color(uiColor: color))
            last = m.range.location + m.range.length
        }
        if last < ns.length { math(ns.substring(from: last)) }
        return result
    }
}


/// Minimal mhchem: H2SO4 → \mathrm{H_{2}SO_{4}}, Fe^{3+}/Fe^3+ → charge, ->, <=>, (aq)/(s)/(l)/(g), coefficients.
enum Chem {
    static func tex(_ s: String) -> String {
        var out = ""
        let arrows: [(String, String)] = [("<=>", #"\rightleftharpoons "#), ("<->", #"\leftrightarrow "#), ("->", #"\rightarrow "#), ("<-", #"\leftarrow "#)]
        var rest = Substring(s)
        while !rest.isEmpty {
            if let a = arrows.first(where: { rest.hasPrefix($0.0) }) { out += " " + a.1; rest = rest.dropFirst(a.0.count); continue }
            let ch = rest.first!
            if ch == " " { out += #"\ "#; rest = rest.dropFirst(); continue }
            if ch == "+" { out += " + "; rest = rest.dropFirst(); continue }
            if ch == "^" {
                rest = rest.dropFirst()
                var chg = ""
                if rest.first == "{" { rest = rest.dropFirst(); while let c = rest.first, c != "}" { chg.append(c); rest = rest.dropFirst() }; rest = rest.dropFirst() }
                else { while let c = rest.first, c.isNumber || c == "+" || c == "-" { chg.append(c); rest = rest.dropFirst() } }
                out += "^{" + chg.replacingOccurrences(of: "-", with: "−") + "}"; continue
            }
            if ch == "_" {
                rest = rest.dropFirst()
                var sub = ""
                if rest.first == "{" { rest = rest.dropFirst(); while let c = rest.first, c != "}" { sub.append(c); rest = rest.dropFirst() }; rest = rest.dropFirst() }
                else { while let c = rest.first, c.isNumber { sub.append(c); rest = rest.dropFirst() } }
                out += "_{" + sub + "}"; continue
            }
            if ch.isNumber {
                var n = ""
                while let c = rest.first, c.isNumber { n.append(c); rest = rest.dropFirst() }
                // A number right after a letter or ) is a subscript; at the start of a species it's a coefficient.
                if let p = out.last, p.isLetter || p == ")" || p == "}" && !out.hasSuffix(" ") { out += "_{" + n + "}" } else { out += n }
                continue
            }
            if ch.isLetter {
                var w = ""
                while let c = rest.first, c.isLetter { w.append(c); rest = rest.dropFirst() }
                out += #"\mathrm{"# + w + "}"; continue
            }
            out.append(ch); rest = rest.dropFirst()
        }
        return out
    }
}
