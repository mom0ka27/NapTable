import SwiftUI

/// 一张课表自己的设置：学期、周次、节次时间、调休。
///
/// 不同学校、不同学期各不相同，存在 `CourseTable` 上而不是全局
/// 设置里。所以入口放在「我的课表」里每张课表下面，改的就是那一张，不会误改到别的课表。
struct CourseTableSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var purchases = PurchaseManager.shared
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
        .appSoftTopScrollEdge()
        .alert("重命名课表", isPresented: $renaming) {
            TextField("", text: $renameText, prompt: Text("课表名称"))
                .labelsHidden()
                .multilineTextAlignment(.leading)
            Button("取消", role: .cancel) {}
            Button("保存") { store.renameTable(tableId, to: renameText) }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || store.isTableNameTaken(renameText, except: tableId))
        } message: {
            Text("课表名称不能与其他课表重复。")
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
        .appListBackground()
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

            SettingsDestinationRow(
                title: "编辑课表",
                detail: "课程、上课周次与节次",
                systemImage: "square.and.pencil"
            ) {
                ScheduleEditingView(tableID: tableId)
            }

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
                Text("由学校的学期配置提供，无需手动设置。")
            } else if table.semesterStartMonday.isEmpty, BundledConfig.fallbackSemesterStartMonday != nil {
                Text("尚未设置，暂按内置校历（\(store.semesterStartMondayDisplay(of: table))）计算。如有出入，请手动修改。")
            } else {
                Text("请填写开学第一周的星期一，之后的周次将自动推算。仅对本课表生效。")
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

            SettingsDestinationRow(
                title: "背景图片",
                detail: purchases.allowsPerTableBackgrounds
                    ? "浅色与深色模式可分别设置"
                    : "专业版功能",
                systemImage: "photo.on.rectangle"
            ) {
                ScheduleBackgroundSettingsScreen(tableId: tableId)
                    .navigationTitle("背景图片")
                    .appInlineNavigationTitle()
                    .appSoftTopScrollEdge()
            }

            Toggle(isOn: Binding(
                get: { table.unifiedHolidaysEnabled != false },
                set: { store.setUnifiedHolidaysEnabled($0, tableId: tableId) }
            )) {
                Label("统一放假", systemImage: "calendar.badge.clock")
            }

            Toggle(isOn: Binding(
                get: { table.unifiedMakeupEnabled != false },
                set: { store.setUnifiedMakeupEnabled($0, tableId: tableId) }
            )) {
                Label("统一调休补班", systemImage: "arrow.triangle.swap")
            }

            let adjustments = store.calendarAdjustments(of: table)
            if !adjustments.isEmpty {
                SettingsDestinationRow(
                    title: "调休安排",
                    detail: "\(adjustments.count) 天 · 服务端下发",
                    systemImage: "arrow.triangle.swap"
                ) {
                    CalendarAdjustmentsList(tableId: tableId)
                }
            }

            let hidden = store.hiddenCourses(inTable: tableId)
            if !hidden.isEmpty {
                SettingsDestinationRow(
                    title: "收起的课程",
                    detail: "\(hidden.count) 条上课安排，可恢复",
                    systemImage: "eye.slash"
                ) {
                    HiddenCoursesView(tableId: tableId)
                }
            }
        } header: {
            Text("作息")
        } footer: {
            Text(scheduleAdjustmentFooter(table))
        }
    }

    private func scheduleAdjustmentFooter(_ table: CourseTable) -> String {
        let holidays = table.unifiedHolidaysEnabled != false
        let makeup = table.unifiedMakeupEnabled != false
        switch (holidays, makeup) {
        case (true, true): return "按统一安排调整课程：放假日停课，补班日上调休来源日的课。"
        case (true, false): return "只按统一放假安排停课，补班日按普通星期几显示。"
        case (false, true): return "只按统一调休安排补班，放假日按普通星期几显示。"
        case (false, false): return "已关闭统一放假和统一调休，课表每天按普通星期几显示。"
        }
    }

    private func periodSummary(_ table: CourseTable) -> String {
        let list = table.classTimes(on: WeekCalculator.format(Date()))
        var parts = ["每天 \(list.count) 节"]
        if let first = list.first?.start, let last = list.last?.end { parts.append("\(first)–\(last)") }
        if table.usesCustomClassTimes == true {
            parts.append("自定义")
        } else if isServerManaged(table) {
            parts.append("学校提供")
        } else if table.classTimeList.isEmpty {
            parts.append("默认")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 清除

    private func dangerSection(_ table: CourseTable) -> some View {
        Section {
            // 确认框分别挂在各自的按钮上：iOS 26 起它从触发的视图旁边弹出，
            // 挂在整个 Form 上会飘到不相干的位置。
            Button(role: .destructive) { confirmClear = true } label: {
                Label("清空这张课表的课程", systemImage: "eraser")
            }
            .disabled(courseCount == 0)
            .confirmationDialog("清空「\(table.name)」的课程？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空课程", role: .destructive) { store.deleteAllCourses(inTable: tableId) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("课表及其学期、节次设置将保留，其中的课程将全部删除，此操作无法撤销。")
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("删除这张课表", systemImage: "trash")
            }
            .confirmationDialog("删除课表「\(table.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除课表及其课程", role: .destructive) {
                    dismiss()
                    store.deleteTable(tableId)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(ICloudSyncService.shared.isEnabled
                     ? "课表中的课程将一并删除，并同步删除 iCloud 和其他设备上的对应课表。"
                     : "课表中的课程将一并删除，此操作无法撤销。")
            }
        }
    }

    private var courseCount: Int {
        Set(store.courses.filter { $0.tableId == tableId }.map(\.name)).count
    }
}

// MARK: - 节次时间

/// 开关与多套作息都先编辑草稿，通过校验后一次保存。
private struct ClassTimesEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let tableId: Int
    @State private var usesCustom = false
    @State private var list: [ClassTime] = []
    @State private var seasons: [SeasonalClassTimes] = []
    @State private var loaded = false
    @State private var saveError: String?

    private var table: CourseTable? { store.tables.first { $0.id == tableId } }
    private var requiredPeriods: Int {
        store.courses.filter { $0.tableId == tableId && !$0.isFreeTime }.map(\.endTime).max() ?? 1
    }
    private var problem: String? {
        usesCustom ? ClassTimeValidator.problem(base: list, seasons: seasons, requiredPeriods: requiredPeriods) : nil
    }

    var body: some View {
        Form {
            Section {
                Toggle("使用自定义节次时间", isOn: $usesCustom)
            } footer: {
                Text("关闭后使用学校下发或原有的作息，自定义配置会保留。修改后点保存，仅对这张课表生效。")
            }
            if usesCustom {
                Section {
                    ClassTimeRows(list: $list, requiredPeriods: requiredPeriods)
                } header: {
                    Text("基础作息")
                } footer: {
                    Text("采用 24 小时制，如 08:00。没有设置按日期切换的作息时，全年使用这份时间。")
                }
                ForEach(seasons.indices, id: \.self) { index in
                    Section {
                        TextField("生效日期（月-日）", text: $seasons[index].from, prompt: Text("05-01"))
                            .accessibilityHint("每年的生效日期，例如 05-01")
                        ClassTimeRows(list: $seasons[index].periods, requiredPeriods: requiredPeriods)
                        Button("删除这套作息", role: .destructive) { seasons.remove(at: index) }
                    } header: {
                        Text("日期作息 \(index + 1) · 每年 \(seasons[index].from) 起")
                    }
                }
                Section {
                    Button {
                        let date = nextSeasonDate
                        seasons.append(SeasonalClassTimes(from: date, periods: list))
                    } label: {
                        Label("添加按日期切换的作息", systemImage: "calendar.badge.plus")
                    }
                    .disabled(seasons.count >= ClassTimeValidator.maxSeasonalSchedules)
                } footer: {
                    Text("例如设置 05-01 起的夏令作息、10-01 起的冬令作息。各套作息节次数量须一致，最多 4 套。配置后，每天使用最近一次生效的日期作息；年初沿用上一年最后一套，不使用基础作息。")
                }
            } else if let table {
                Section {
                    let times = table.classTimeList.isEmpty ? SchoolDefaults.classTimeList : table.classTimeList
                    ForEach(Array(times.enumerated()), id: \.offset) { index, time in
                        LabeledContent("第 \(index + 1) 节", value: "\(time.start)–\(time.end)")
                    }
                } header: { Text("学校下发或原有作息") }
                let suppliedSeasons = table.seasonalPeriods ?? SeasonalClassTimes.defaults(for: table.schoolID) ?? []
                ForEach(Array(suppliedSeasons.enumerated()), id: \.offset) { _, season in
                    Section {
                        ForEach(Array(season.periods.enumerated()), id: \.offset) { index, time in
                            LabeledContent("第 \(index + 1) 节", value: "\(time.start)–\(time.end)")
                        }
                    } header: { Text("每年 \(season.from) 起") }
                }
            }
            if let problem = saveError ?? problem {
                Section { Text(problem).foregroundStyle(.red) }
            }
        }
        .appListBackground()
        .navigationTitle("节次时间")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
        .onAppear {
            guard !loaded, let table else { return }
            usesCustom = table.usesCustomClassTimes == true
            list = table.customClassTimeList ?? table.classTimes(on: WeekCalculator.format(Date()))
            seasons = table.customSeasonalPeriods ?? table.effectiveSeasonalPeriods ?? []
            loaded = true
        }
        .onChange(of: usesCustom) { _, _ in saveError = nil }
        .onChange(of: list) { _, _ in saveError = nil }
        .onChange(of: seasons) { _, _ in saveError = nil }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    let saved = usesCustom
                        ? store.updateCustomClassTimes(list, seasons: seasons, tableId: tableId)
                        : (store.updateCustomClassTimes(list, seasons: seasons, tableId: tableId, enabled: false)
                           || store.setUsesCustomClassTimes(false, tableId: tableId))
                    if saved { dismiss() }
                    else { saveError = "无法保存，请检查作息和课程使用的节次。" }
                }
                .disabled(!loaded || problem != nil || table == nil)
            }
        }
    }

    private var nextSeasonDate: String {
        let used = Set(seasons.map(\.from))
        if !used.contains("05-01") { return "05-01" }
        if !used.contains("10-01") { return "10-01" }
        let first = WeekCalculator.parseDay("2000-01-01")!
        return (0..<366).lazy.compactMap { offset -> String? in
            guard let date = WeekCalculator.calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            let value = String(WeekCalculator.format(date).suffix(5))
            return used.contains(value) ? nil : value
        }.first ?? "01-01"
    }
}

private struct ClassTimeRows: View {
    @Binding var list: [ClassTime]
    let requiredPeriods: Int

    var body: some View {
        ForEach(Array(list.enumerated()), id: \.offset) { index, _ in
            HStack(spacing: 10) {
                Text("第 \(index + 1) 节").frame(width: 66, alignment: .leading)
                TextField("08:00", text: timeBinding(index, \.start))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 80)
                    .accessibilityLabel("第 \(index + 1) 节上课时间")
                Text("–").foregroundStyle(.secondary)
                TextField("08:50", text: timeBinding(index, \.end))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 80)
                    .accessibilityLabel("第 \(index + 1) 节下课时间")
            }
            .font(.subheadline.monospacedDigit())
        }
        Button {
            let start = min((list.last.flatMap { ClassTimeValidator.minutes($0.end) } ?? 470) + 10, 1389)
            list.append(ClassTime(start: ClassTimeValidator.format(start), end: ClassTimeValidator.format(start + 50)))
        } label: { Label("添加节次", systemImage: "plus") }
        .disabled(list.count >= ClassTimeValidator.maxCustomPeriods)
        if list.count > max(1, requiredPeriods) {
            Button("删除最后一节", role: .destructive) { list.removeLast() }
        }
    }

    private func timeBinding(_ index: Int, _ keyPath: WritableKeyPath<ClassTime, String>) -> Binding<String> {
        Binding(
            get: { list.indices.contains(index) ? list[index][keyPath: keyPath] : "" },
            set: { value in
                guard list.indices.contains(index) else { return }
                list[index][keyPath: keyPath] = value
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
                let list = store.calendarAdjustments(of: table)
                let index = CalendarAdjustmentResolver.index(list, semesterStartMonday: store.effectiveSemesterStartMonday(of: table))
                Section {
                    ForEach(list) { item in
                        LabeledContent(item.date, value: index[item.date]?.detail ?? item.note)
                    }
                } footer: {
                    Text("由服务端统一下发。课表、月历、小组件与灵动岛将按这些日期调整课程。")
                }
            }
        }
        .appListBackground()
        .navigationTitle("调休安排")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
    }
}
