import SwiftUI

struct CodeEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 180
    var body: some View {
        TextEditor(text: $text)
            .font(.system(.callout, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(8)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel("Code")
    }
}

struct ResultTables: View {
    let sets: [ResultSet]
    @Environment(\.tr) private var T
    var body: some View {
        if sets.isEmpty {
            Text(T("(no rows)", "（没有返回行）")).font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sets) { s in
                    TableBlock(rows: [s.columns.map { TableCell(text: AttributedString($0), header: true) }]
                               + s.rows.prefix(100).map { $0.map { TableCell(text: AttributedString($0), header: false) } })
                }
            }
        }
    }
}

struct OutcomeView: View {
    let outcome: RunOutcome
    @Environment(\.tr) private var T
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(outcome.pass ? T("Passed", "通过") : T("Not yet", "未通过"),
                  systemImage: outcome.pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.headline)
                .foregroundStyle(outcome.pass ? Color.good : Color.bad)
            if !outcome.tables.isEmpty { ResultTables(sets: outcome.tables) }
            if !outcome.stdout.isEmpty { CodeBlock(text: outcome.stdout) }
            if !outcome.error.isEmpty {
                Text(outcome.error).font(.system(.callout, design: .monospaced)).foregroundStyle(Color.bad).textSelection(.enabled)
            }
            ForEach(outcome.lines) { l in
                Label {
                    Text(l.text).font(.system(.callout, design: .monospaced))
                } icon: {
                    Image(systemName: l.ok ? "checkmark" : "xmark").foregroundStyle(l.ok ? Color.good : Color.bad)
                }
            }
            if let e = outcome.expectedOutput {
                Text(T("Expected output", "应输出")).font(.caption).foregroundStyle(.secondary)
                CodeBlock(text: e)
            }
            if let e = outcome.expected {
                DisclosureGroup(T("Expected result", "应有结果")) { ResultTables(sets: e).padding(.top, 6) }
            }
        }
    }
}

/// Task + editor + run/check. Used in sessions and on its own page.
struct PracticalEditor: View {
    let item: Item
    let practical: Practical
    @Binding var code: String
    var inSession = false
    var onResult: (Bool) -> Void = { _ in }
    @Environment(\.tr) private var T
    @State private var outcome: RunOutcome?
    @State private var running = false
    @State private var showModel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(T(practical.t, practical.tz ?? practical.t)).font(.title3.bold())
                Spacer()
                Text((practical.lang ?? "").uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let s = practical.src, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary) }
            RichText(html: T(practical.task, practical.taskz ?? practical.task))
            if (practical.lang ?? "") == "sql", let setup = practical.setup, !setup.isEmpty {
                DisclosureGroup(T("Tables", "数据表")) { CodeBlock(text: setup).padding(.top, 6) }
            }
            CodeEditor(text: $code)
            if practical.isSelfCheck {
                DisclosureGroup(T("Model answer", "参考答案"), isExpanded: $showModel) {
                    CodeBlock(text: practical.modelAnswer).padding(.top, 6)
                }
                if inSession {
                    Toggle(T("My answer matches the model answer", "我的答案和参考答案一致"),
                           isOn: Binding(get: { outcome?.pass ?? false }, set: { v in var o = RunOutcome(); o.pass = v; outcome = o; onResult(v) }))
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { buttons }
                    VStack(alignment: .leading) { buttons }
                }
                if running { ProgressView(T("Running…", "运行中…")) }
                if let outcome { OutcomeView(outcome: outcome) }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button {
            Task { await run() }
        } label: {
            Label(T("Run & check", "运行并检查"), systemImage: "play.fill")
        }
        .glassButton(prominent: true)
        .disabled(running)
        .keyboardShortcut("r", modifiers: .command)
        if !inSession {
            Button {
                code = practical.solution ?? practical.modelAnswer
            } label: {
                Label(T("Show solution", "看参考答案"), systemImage: "lightbulb")
            }
            .glassButton()
            Button(role: .destructive) {
                code = practical.starter ?? ""; outcome = nil
            } label: {
                Label(T("Reset", "重置"), systemImage: "arrow.uturn.backward")
            }
            .glassButton()
        }
    }

    private func run() async {
        running = true
        let o = await Runner.run(practical, code: code)
        outcome = o
        running = false
        onResult(o.pass)
    }
}

struct PracticalPage: View {
    let key: String
    @Environment(Library.self) private var lib
    @Environment(ProgressStore.self) private var prog
    @Environment(\.tr) private var T
    @State private var code: String?

    var body: some View {
        if let it = lib.items[key], let p = it.practical, let c = it.chapterID.flatMap({ lib.chapter($0) }) {
            let idx = c.pr.firstIndex(of: key) ?? 0
            ScrollView {
                PracticalEditor(item: it, practical: p,
                                code: Binding(get: { code ?? p.starter ?? "" }, set: { code = $0 })) { pass in
                    prog.record(key, ok: pass)
                }
                .card()
                .frame(maxWidth: 820)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .softEdges()
            .appScreen()
            .navigationTitle(c.name)
            .noteRecent(.practical(key), c.name, T(p.t, p.tz ?? p.t))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if idx > 0 {
                        NavigationLink(value: Route.practical(c.pr[idx - 1])) { Label(T("Previous", "上一题"), systemImage: "chevron.left") }
                    }
                    Spacer()
                    Text("\(idx + 1) / \(c.pr.count)").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    if idx < c.pr.count - 1 {
                        NavigationLink(value: Route.practical(c.pr[idx + 1])) { Label(T("Next", "下一题"), systemImage: "chevron.right") }
                    }
                }
            }
        } else {
            ContentUnavailableView(T("Not found", "找不到"), systemImage: "questionmark")
        }
    }
}
