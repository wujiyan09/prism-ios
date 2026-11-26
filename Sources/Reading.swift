import SwiftUI

/// Apple Books–style reading settings for content (cards, questions, options, solutions).
enum Reading {
    static let fontName = "Times New Roman"
    static let lineKey = "read.line", paraKey = "read.para", marginKey = "read.margin", sizeKey = "read.size"
    static let lineDefault = 5.0, paraDefault = 12.0, marginDefault = 16.0, sizeDefault = 1.0
    static let keys = [lineKey, paraKey, marginKey, sizeKey]

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let scale = UserDefaults.standard.object(forKey: sizeKey) as? Double ?? sizeDefault
        return Font.custom(fontName, size: size * scale).weight(weight)
    }
}

/// Times New Roman for Latin text (CJK falls back to the system font), plus line spacing.
struct ReadingText: ViewModifier {
    @AppStorage(Reading.lineKey) private var line = Reading.lineDefault
    @AppStorage(Reading.sizeKey) private var scale = Reading.sizeDefault
    var size: CGFloat = 17
    func body(content: Content) -> some View {
        content
            .font(.custom(Reading.fontName, size: size * scale, relativeTo: .body))
            .lineSpacing(line)
    }
}

struct ReadingMargin: ViewModifier {
    @AppStorage(Reading.marginKey) private var margin = Reading.marginDefault
    func body(content: Content) -> some View { content.padding(.horizontal, margin) }
}

extension View {
    func readingText(_ size: CGFloat = 17) -> some View { modifier(ReadingText(size: size)) }
    /// Horizontal page margin from 设置 → 阅读.
    func readingMargin() -> some View { modifier(ReadingMargin()) }
}

struct ReadingSettingsView: View {
    @Environment(\.tr) private var T
    @AppStorage(Reading.lineKey) private var line = Reading.lineDefault
    @AppStorage(Reading.paraKey) private var para = Reading.paraDefault
    @AppStorage(Reading.marginKey) private var margin = Reading.marginDefault
    @AppStorage(Reading.sizeKey) private var scale = Reading.sizeDefault

    private let sample = """
    **Example.** The roots of $x^2 - 5x + 6 = 0$ are $\\alpha$ and $\\beta$. Find the value of $\\alpha^2 + \\beta^2$.

    由于 $\\alpha + \\beta = 5$ 且 $\\alpha\\beta = 6$，所以 $\\alpha^2 + \\beta^2 = (\\alpha + \\beta)^2 - 2\\alpha\\beta = 13$.

    A protocol is a set of rules that allows two devices to exchange data. 协议规定了数据的格式和传输方式。
    """

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                MathText(text: sample, size: 17)
                    .padding(.vertical, 16)
                    .readingMargin()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            .background(Color.cardBackground)
            .animation(.easeOut(duration: 0.15), value: line + para + margin + scale)
            Form {
                Section {
                    slider(T("Text size", "字号"), value: $scale, in: 0.8...1.6, step: 0.05, label: "\(Int((scale * 100).rounded()))%")
                    slider(T("Line spacing", "行间距"), value: $line, in: 0...16, step: 1, label: "\(Int(line))")
                    slider(T("Paragraph spacing", "段间距"), value: $para, in: 0...32, step: 2, label: "\(Int(para))")
                    slider(T("Margins", "页边距"), value: $margin, in: 0...64, step: 4, label: "\(Int(margin))")
                } footer: {
                    Text(T("Applies to cards, questions, options and solutions. English uses Times New Roman.", "用于知识卡、题目、选项和解答。英文使用 Times New Roman。"))
                }
                .listRowBackground(Color.cardBackground)
                Section {
                    Button(T("Reset", "恢复默认")) {
                        line = Reading.lineDefault; para = Reading.paraDefault; margin = Reading.marginDefault; scale = Reading.sizeDefault
                    }
                }
                .listRowBackground(Color.cardBackground)
            }
            .scrollContentBackground(.hidden)
        }
        .appScreen()
        .navigationTitle(T("Reading", "阅读"))
    }

    private func slider(_ title: String, value: Binding<Double>, in r: ClosedRange<Double>, step: Double, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(label).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: r, step: step)
        }
    }
}
