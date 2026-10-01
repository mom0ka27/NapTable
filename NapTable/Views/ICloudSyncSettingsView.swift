import SwiftUI

struct ICloudSyncSettingsView: View {
    @ObservedObject private var sync = ICloudSyncService.shared

    var body: some View {
        Form {
            Section {
                Toggle("iCloud 同步", isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) }))
                LabeledContent("状态") {
                    HStack {
                        if sync.isSyncing { ProgressView().controlSize(.small) }
                        Text(sync.statusText).multilineTextAlignment(.trailing)
                    }
                }
                if let date = sync.lastSyncedAt {
                    LabeledContent("上次同步") {
                        Text(date, format: .dateTime.month().day().hour().minute())
                    }
                }
                Button("立即同步") { Task { await sync.syncNow() } }
                    .disabled(!sync.isEnabled || sync.isSyncing)
            } footer: {
                Text("在使用同一 Apple 账号的设备上分别开启。打开 App 时自动同步，离线修改会在联网后重试。关闭后保留本机和云端已有数据。")
            }
            Section {
                Label("自己的课表、课程、学期与节次设置", systemImage: "calendar")
                Label("已保存的共享课表及备注", systemImage: "person.2")
                Label("分享管理记录，可在其他设备更新或撤销分享", systemImage: "link")
            } header: {
                Text("同步内容")
            } footer: {
                Text("显示偏好、当前选中的课表和通知设置由各设备分别保存。共享课表仍通过分享码与他人分享；iCloud 用于你自己的设备间同步。")
            }
            Section("数据与隐私") {
                Text("开启后，上述数据（包括课程名称、教师、教室以及分享管理凭证）会上传到你个人的 iCloud 私有数据库，由 Apple 提供存储。学校账号和密码不会上传。")
                Text("首次同步会合并已有课表。删除课表也会同步到其他设备；同时修改同一张课表时，以较新的修改为准。被替换前的本机数据会保存恢复副本。")
                Text("如需清空云端课表，请保持同步开启，删除自己的课表和已保存的共享课表，再等待同步完成。分享管理记录可从分享管理页面移除或撤销。")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Section {
                NavigationLink("恢复同步前的课表") { CloudSyncRecoveryView() }
            } footer: {
                Text("保留最近 5 份同步替换前的本机副本，可将其中自己的课表恢复为新课表。")
            }
        }
        .appListBackground()
        .navigationTitle("iCloud 同步")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
    }
}

private struct CloudSyncRecoveryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var message: String?

    var body: some View {
        List {
            if store.cloudRecoveryCopies.isEmpty {
                Text("尚无恢复副本").foregroundStyle(.secondary)
            }
            ForEach(store.cloudRecoveryCopies) { copy in
                Button {
                    do {
                        try store.restoreCloudRecovery(copy)
                        message = "已追加恢复为新课表，可在「我的课表」中查看。"
                    } catch { message = error.localizedDescription }
                } label: {
                    Label {
                        Text(copy.date, format: .dateTime.year().month().day().hour().minute().second())
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
            }
        }
        .appListBackground()
        .navigationTitle("恢复同步前的课表")
        .appInlineNavigationTitle()
        .alert("恢复课表", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }
}
