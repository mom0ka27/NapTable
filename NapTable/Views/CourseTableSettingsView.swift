import SwiftUI

/// 一张课表自己的设置：学期、周次、节次时间、调休。
///
/// 这些都是学校给的，不同学校、不同学期各不相同，存在 `CourseTable` 上而不是全局
/// 设置里。所以入口放在「我的课表」里每张课表下面，改的就是那一张，不会误改到别的课表。
struct CourseTableSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let tableId: Int

    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmClear = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let table {
                content(table)
            } else {
                ContentUnavailableView("这张课表已删除", systemImage: "calendar.badge.minus")
            }
        }
        .navigationTitle(table?.name ?? "课表")
        .appInlineNavigationTitle()
        // 挂在 Form 外面：挂在里面时，输入框会沿用表单行「标题在左、内容在右」的排版，
        // 在弹窗里整个往右偏。
        .alert("重命名课表", isPresented: $renaming) {
            TextField("", text: $renameText, prompt: Text("课表名称"))
                .labelsHidden()
                .multilineTextAlignment(.leading)
            Button("取消", role: .cancel) {}
            Button("保存") { store.renameTable(tableId, to: renameText) }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || store.isTableNameTaken(renameText, except: tableId))
        } message: {
            Text("课表名称不能和其他课表重复。")
        }
    }

    private var table: CourseTable? {
        store.tables.first { $0.id == tableId }
    }

    private func content(_ table: CourseTable) -> some View {
        Form {
            overviewSection(table)
            semesterSection(table)
            scheduleSection(table)
            dangerSection(table)
        }
        .confirmationDialog("清空「\(table.name)」的课程？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空课程", role: .destructive) { store.deleteAllCourses(inTable: tableId) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("课表和它的学期、节次设置保留，里面的课程全部删除，无法撤销。")
        }
        .confirmationDialog("删除课表「\(table.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除课表及其课程", role: .destructive) {
                dismiss()
                store.deleteTable(tableId)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这张课表里的课程会一起删掉，无法撤销。")
        }
    }

    // MARK: 概览

    private func overviewSection(_ table: CourseTable) -> some View {
        Section {
            Button {
                renameText = table.name
                renaming = true
            } label: {
                // 和只读的行区分开：名字用强调色，后面跟一支笔，一看就知道能点。
                HStack(spacing: 8) {
                    Text("名称").foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Text(table.name)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("名称，\(table.name)")
            .accessibilityHint("重命名这张课表")

            LabeledContent("课程", value: "\(courseCount) 门")

            if table.id == store.selectedTableId {
                // 右边不能放 `Label`：表单会把它当成多个子视图拆开排，状态下面凭空多出一块空行。
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("正在使用")
                    }
                    .foregroundStyle(Color.accentColor)
                }
            } else {
                Button("切换到这张课表") { store.selectTable(tableId) }
            }
        }
    }

    // MARK: 学期与周次

    private func isServerManaged(_ table: CourseTable) -> Bool { table.termID != nil }

    private func semesterSection(_ table: CourseTable) -> some View {
        Section {
            if let school = table.schoolID, isServerManaged(table) {
                LabeledContent("学校", value: school)
                if let term = table.termID { LabeledContent("学期", value: term) }
            }

            LabeledContent("当前周次") {
                let week = store.liveWeek(of: table)
                Text(week > 0 ? "第 \(week) 周" : "不在学期内")
            }

            if isServerManaged(table) {
                LabeledContent("第一周的星期一", value: store.semesterStartMondayDisplay(of: table))
                LabeledContent("学期总周数", value: "\(store.weekCount(of: table)) 周")
            } else {
                DatePicker(
                    "第一周的星期一",
                    selection: Binding(
                        get: {
                            WeekCalculator.parseDay(store.effectiveSemesterStartMonday(of: table))
                                ?? WeekCalculator.monday(of: Date())
                        },
                        set: { value in
                            store.updateSemesterStart(
                                WeekCalculator.format(WeekCalculator.monday(of: value)),
                                tableId: tableId
                            )
                        }
                    ),
                    displayedComponents: .date
                )
                Stepper(
                    "学期总周数：\(store.weekCount(of: table)) 周",
                    value: Binding(
                        get: { store.weekCount(of: table) },
                        set: { store.updateWeekCount($0, tableId: tableId) }
                    ),
                    in: 1...40
                )
                if !table.semesterStartMonday.isEmpty {
                    Button("清除开学日期", role: .destructive) {
                        store.updateSemesterStart("", tableId: tableId)
                    }
                }
            }
        } header: {
            Text("学期与周次")
        } footer: {
            if isServerManaged(table) {
                Text("由学校的学期配置提供，不用自己填。")
            } else if table.semesterStartMonday.isEmpty, BundledConfig.fallbackSemesterStartMonday != nil {
                Text("还没填，暂时按内置校历（\(store.semesterStartMondayDisplay(of: table))）算。对不上就改掉。")
            } else {
                Text("填开学那周的星期一，周次会自动往后推。只影响这张课表。")
            }
        }
    }

    // MARK: 节次、调休、收起的课

    private func scheduleSection(_ table: CourseTable) -> some View {
        Section {
            SettingsDestinationRow(
                title: "节次时间",
                detail: periodSummary(table),
                systemImage: "clock"
            ) {
                ClassTimesEditor(tableId: tableId)
            }

            if let adjustments = table.calendarAdjustments, !adjustments.isEmpty {
                SettingsDestinationRow(
                    title: "调休安排",
                    detail: "\(adjustments.count) 天 · 学校下发",
                    systemImage: "arrow.triangle.swap"
                ) {
                    CalendarAdjustmentsList(tableId: tableId)
                }
            }

            let hidden = store.hiddenCourses(inTable: tableId)
            if !hidden.isEmpty {
                SettingsDestinationRow(
                    title: "收起的课程",
                    detail: "导入时让位的 \(hidden.count) 门课，可恢复",
                    systemImage: "eye.slash"
                ) {
                    HiddenCoursesView(tableId: tableId)
                }
            }
        } header: {
            Text("作息")
        }
    }

    private func periodSummary(_ table: CourseTable) -> String {
        let list = table.effectiveClassTimeList
        var parts = ["每天 \(list.count) 节"]
        if let first = list.first?.start, let last = list.last?.end { parts.append("\(first)–\(last)") }
        if isServerManaged(table) {
            parts.append("学校提供")
        } else if table.classTimeList.isEmpty {
            parts.append("默认")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 清除

    private func dangerSection(_ table: CourseTable) -> some View {
        Section {
            Button(role: .destructive) { confirmClear = true } label: {
                Label("清空这张课表的课程", systemImage: "eraser")
            }
            .disabled(courseCount == 0)
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("删除这张课表", systemImage: "trash")
            }
        }
    }

    private var courseCount: Int {
        store.courses.filter { $0.tableId == tableId }.count
    }
}

// MARK: - 节次时间

/// 一张课表每节课的起止时间。学校配置下发的只读，自己导入的可以改。
private struct ClassTimesEditor: View {
    @EnvironmentObject private var store: AppStore
    let tableId: Int

    private var table: CourseTable? { store.tables.first { $0.id == tableId } }
    private var list: [ClassTime] { table?.effectiveClassTimeList ?? SchoolDefaults.classTimeList }
    private var isServerManaged: Bool { table?.termID != nil }

    var body: some View {
        Form {
            Section {
                ForEach(Array(list.enumerated()), id: \.offset) { index, time in
                    HStack(spacing: 10) {
                        Text("第 \(index + 1) 节")
                            .frame(width: 66, alignment: .leading)
                        if isServerManaged {
                            Text(time.start).frame(maxWidth: 80)
                        } else {
                            TextField("08:00", text: timeBinding(index, \.start))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 80)
                        }
                        Text("–").foregroundStyle(.secondary)
                        if isServerManaged {
                            Text(time.end).frame(maxWidth: 80)
                        } else {
                            TextField("08:50", text: timeBinding(index, \.end))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 80)
                        }
                    }
                    .font(.subheadline.monospacedDigit())
                }
                .onDelete { offsets in
                    guard !isServerManaged else { return }
                    var list = list
                    list.remove(atOffsets: offsets)
                    store.updateClassTimeList(list, tableId: tableId)
                }

                if !isServerManaged {
                    Button {
                        var list = list
                        let last = list.last ?? ClassTime(start: "08:00", end: "08:50")
                        list.append(ClassTime(start: last.end, end: last.end))
                        store.updateClassTimeList(list, tableId: tableId)
                    } label: {
                        Label("加一节", systemImage: "plus")
                    }
                    if !(table?.classTimeList.isEmpty ?? true) {
                        Button("恢复默认节次时间", role: .destructive) {
                            store.updateClassTimeList([], tableId: tableId)
                        }
                    }
                }
            } header: {
                Text("每节课的起止时间")
            } footer: {
                if isServerManaged {
                    Text("由学校的学期配置提供，改不了。")
                } else {
                    Text("24 小时制，如 08:00。左滑可删。只影响「\(table?.name ?? "这张课表")」。")
                }
            }
        }
        .navigationTitle("节次时间")
        .appInlineNavigationTitle()
    }

    private func timeBinding(_ index: Int, _ keyPath: WritableKeyPath<ClassTime, String>) -> Binding<String> {
        Binding(
            get: { list.indices.contains(index) ? list[index][keyPath: keyPath] : "" },
            set: { value in
                var list = list
                guard list.indices.contains(index) else { return }
                list[index][keyPath: keyPath] = value
                store.updateClassTimeList(list, tableId: tableId)
            }
        )
    }
}

// MARK: - 调休

private struct CalendarAdjustmentsList: View {
    @EnvironmentObject private var store: AppStore
    let tableId: Int

    var body: some View {
        Form {
            if let table = store.tables.first(where: { $0.id == tableId }) {
                let index = table.calendarAdjustmentIndex(anchor: store.effectiveSemesterStartMonday(of: table))
                Section {
                    ForEach(table.calendarAdjustments ?? []) { item in
                        LabeledContent(item.date, value: index[item.date]?.detail ?? item.note)
                    }
                } footer: {
                    Text("由学校配置下发，课表、月历、小组件和灵动岛都会按这些日期覆盖课程。")
                }
            }
        }
        .navigationTitle("调休安排")
        .appInlineNavigationTitle()
    }
}
