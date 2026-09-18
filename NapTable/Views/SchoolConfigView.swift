import SwiftUI

struct SchoolConfigView: View {
    @EnvironmentObject private var store: AppStore
    @State private var serverURL = ScheduleSharingService.shared.serverURLString
    @State private var message: String?

    var body: some View {
        Form {
            Section("服务地址") {
                TextField("服务地址", text: $serverURL)
                Button("保存服务地址") {
                    do {
                        try ScheduleSharingService.shared.setServerURL(serverURL)
                        message = "已保存，导入时会自动读取对应学校配置"
                    } catch { message = error.localizedDescription }
                }
            }
            Section("当前课表配置") {
                if let table = store.selectedTable, let school = table.schoolID, let term = table.termID {
                    LabeledContent("学校", value: school)
                    LabeledContent("学期", value: term)
                    LabeledContent("版本", value: "v\(table.termVersion ?? 0)")
                    LabeledContent("第一周周一", value: table.semesterStartMonday)
                    LabeledContent("总周数", value: "\(table.termWeekCount ?? store.maxWeeks)")
                    LabeledContent("调休", value: adjustmentSummary(table))
                } else {
                    Text("选择学校导入课表后，自动读取对应学校的学期和节次配置。")
                }
            }
            if let table = store.selectedTable, let list = table.calendarAdjustments, !list.isEmpty {
                Section("调休安排") {
                    ForEach(list) { item in
                        LabeledContent(
                            item.date,
                            value: table
                                .calendarAdjustmentIndex(anchor: store.effectiveSemesterStartMonday)[item.date]?
                                .detail ?? item.note
                        )
                    }
                    Text("由学校配置下发，课表、月历、小组件和灵动岛都会按这些日期覆盖课程。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("节次时间") {
                ForEach(Array(store.classTimeList.enumerated()), id: \.offset) { index, period in
                    LabeledContent("第\(index + 1)节", value: "\(period.start)–\(period.end)")
                }
            }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("课表服务")
    }

    private func adjustmentSummary(_ table: CourseTable) -> String {
        let list = table.calendarAdjustments ?? []
        guard !list.isEmpty else { return "无" }
        let off = list.filter { $0.kind == .off }.count
        let swap = list.count - off
        return [off > 0 ? "放假 \(off) 天" : nil, swap > 0 ? "补课 \(swap) 天" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct ShareScheduleView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var service = ScheduleSharingService.shared
    @State private var input = ""
    @State private var preview: FollowedSchedule?
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Button("生成分享码") { run { try await share() } }
                    .disabled(busy)
                ForEach(service.myShares) { credential in
                    shareRow(credential)
                }
                if service.myShares.isEmpty {
                    Text("分享码由服务端保存，写入权限只在本机。换机后旧分享无法再更新或撤销。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("我的分享")
            } footer: {
                Text("「更新课程」把当前课表重新发布到同一个分享码，看的人不用换码。\n"
                     + "「同步校历时间」按学校最新的节次和调休重新固化——分享创建时的时间不会被管理员的修改悄悄改掉，只有你确认才更新。")
            }

            Section {
                if let followed = service.followedSchedule {
                    LabeledContent("来源", value: followed.name)
                    LabeledContent("课程数", value: "\(followed.courses.count)")
                    LabeledContent("节次", value: "\(followed.classTimes.count) 节 · 首节 \(followed.classTimes.first?.start ?? "--")")
                    LabeledContent("第一周周一", value: followed.meta.semesterStartMonday)
                    if !followed.adjustments.isEmpty {
                        LabeledContent("调休", value: "\(followed.adjustments.count) 天")
                    }
                    Button("立即刷新") { run { await service.refreshFollowed() } }
                        .disabled(busy)
                    Button("切回我的课表", role: .destructive) { service.unfollow(); message = "已切回我的课表" }
                }
            } header: {
                Text("当前提示来源")
            } footer: {
                if service.followedSchedule != nil {
                    Text("小组件和灵动岛显示这张课表，用的是对方学校的节次时间、第一周和调休；本机课表界面不受影响。")
                } else {
                    Text("没有关注任何人时，小组件和灵动岛显示你自己的课表。")
                }
            }

            Section("查看他人课表") {
                TextField("输入分享码", text: $input)
                    .appUppercasedInput()
                    .autocorrectionDisabled()
                Button("读取预览") { run { try await lookup() } }
                    .disabled(busy || input.trimmingCharacters(in: .whitespaces).isEmpty)
                if let preview {
                    LabeledContent("课表", value: preview.name)
                    LabeledContent("学校", value: preview.meta.schoolName)
                    LabeledContent("课程数", value: "\(preview.courses.count)")
                    LabeledContent("节次时间", value: "\(preview.classTimes.count) 节 · 首节 \(preview.classTimes.first?.start ?? "--")")
                    LabeledContent("第一周周一", value: preview.meta.semesterStartMonday)
                    Button("加入我的课表") {
                        _ = store.install(payload: preview.importedSchedule, mode: .newTable)
                        message = "已加入我的课表，节次时间跟随对方学校"
                    }
                    Button("设为提示来源") {
                        service.follow(preview)
                        message = "已设为提示来源；小组件和灵动岛改用这张课表"
                    }
                }
            }

            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("课表分享")
        .task { await service.refreshFollowed() }
    }

    @ViewBuilder
    private func shareRow(_ credential: ShareCredential) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(credential.code).font(.title3.monospaced())
            if !credential.label.isEmpty {
                Text(credential.label).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Button("更新课程") { run { try await update(credential) } }
                Button("同步校历时间") { run { try await resync(credential) } }
                Button("撤销", role: .destructive) { run { try await service.revoke(credential) } }
            }
            .font(.footnote)
            .buttonStyle(.borderless)
            .disabled(busy)
        }
        .padding(.vertical, 2)
    }

    /// One place to serialise the calls and turn a thrown error into the
    /// message line, so every button reports failure the same way.
    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            do { try await work() } catch { message = error.localizedDescription }
            busy = false
        }
    }

    private func share() async throws {
        guard let schoolID = store.selectedTable?.schoolID, let termID = store.selectedTable?.termID else {
            message = "请先从对应学校导入课表，学校配置会自动匹配"
            return
        }
        let result = try await service.share(courses: store.currentCourses, schoolID: schoolID, termID: termID)
        message = "已创建分享 \(result.id)"
    }

    private func update(_ credential: ShareCredential) async throws {
        _ = try await service.update(credential, courses: store.currentCourses)
        message = "已用当前课表更新 \(credential.code)"
    }

    private func resync(_ credential: ShareCredential) async throws {
        let result = try await service.resync(credential)
        message = "\(credential.code) 已同步到 \(result.schoolName) 的最新校历（v\(result.termVersion)）"
    }

    private func lookup() async throws {
        preview = try await service.previewShare(input)
        message = "已读取预览"
    }
}

extension Notification.Name {
    static let naptableFollowedSourceChanged = Notification.Name("naptable.followedSourceChanged")
}
