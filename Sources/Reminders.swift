import SwiftUI
import UserNotifications
import Observation

/// System-level study reminders for exam plans (local notifications).
@Observable
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Reminders()
    var status: UNAuthorizationStatus = .notDetermined
    /// Set when the student taps a reminder; the window opens that exam.
    var openExam: UUID?

    private let center = UNUserNotificationCenter.current()
    private var pending: Task<Void, Never>?

    func setUp() {
        center.delegate = self
        Task {
            await refreshStatus()
            // Ask once on first launch so reminders work without visiting 备考计划 first.
            if status == .notDetermined { await requestPermission() }
            reschedule()
        }
    }

    @MainActor func refreshStatus() async {
        status = await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestPermission() async -> Bool {
        let ok = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshStatus()
        reschedule()
        return ok
    }

    /// Rebuilds every pending reminder from the current plans. Debounced.
    func reschedule() {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await build()
        }
    }

    @MainActor private func build() async {
        let settings = await center.notificationSettings()
        status = settings.authorizationStatus
        center.removeAllPendingNotificationRequests()
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        let lib = Library.shared
        guard lib.loaded else { return }
        let en = UserDefaults.standard.string(forKey: "lang") == "en"
        let T = Tr(en: en)
        let cal = Calendar.current
        let now = Date()
        var requests: [UNNotificationRequest] = []
        let exams = ExamStore.shared.exams.filter { $0.remind && Planner.days(until: $0.date) >= 0 }
        // iOS keeps at most 64 pending requests; share them out between exams.
        let perExam = max(4, 60 / max(1, exams.count))
        for e in exams {
            let name = e.name.isEmpty ? T("Exam", "考试") : e.name
            let plan = Planner.plan(e, lib)
            var count = 0
            for (day, tasks) in plan {
                guard count < perExam - 1 else { break }
                let open = tasks.filter { e.done[$0.id] == nil }
                guard !open.isEmpty,
                      let fire = cal.date(bySettingHour: e.remindAt / 60, minute: e.remindAt % 60, second: 0, of: day),
                      fire > now else { continue }
                let left = Planner.days(until: e.date, from: day)
                let mins = open.reduce(0) { $0 + $1.minutes }
                let c = UNMutableNotificationContent()
                c.title = T("\(name) · \(left) days left", "\(name) · 还有 \(left) 天")
                let first = open.prefix(2).map { Planner.title($0, lib, T) }.joined(separator: "\n")
                c.body = T("Today: \(open.count) tasks, about \(mins) min\n", "今天：\(open.count) 项任务，约 \(mins) 分钟\n") + first
                c.sound = .default
                c.threadIdentifier = e.id.uuidString
                c.userInfo = ["exam": e.id.uuidString]
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                requests.append(UNNotificationRequest(identifier: "plan-\(e.id)-\(Int(day.timeIntervalSince1970))", content: c,
                                                      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
                count += 1
            }
            // Evening before the exam.
            if let eve = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: e.date)),
               let fire = cal.date(bySettingHour: 20, minute: 30, second: 0, of: eve), fire > now {
                let c = UNMutableNotificationContent()
                c.title = T("\(name) is tomorrow", "明天考 \(name)")
                c.body = T("Skim your wrong questions and get some sleep.", "看一遍错题，早点睡。")
                c.sound = .default
                c.threadIdentifier = e.id.uuidString
                c.userInfo = ["exam": e.id.uuidString]
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                requests.append(UNNotificationRequest(identifier: "eve-\(e.id)", content: c,
                                                      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }
        for r in requests.prefix(64) { try? await center.add(r) }
    }

    // Show banners while the app is open, and open the exam when tapped.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let s = response.notification.request.content.userInfo["exam"] as? String, let id = UUID(uuidString: s) {
            await MainActor.run { self.openExam = id }
        }
    }
}

/// Settings section: permission state and a shortcut to system settings.
struct ReminderSettingsSection: View {
    @Environment(\.tr) private var T
    @Environment(\.openURL) private var openURL
    @State private var r = Reminders.shared
    var body: some View {
        Section {
            switch r.status {
            case .denied:
                Button(T("Notifications are off. Open Settings", "通知已关闭，去系统设置打开")) {
                    if let u = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(u) }
                }
            case .notDetermined:
                Button(T("Allow study reminders", "允许复习提醒")) { Task { await r.requestPermission() } }
            default:
                Label(T("Reminders are on", "提醒已开启"), systemImage: "bell.badge.fill")
            }
        } header: {
            Text(T("Reminders", "提醒"))
        } footer: {
            Text(T("Set the time for each exam in Exam Plan.", "每场考试的提醒时间在备考计划里设置。"))
        }
        .listRowBackground(Color.cardBackground)
        .task { await r.refreshStatus() }
    }
}
