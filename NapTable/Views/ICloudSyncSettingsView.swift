import SwiftUI

struct ICloudSyncSettingsView: View {
    @ObservedObject private var sync = ICloudSyncService.shared
    var presentsReviewDuringOnboarding = false

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
                if sync.pendingReview != nil {
                    Button("查看云端课表更新") { sync.isReviewPresented = true }
                }
                Button("立即同步") { Task { await sync.syncNow(refreshReview: true) } }
                    .disabled(!sync.isEnabled || sync.isSyncing)
            } footer: {
                Text("在使用同一 Apple 账号的设备上分别开启。本机修改和设置自动同步；发现云端课表有内容更新时，列出修改项与来源设备，由你确认是否接收。关闭后保留已有数据。")
            }
            Section {
                Label("自己的课表、课程、学期与节次设置", systemImage: "calendar")
                Label("已保存的共享课表及备注", systemImage: "person.2")
                Label("分享管理记录，可在其他设备更新或撤销分享", systemImage: "link")
                Label("关心对象", systemImage: "person.crop.circle.badge.checkmark")
            } header: {
                Text("同步内容")
            } footer: {
                Text("关心对象、课表配置和共享备注自动同步，不弹出确认。实时活动开关、提前显示时间、分节计时、系统权限、显示偏好和当前选中的课表均由本机保存。")
            }
            Section("数据与隐私") {
                Text("开启后，上述数据（包括课程名称、教师、教室、分享管理凭证与修改设备名称）会保存到你个人的 iCloud 私有数据库。App 不单独保存学校账号和密码，也不会将它们纳入同步；学校网页的登录会话保留在本机。")
                Text("远程新增、删除或课程内容变更须确认。接收自己的课表时，可更新对应课表、替换当前课表或新建课表；同一课表并发修改以较新版本为准。")
                Text("如需清空云端课表，请保持同步开启，删除自己的课表和已保存的共享课表，再等待同步完成。分享管理记录可从分享管理页面移除或撤销。")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .appListBackground()
        .navigationTitle("iCloud 同步")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
        .sheet(isPresented: Binding(
            get: { presentsReviewDuringOnboarding && sync.isReviewPresented },
            set: { if !$0 { sync.deferReview() } }
        )) {
            NavigationStack { ICloudSyncReviewView() }
        }
    }
}

struct ICloudSyncReviewView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var sync = ICloudSyncService.shared
    @State private var destinations: [String: String] = [:]

    var body: some View {
        Form {
            if let review = sync.pendingReview {
                Section {
                    Text("发现云端课表更新，要接收吗？")
                    Text(sync.statusText).font(.footnote).foregroundStyle(.secondary)
                } footer: {
                    Text("确认前保留本机课程内容。设置与本机修改继续自动同步；可以暂不接收，稍后从 iCloud 同步设置继续。")
                }
                changeSection(review, direction: .download, title: "云端课表更新")
                Section {
                    Text("替换当前课表会覆盖其课程与课表配置，并与云端课表使用同一同步身份，其他设备也会收到这个结果。选择新建课表可保留本机版本和云端版本。一次只能将一张云端课表替换到当前课表。")
                }.font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("没有待确认的修改").foregroundStyle(.secondary)
            }
        }
        .appListBackground()
        .navigationTitle("接收课表更新")
        .appInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("暂不接收") { sync.deferReview() }.disabled(sync.isSyncing)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("确认接收") {
                    guard let review = sync.pendingReview else { return }
                    let choices = tableChoices(review)
                    Task { await sync.confirmReview(review.id, destinations: choices) }
                }
                .disabled(sync.isSyncing || sync.pendingReview == nil || !choicesAreValid)
            }
        }
        .onChange(of: sync.pendingReview?.id) { _, _ in destinations = [:] }
        .interactiveDismissDisabled(sync.isSyncing)
    }

    private var choicesAreValid: Bool {
        destinations.values.filter { $0.hasPrefix("current:") }.count <= 1
    }

    private func changeSection(_ review: CloudSyncReview, direction: CloudSyncChange.Direction, title: String) -> some View {
        let changes = review.changes.filter { $0.direction == direction }
        return Section(title) {
            if changes.isEmpty { Text("没有修改").foregroundStyle(.secondary) }
            ForEach(changes) { change in
                VStack(alignment: .leading, spacing: 8) {
                    Text(change.title).font(.headline)
                    Text("修改设备：\(change.device)").font(.caption).foregroundStyle(.secondary)
                    Text(change.modifiedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(change.details.prefix(4).enumerated()), id: \.offset) { _, detail in
                        Text(detail).font(.subheadline)
                    }
                    if change.details.count > 4 {
                        DisclosureGroup("其余 \(change.details.count - 4) 项修改") {
                            ForEach(Array(change.details.dropFirst(4).enumerated()), id: \.offset) { _, detail in
                                Text(detail).font(.subheadline)
                            }
                        }
                    }
                    if change.incomingTable != nil {
                        Picker("接收方式", selection: Binding(
                            get: { destinations[change.key] ?? defaultDestination(change) },
                            set: { destinations[change.key] = $0 }
                        )) {
                            if let matching = store.tables.first(where: { "table:" + ($0.syncID ?? "") == change.key }) {
                                Text("更新对应课表：\(matching.name)").tag("matching")
                            }
                            if let selected = store.selectedTable,
                               "table:" + (selected.syncID ?? "") != change.key,
                               !review.changes.contains(where: { $0.key == "table:" + (selected.syncID ?? "") && $0.incomingTable != nil }) {
                                Text("替换当前课表：\(selected.name)").tag("current:\(selected.id)")
                            }
                            Text("新建一个课表").tag("new")
                        }
                        if let choice = destinations[change.key], choice.hasPrefix("current:"),
                           let id = Int(choice.dropFirst(8)),
                           let target = store.tables.first(where: { $0.id == id }),
                           case .table(let old) = store.cloudSnapshot()["table:" + (target.syncID ?? "")],
                           let incoming = change.incomingTable {
                            DisclosureGroup("替换「\(target.name)」后的修改") {
                                ForEach(Array(CloudSyncReview.tableDetails(old, incoming).enumerated()), id: \.offset) { _, detail in
                                    Text(detail).font(.subheadline)
                                }
                                Text("相关分享管理记录也会关联到接收的课表。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func defaultDestination(_ change: CloudSyncChange) -> String {
        store.tables.contains { "table:" + ($0.syncID ?? "") == change.key } ? "matching" : "new"
    }

    private func tableChoices(_ review: CloudSyncReview) -> [String: CloudTableDestination] {
        Dictionary(uniqueKeysWithValues: review.changes.filter { $0.incomingTable != nil }.map { change in
            let choice = destinations[change.key] ?? defaultDestination(change)
            let destination: CloudTableDestination
            if choice == "new" { destination = .new }
            else if choice.hasPrefix("current:"), let id = Int(choice.dropFirst(8)) { destination = .current(id) }
            else { destination = .matching }
            return (change.key, destination)
        })
    }
}
