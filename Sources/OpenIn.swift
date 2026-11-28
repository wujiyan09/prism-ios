import SwiftUI
import PDFKit

/// Files sent to Prism from another app's share sheet ("拷贝到 Prism") or opened from Files.
@Observable
final class OpenIn {
    static let shared = OpenIn()
    struct Item: Identifiable { let id = UUID(); var name: String; var doc: PDFDocument?; var error: String?; var restored = false }
    var item: Item?

    func receive(_ url: URL) {
        guard url.isFileURL else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url) else { item = Item(name: name, error: "无法读取这个文件"); return }
        if url.pathExtension.lowercased() == "prismpaper" {
            let ok = ImpBundle.restore(data) != nil || NoteBundle.restore(data) != nil
            item = Item(name: name, error: ok ? nil : "这个导出包无法读取", restored: ok)
            Task { await SyncManager.shared.sync() }
            return
        }
        if let d = PDFDocument(data: data) { item = Item(name: name, doc: d) }
        else if let im = UIImage(data: data) { item = Item(name: name, doc: ImpPDF.from(images: [im])) }
        else { item = Item(name: name, error: "只支持 PDF 或图片") }
        try? FileManager.default.removeItem(at: url)   // the Inbox copy; we keep our own
    }
}

struct OpenInSheet: View {
    let item: OpenIn.Item
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var subject = "math"
    @State private var done: String?
    @State private var folder = ""
    @State private var newFolder = false
    @State private var newName = ""

    var body: some View {
        Form {
            if let e = item.error {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if item.restored {
                Label("已导入导出包，可在「笔记」或「导入的试卷」中找到。", systemImage: "checkmark.circle")
            } else if let d = done {
                Label(d, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let doc = item.doc {
                Section { TextField("名称", text: $name) } footer: { Text("\(doc.pageCount) 页") }
                if RootView.notesOnly {
                    // Nodus: no subjects. Choose the folder the note goes into.
                    Section("存到文件夹") {
                        Picker("文件夹", selection: $folder) {
                            Text("笔记（顶层）").tag("")
                            ForEach(NoteStore.shared.folders, id: \.self) { f in Text(f.replacingOccurrences(of: "/", with: " › ")).tag(f) }
                        }
                        Button { newName = ""; newFolder = true } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                    }
                    Section {
                        Button {
                            let n = NoteStore.shared.createFrom(title: title, pdf: doc)
                            NoteStore.shared.update(n.id) { $0.folder = folder }
                            finish(folder.isEmpty ? "已存到「笔记」" : "已存到「\(NoteStore.leaf(folder))」")
                        } label: { Label("导入", systemImage: "square.and.arrow.down") }.bold()
                    }
                } else {
                Section("导入到") {
                      Button { let n = NoteStore.shared.createFrom(title: title, pdf: doc); _ = n; finish("已存到「笔记」") } label: {
                          Label("笔记", systemImage: "note.text")
                      }
                      Picker("科目", selection: $subject) {
                          Text("数学").tag("math"); Text("化学").tag("chem"); Text("ICT").tag("ict"); Text("中文").tag("zh"); Text("其他").tag("other")
                      }
                      Button { _ = ImportStore.shared.create(name: title, subject: subject, chapters: [], pdf: doc); finish("已存到「导入的试卷」") } label: {
                          Label("导入的试卷", systemImage: "doc.text.magnifyingglass")
                      }
                  }
                }
            }
        }
        .navigationTitle("导入到 \(AppBrand.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .onAppear { name = item.name }
        .alert("新建文件夹", isPresented: $newFolder) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let n = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
                guard !n.isEmpty else { return }
                NoteStore.shared.addFolder("", n); folder = n
            }
        }
    }
    private var title: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? item.name : name }
    private func finish(_ s: String) {
        done = s
        Task { await SyncManager.shared.sync(); try? await Task.sleep(for: .seconds(1)); dismiss() }
    }
}
