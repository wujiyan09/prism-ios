import Foundation

/// A subject plugged into Prism. Each subject has its own content source,
/// textbooks (books → chapters) and past papers. ICT is the first one.
struct Subject: Identifiable, Hashable {
    let id: String
    let name: String
    let nameZh: String
    let icon: String
    /// Base URL of the subject's content repo (data/, pages/, figs/).
    let base: String
    /// Folder name for the offline cache.
    let cacheName: String
    /// Content ships inside the app (no download). Split-screen scratch is on for these.
    var bundled = false
    var scratch: Bool { bundled && id != "zh" }

    static let ict = Subject(id: "ict", name: "ICT", nameZh: "资讯及通讯科技", icon: "desktopcomputer",
                             base: "https://raw.githubusercontent.com/wujiyan09/ict-portal/main/", cacheName: "ictdata")

    static let math = Subject(id: "math", name: "Maths", nameZh: "数学", icon: "function", base: "", cacheName: "math", bundled: true)

    static let zh = Subject(id: "zh", name: "Chinese", nameZh: "中文", icon: "character.book.closed", base: "", cacheName: "math", bundled: true)

    static let all: [Subject] = [.ict, .math, .zh]
    static func find(_ id: String) -> Subject { all.first { $0.id == id } ?? .ict }

    /// Subjects in the order Sam chose (Settings / Edit on the subject list).
    static var ordered: [Subject] {
        let ids = (UserDefaults.standard.string(forKey: "subject.order") ?? "").split(separator: ",").map(String.init)
        return all.sorted { (ids.firstIndex(of: $0.id) ?? 99, all.firstIndex(of: $0) ?? 0) < (ids.firstIndex(of: $1.id) ?? 99, all.firstIndex(of: $1) ?? 0) }
    }
    static func saveOrder(_ s: [Subject]) { UserDefaults.standard.set(s.map(\.id).joined(separator: ","), forKey: "subject.order") }
}
