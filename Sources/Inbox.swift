import SwiftUI
import Observation

/// 收件箱: ideas / to-dos / notes, added in the app or remotely by Quest. Synced as "inbox/<id>".
struct InboxItem: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var title = ""
    var body = ""
    var kind = "note"             // idea | todo | note
    var date = Date().timeIntervalSince1970   // unix seconds
    var done = false
    var source: String? = nil      // "quest" when added remotely

    enum CodingKeys: String, CodingKey { case id, title, body, kind, date, done, source }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "note"
        date = (try? c.decode(Double.self, forKey: .date)) ?? Date().timeIntervalSince1970
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
        source = try? c.decode(String.self, forKey: .source)
    }

    static let kinds = ["idea", "todo", "note"]
    static func kindName(_ k: String) -> String { ["idea": "想法", "todo": "待办", "note": "笔记"][k] ?? "笔记" }
    static func kindIcon(_ k: String) -> String { ["idea": "lightbulb", "todo": "checklist", "note": "note.text"][k] ?? "note.text" }
}

@Observable
final class InboxStore {
    static let shared = InboxStore()
    var items: [String: InboxItem] = [:] { didSet { save() } }
    private static var file: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("inbox.json")
    }
    init() {
        if let d = try? Data(contentsOf: Self.file), let x = try? JSONDecoder().decode([String: InboxItem].self, from: d) { items = x }
    }
    private func save() { if let d = try? JSONEncoder().encode(items) { try? d.write(to: Self.file, options: .atomic) } }
    var sorted: [InboxItem] { items.values.sorted { ($0.done ? 1 : 0, -$0.date) < ($1.done ? 1 : 0, -$1.date) } }
    func put(_ i: InboxItem) { items[i.id] = i; Task { await SyncManager.shared.sync() } }
    func remove(_ id: String) { items[id] = nil; Task { await SyncManager.shared.sync() } }
}

struct InboxView: View {
    @State private var store = InboxStore.shared
    @Environment(\.tr) private var T
    @State private var filter = "all"
    @State private var editing: InboxItem?

    var body: some View {
        let list = store.sorted.filter { filter == "all" || $0.kind == filter }
        List {
            Section {
                Picker("", selection: $filter) {
                    Text(T("All", "全部")).tag("all")
                    ForEach(InboxItem.kinds, id: \.self) { k in Text(InboxItem.kindName(k)).tag(k) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            if list.isEmpty {
                ContentUnavailableView(T("Inbox is empty", "收件箱是空的"), systemImage: "tray",
                                       description: Text(T("Ideas, to-dos and notes land here, from you or from Quest.", "想法、待办和笔记会放在这里，可以自己加，也可以由 Quest 发来。")))
                    .listRowBackground(Color.clear)
            }
            ForEach(list) { i in
                row(i)
                    .listRowBackground(Color.cardBackground)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { withAnimation { store.remove(i.id) } } label: { Label(T("Delete", "删除"), systemImage: "trash") }
                    }
                    .swipeActions(edge: .leading) {
                        Button { var x = i; x.done.toggle(); withAnimation { store.put(x) } } label: {
                            Label(i.done ? T("Undo", "未完成") : T("Done", "完成"), systemImage: i.done ? "arrow.uturn.backward" : "checkmark")
                        }.tint(.green)
                    }
            }
        }
        .listStyle(.insetGrouped)
        .appList()
        .navigationTitle(T("Inbox", "收件箱"))
        .refreshable { await SyncManager.shared.sync() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = InboxItem() } label: { Label(T("Add", "添加"), systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { i in InboxEditor(item: i).environment(\.tr, T) }
    }

    private func row(_ i: InboxItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { var x = i; x.done.toggle(); withAnimation { store.put(x) } } label: {
                Image(systemName: i.done ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(i.done ? Color.good : Color.secondary)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label(InboxItem.kindName(i.kind), systemImage: InboxItem.kindIcon(i.kind)).font(.caption.bold()).foregroundStyle(.secondary)
                    Text(Date(timeIntervalSince1970: i.date).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
                    if i.source == "quest" { Text(T("from Quest", "来自 Quest")).font(.caption2).foregroundStyle(.secondary) }
                }
                if !i.title.isEmpty { Text(i.title).font(.headline).strikethrough(i.done).foregroundStyle(i.done ? .secondary : .primary) }
                if !i.body.isEmpty { DSMarkdown(text: i.body).opacity(i.done ? 0.6 : 1) }
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = i }
        }
        .padding(.vertical, 4)
    }
}

struct InboxEditor: View {
    @State var item: InboxItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tr) private var T
    var body: some View {
        NavigationStack {
            Form {
                Picker(T("Kind", "类型"), selection: $item.kind) {
                    ForEach(InboxItem.kinds, id: \.self) { k in Text(InboxItem.kindName(k)).tag(k) }
                }
                .pickerStyle(.segmented)
                TextField(T("Title", "标题"), text: $item.title)
                TextField(T("Details (Markdown, $LaTeX$)", "内容（支持 Markdown 和 $LaTeX$）"), text: $item.body, axis: .vertical).lineLimit(4...12)
                Toggle(T("Done", "已完成"), isOn: $item.done)
            }
            .navigationTitle(T("Inbox item", "收件箱条目"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(T("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Save", "保存")) { InboxStore.shared.put(item); dismiss() }
                        .disabled(item.title.isEmpty && item.body.isEmpty)
                }
            }
        }
    }
}
