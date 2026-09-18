import SwiftUI

/// The import hub. Mirrors the Flutter app's `ImportView`: the configuration-driven
/// WebView importers and manual entry.
struct ImportView: View {
    @EnvironmentObject private var store: AppStore
    /// The ported schedule store. Manual entry uses the same editor as a tap on
    /// an empty grid slot, so both paths create courses the same way.
    @EnvironmentObject private var scheduleStore: NativeScheduleStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode: AppStore.ImportMode = .replaceCurrent
    @State private var manualPresented = false
    @State private var webSchool: SchoolConfig?
    /// Set after an import lands. It is shown inline instead of in another
    /// sheet: presenting a sheet while this one is dismissing is what made the
    /// screen flash and lose the result.
    @State private var imported: ImportedSchedule?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        manualPresented = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("手动添加课程")
                                Text("不依赖学校系统，自己填写课程时间")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                } header: {
                    Text("快捷导入")
                }

                Section {
                    ForEach(SchoolCatalog.all) { school in
                        Button {
                            webSchool = school
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(school.title)
                                Text(school.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!school.hasExtractor)
                    }
                } header: {
                    Text("网页导入（在应用内登录学校系统）")
                } footer: {
                    Text("推荐优先用这一条：它打开学校的真实登录页，统一身份认证、验证码、会话全部由学校页面处理，"
                         + "应用只读取课表页面，不保存账号密码。")
                }

                Section {
                    Picker("导入方式", selection: $mode) {
                        ForEach(AppStore.ImportMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                } header: {
                    Text("导入到")
                } footer: {
                    Text(mode == .replaceCurrent
                         ? "清空当前课表后再写入导入结果。"
                         : (mode == .newTable
                            ? "每次导入都会新建一张课表。"
                            : "保留当前课表，把导入的课程追加进去。"))
                }

                if let imported {
                    Section("导入结果") {
                        Label("导入成功", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Color.accentColor)
                        LabeledContent("课表", value: imported.name)
                        LabeledContent("课程条数", value: "\(imported.courses.count)")
                        LabeledContent("覆盖周次", value: weekSummary(of: imported))
                        Button {
                            self.imported = nil
                        } label: {
                            Label("继续导入", systemImage: "arrow.clockwise")
                        }
                    }

                    if imported.termID == nil { Section("校正周次") {
                        Text("设置学期第一周的星期一，应用就能自动算出当前是第几周。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DatePicker(
                            "第一周星期一",
                            selection: Binding(
                                get: { WeekCalculator.parseDay(store.semesterStartMonday) ?? WeekCalculator.monday(of: Date()) },
                                set: { store.updateSemesterStart(WeekCalculator.format(WeekCalculator.monday(of: $0))) }
                            ),
                            displayedComponents: .date
                        )
                        Button("使用今天所在的星期一") {
                            store.updateSemesterStart(WeekCalculator.format(WeekCalculator.monday(of: Date())))
                        }
                        .font(.caption)
                    } } else {
                        Section("学校配置") {
                            LabeledContent("学校", value: imported.schoolID ?? "")
                            LabeledContent("学期", value: imported.termID ?? "")
                            Text("开学日期与节次已自动使用对应学校的服务端配置。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if !store.tables.isEmpty {
                    Section("当前课表") {
                        LabeledContent("名称", value: store.selectedTable?.name ?? "-")
                        LabeledContent("课程条数", value: "\(store.currentCourses.count)")
                        LabeledContent("学期开始", value: store.semesterStartMondayDisplay)
                    }
                }
            }
            .navigationTitle("导入课表")
            .appInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $manualPresented) {
                NativeCourseEditorSheet(
                    selection: nil,
                    store: scheduleStore,
                    defaultDay: 1,
                    defaultWeek: store.displayWeek,
                    defaultStartSlot: 1
                )
                .appSheetDetents([.large])
                .appDragIndicatorVisible()
            }
            .sheet(item: $webSchool) { school in
                WebImporterView(school: school, initialMode: mode) { schedule, selectedMode in
                    store.install(payload: schedule, mode: selectedMode)
                    imported = schedule
                }
            }
        }
    }

}

extension ImportView {
    /// "第 3-17 周" style summary of the imported week span.
    func weekSummary(of schedule: ImportedSchedule) -> String {
        let weeks = schedule.courses.flatMap(\.weeks)
        guard let first = weeks.min(), let last = weeks.max() else { return "-" }
        return "第 \(first)-\(last) 周"
    }
}

/// The parse summary plus the destination picker. It is embedded inside whatever
/// sheet performed the import, so a successful login never has to stack a second
/// sheet on top of one that is still dismissing.
struct ImportedScheduleForm: View {
    let schedule: ImportedSchedule
    @Binding var mode: AppStore.ImportMode

    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            Section("解析结果") {
                Label("解析成功", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Color.accentColor)
                LabeledContent("课表名称", value: schedule.name)
                LabeledContent("课程条数", value: "\(schedule.courses.count)")
                if let term = schedule.termID {
                    LabeledContent("自动匹配学期", value: term)
                }
                if let start = schedule.semesterStartMonday, !start.isEmpty {
                    LabeledContent("学期开始", value: start)
                }
            }
            Section("导入到") {
                ForEach(AppStore.ImportMode.allCases) { item in
                    Button {
                        mode = item
                    } label: {
                        HStack {
                            Text(item.title).foregroundStyle(.primary)
                            Spacer()
                            if mode == item {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        // With `.buttonStyle(.plain)` the label's `Spacer()` is
                        // not hit-testable, so only the text reacted and tapping
                        // the rest of the row did nothing. This makes the whole
                        // row a tap target.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(item == .appendToCurrent && !canAppend)
                }
                if !canAppend {
                    Text("当前课表的学校或学期配置不同，请新建或覆盖课表。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text(consequence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if mode == .appendToCurrent && !canAppend { mode = .newTable }
        }
    }

    private var canAppend: Bool {
        guard !store.currentCourses.isEmpty, let table = store.selectedTable else { return true }
        return table.schoolID == schedule.schoolID && table.termID == schedule.termID
            && (schedule.classTimeList == nil || table.effectiveClassTimeList == schedule.classTimeList)
            && (schedule.semesterStartMonday == nil || table.semesterStartMonday == schedule.semesterStartMonday)
    }

    private var consequence: String {
        switch mode {
        case .replaceCurrent:
            let count = store.currentCourses.count
            return count == 0
                ? "当前课表为空，导入结果会直接写入。"
                : "当前课表的 \(count) 条课程会被清空后写入导入结果。"
        case .newTable:
            return "会新建一张课表，当前课表保持不变。"
        case .appendToCurrent:
            return "课程会追加到当前课表「\(store.selectedTable?.name ?? "课表")」。"
        }
    }
}
