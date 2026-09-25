import SwiftUI

struct SchoolConfigView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section("服务地址") {
                LabeledContent("服务地址", value: ScheduleSharingService.shared.serverURLString)
                Text("导入时会自动读取对应学校配置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

/// Personal and shared schedules live in one management destination.
struct MySchedulesView<OwnedSchedules: View>: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var service = ScheduleSharingService.shared
    @Binding var showImport: Bool
    @ViewBuilder var ownedSchedules: () -> OwnedSchedules
    @State private var showingSharedImport = false
    @State private var message: String?
    @State private var pendingRemoval: FollowedSchedule?

    var body: some View {
        Form {
            Section("添加课表") {
                Button { showImport = true } label: {
                    Label("从学校导入", systemImage: "building.2")
                }
                Button { showingSharedImport = true } label: {
                    Label("用分享码导入", systemImage: "person.crop.rectangle.badge.plus")
                }
            }

            ownedSchedules()

            Section {
                if service.sharedSchedules.isEmpty {
                    Text("导入分享码后，在这里管理共享课表。")
                        .foregroundStyle(.secondary)
                }
                ForEach(service.sharedSchedules, id: \.meta.code) { schedule in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(schedule.name).font(.headline)
                                Text("\(schedule.meta.schoolName) · \(schedule.courses.count) 门课程")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button(role: .destructive) {
                                pendingRemoval = schedule
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.red)
                                    .frame(width: 36, height: 36)
                                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移除共享课表「\(schedule.name)」")
                            // 挂在垃圾桶按钮上：iOS 26 起确认框从触发它的视图旁边弹出，
                            // 挂在整个列表上会飘到屏幕中间。
                            .confirmationDialog(
                                "移除共享课表「\(schedule.name)」？",
                                isPresented: Binding(
                                    get: { pendingRemoval?.meta.code == schedule.meta.code },
                                    set: { if !$0 { pendingRemoval = nil } }
                                ),
                                titleVisibility: .visible
                            ) {
                                Button("移除课表", role: .destructive) {
                                    service.removeShared(schedule.meta.code)
                                    pendingRemoval = nil
                                }
                                Button("取消", role: .cancel) { pendingRemoval = nil }
                            } message: {
                                Text("仅从你的列表移除，不影响对方课表。如已设为关心，也会停止关注和实时通知。")
                            }
                        }
                        Toggle(isOn: Binding(
                            get: { service.followedCode == schedule.meta.code },
                            set: { value in
                                if value { service.follow(schedule) } else { service.unfollow() }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("设为关心")
                                Text("在锁屏实时活动和灵动岛显示对方课程。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("共享课表")
            } footer: {
                Text("一次可关心一人，取消后恢复显示自己的课程。仅切换查看课表不会改变关心对象。")
            }

            Section {
                NavigationLink {
                    ShareOwnScheduleView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("分享自己的课表").font(.headline)
                            Text("生成分享码，把课表发给朋友")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("我的课表")
        .appInlineNavigationTitle()
        .sheet(isPresented: $showingSharedImport) {
            SharedScheduleImportView { name in
                message = "已导入「\(name)」，可在课表顶部切换查看"
            }
        }
        .task { await service.refreshFollowed() }
    }

}

private struct ShareOwnScheduleView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var service = ScheduleSharingService.shared
    @State private var busy = false
    @State private var errorMessage: String?

    private var currentShare: ShareCredential? {
        guard let table = store.selectedTable else { return nil }
        return service.myShares.last { $0.tableID == table.id }
    }

    private var otherShares: [ShareCredential] {
        service.myShares.filter { $0.code != currentShare?.code }
    }

    private var canGenerateShare: Bool {
        guard let table = store.selectedTable else { return false }
        return service.canShare(courses: store.currentCourses, table: table)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("把课表分享给朋友")
                        .font(.title2.bold())
                    Text("朋友在「我的课表」中输入分享码，就能查看你的课程安排。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "calendar")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 48, height: 48)
                            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("当前课表").font(.caption).foregroundStyle(.secondary)
                            Text(store.selectedTable?.name ?? "还没有课表")
                                .font(.headline)
                            Text("\(store.currentCourses.count) 门课程")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if let credential = currentShare {
                        VStack(spacing: 12) {
                            Text("分享码").font(.caption).foregroundStyle(.secondary)
                            Text(credential.code)
                                .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
                                .tracking(3)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .textSelection(.enabled)
                                .accessibilityLabel("分享码：\(credential.code)")
                            Text("长按可复制")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

                        ShareLink(item: credential.code) {
                            Label("发送给朋友", systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "link").font(.largeTitle).foregroundStyle(Color.accentColor)
                            Text("生成一个分享码").font(.headline)
                            Text("只分享当前这张课表，朋友无法修改你的课程。")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }

                    if currentShare == nil || canGenerateShare {
                        Button(action: generateShare) {
                            HStack(spacing: 8) {
                                if busy { ProgressView() }
                                Text(busy ? "正在生成…" : currentShare == nil ? "生成分享码" : "更新分享码")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(busy || !canGenerateShare)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(20)
                .background(Color.appSecondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 24))

                Label {
                    Text(sharingHint)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 4)

                if !otherShares.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("其他分享码").font(.headline)
                        ForEach(otherShares) { credential in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(shareLabel(credential)).font(.subheadline.weight(.medium))
                                    Text(credential.code).font(.body.monospaced()).textSelection(.enabled)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                ShareLink(item: credential.code) {
                                    Label("发送", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(16)
                            .background(Color.appSecondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
            }
            .frame(maxWidth: 560)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Color.appGroupedBackground)
        .navigationTitle("分享课表")
        .appInlineNavigationTitle()
    }

    private var sharingHint: String {
        guard let table = store.selectedTable, table.schoolID != nil, table.termID != nil else {
            return "先从学校导入课表，就可以生成分享码。"
        }
        if currentShare != nil && !canGenerateShare {
            return "课表没有变更，可以继续使用这个分享码。"
        }
        return "课表变更后可更新分享码，更新后旧码失效，需要把新码发给朋友。"
    }

    private func shareLabel(_ credential: ShareCredential) -> String {
        store.tables.first { $0.id == credential.tableID }?.name ?? "已分享的课表"
    }

    private func generateShare() {
        guard !busy, let table = store.selectedTable else { return }
        busy = true
        errorMessage = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await service.share(courses: store.currentCourses, table: table)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Use a regular form instead of an alert text field, so the keyboard and
/// larger text sizes participate in the sheet's normal layout.
private struct SharedScheduleImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = ScheduleSharingService.shared
    let onImported: (String) -> Void
    @State private var input = ""
    @State private var remark = ""
    @State private var preview: FollowedSchedule?
    @State private var message: String?
    @State private var busy = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case code, remark }

    var body: some View {
        NavigationStack {
            Form {
                if let preview {
                    Section("课表预览") {
                        Label(preview.name, systemImage: "calendar")
                            .font(.headline)
                        LabeledContent("学校", value: preview.meta.schoolName)
                        LabeledContent("课程", value: "\(preview.courses.count) 门")
                    }
                    Section {
                        TextField("例如：小明的课表", text: $remark)
                            .textFieldStyle(.plain)
                            .padding(.vertical, 10)
                            .focused($focusedField, equals: .remark)
                            .submitLabel(.done)
                            .onSubmit { save(preview) }
                    } header: {
                        Text("为课表填写备注")
                    } footer: {
                        Text("备注仅自己可见，方便在课表列表中识别。")
                    }
                    Section {
                        Button("确认导入") { save(preview) }
                            .disabled(remark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("换一个分享码") {
                            self.preview = nil
                            message = nil
                            focusedField = .code
                        }
                    }
                } else {
                    Section {
                        TextField("输入分享码", text: $input)
                            .textFieldStyle(.plain)
                            .padding(.vertical, 10)
                            .appUppercasedInput()
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .code)
                            .submitLabel(.go)
                            .onSubmit { loadPreview() }
                            .disabled(busy)
                        Button(action: loadPreview) {
                            HStack {
                                Text(busy ? "正在读取课表…" : "预览课表")
                                Spacer()
                                if busy { ProgressView() }
                            }
                        }
                        .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: {
                        Text("分享码")
                    } footer: {
                        Text("输入对方发来的分享码，确认课表并填写备注后即可添加。")
                    }
                }
                if let message {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("导入共享课表")
            .appInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .appSheetDetents([.large])
        .appDragIndicatorVisible()
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func loadPreview() {
        guard !busy, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        message = nil
        focusedField = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let schedule = try await service.previewShare(input)
                remark = service.sharedSchedules.first { $0.meta.code == schedule.meta.code }?.remark ?? ""
                preview = schedule
                focusedField = .remark
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func save(_ schedule: FollowedSchedule) {
        let name = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try service.saveShared(schedule, remark: name)
            onImported(name)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
