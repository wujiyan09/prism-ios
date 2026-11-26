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
        MathText.inlineText(s, size: size, weight: weight, color: uiColor)
    }

    static func inlineText(_ s: String, size: CGFloat, weight: Font.Weight = .regular, color: UIColor) -> Text {
        var result = Text("")
        var i = s.startIndex
        var buf = ""
        func flush() { if !buf.isEmpty { result = result + styled(buf, size: size, weight: weight); buf = "" } }
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
                if let r = TeX.render(tex, size: size, color: color, display: false) {
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
    private static func styled(_ s: String, size: CGFloat, weight: Font.Weight) -> Text {
        var a = AttributedString()
        let pattern = #"\*\*(.+?)\*\*|==(.+?)==|__(.+?)__|(?<![*\w])\*([^*\s][^*]*?)\*(?!\*)"#
        let re = try? NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        var last = 0
        func plain(_ t: String) -> AttributedString {
            var x = AttributedString(t)
            x.font = Reading.font(size, weight: weight)
            return x
        }
        for m in re?.matches(in: s, range: NSRange(location: 0, length: ns.length)) ?? [] {
            if m.range.location > last { a += plain(ns.substring(with: NSRange(location: last, length: m.range.location - last))) }
            if m.range(at: 1).location != NSNotFound {
                var x = AttributedString(ns.substring(with: m.range(at: 1))); x.font = .system(size: size, weight: .bold); a += x
            } else if m.range(at: 2).location != NSNotFound {
                var x = AttributedString(ns.substring(with: m.range(at: 2))); x.font = .system(size: size, weight: .semibold)
                x.backgroundColor = Color.yellow.opacity(0.28); a += x
            } else if m.range(at: 3).location != NSNotFound {
                var x = AttributedString(ns.substring(with: m.range(at: 3))); x.font = .system(size: size, weight: weight)
                x.underlineStyle = .single; a += x
            } else if m.range(at: 4).location != NSNotFound {
                var x = AttributedString(ns.substring(with: m.range(at: 4))); x.font = .system(size: size, weight: weight).italic(); a += x
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
