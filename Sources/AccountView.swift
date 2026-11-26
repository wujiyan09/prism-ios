import SwiftUI

/// 设置 → 账号
struct AccountView: View {
    @State private var sync = SyncManager.shared
    @Environment(\.tr) private var T

    var body: some View {
        Form {
            if sync.signedIn {
                Section {
                    LabeledContent(T("Google account", "Google 账号"), value: sync.email ?? "—")
                    LabeledContent(T("Last synced", "上次同步")) {
                        if sync.syncing { ProgressView() }
                        else { Text(sync.lastSynced.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? T("Never", "从未")) }
                    }
                    Button(T("Sync now", "立即同步")) { Task { await sync.sync() } }
                        .disabled(sync.syncing)
                } footer: {
                    Text(T("Progress, quiz history, daily practice results, exam plans and settings sync across your devices. Scratch paper stays on this device.",
                           "进度、做题记录、每日练习结果、备考计划和设置会在你的设备之间同步。草稿纸不同步。"))
                }
                Section {
                    Button(T("Sign out", "退出登录"), role: .destructive) { sync.signOut() }
                } footer: {
                    Text(T("Data already on this device stays here.", "退出后，这台设备上的数据会保留。"))
                }
            } else {
                Section {
                    if sync.configured == false {
                        Label(T("Not set up yet", "尚未配置"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            sync.signIn()
                        } label: {
                            Label(T("Sign in with Google", "使用 Google 登录"), systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                } footer: {
                    Text(T("Sign in to sync your progress across devices. What's already on this device is merged into your account.",
                           "登录后可以在多台设备之间同步进度。这台设备上已有的数据会合并到账号里。"))
                }
            }
            if let e = sync.error {
                Section { Text(e).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle(T("Account", "账号"))
        .task { await sync.checkConfigured() }
    }
}
