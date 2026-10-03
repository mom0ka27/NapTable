import SwiftUI

/// School selection and import routes share one flow for first use and later additions.
struct ImportView: View {
    var requiresImport = false
    var onFinish: (() -> Void)? = nil
    @State private var importError: String?

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var scheduleStore: NativeScheduleStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    @State private var search = ""
    @State private var webSchool: SchoolConfig?
    @State private var imported: ImportedSchedule?
    @State private var semesterStart = WeekCalculator.monday(of: Date())

    /// 导航路径里代表「手动创建」的值；传给 `initialSchool` 可以直接打开手动创建向导。
    static let manualRoute = "manual"

    init(requiresImport: Bool = false, initialSchool: String? = nil, onFinish: (() -> Void)? = nil) {
        self.requiresImport = requiresImport
        self.onFinish = onFinish
        _path = State(initialValue: initialSchool.map { [$0] } ?? [])
    }

    private var schools: [String] {
        Array(Set(SchoolCatalog.all.map(\.schoolName))).sorted().filter {
            search.isEmpty || $0.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let imported {
                    List {
                        Section {
                            Label("课表已添加", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                            LabeledContent("课表", value: imported.name)
                            // 包括完整保留的重叠课程。
                            LabeledContent("课程", value: "\(imported.courses.count { !$0.isHidden }) 门")
                        }
                        if imported.termID == nil {
                            Section("学期开始日期") {
                                DatePicker("第一周星期一", selection: $semesterStart, displayedComponents: .date)
                            }
                        }

                    }
                    .appListBackground()
                } else {
                    List {
                        Section {
                            Text("选择学校，再选择适合你的导入方式。")
                                .foregroundStyle(.secondary)
                        }
                        Section("学校") {
                            ForEach(schools, id: \.self) { name in
                                NavigationLink(value: name) {
                                    Label(name, systemImage: "building.columns")
                                }
                            }
                            if schools.isEmpty {
                                Text("未找到学校，可以手动创建课表。")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Section {
                            NavigationLink(value: Self.manualRoute) {
                                Label("其他学校 / 手动创建", systemImage: "square.and.pencil")
                            }
                        } footer: {
                            Text("学校不在列表里，就自己设好学期和节次，再逐门添加课程。")
                        }
                    }
                    .appListBackground()
                    .searchable(text: $search, prompt: "搜索学校")
                }
            }
            .navigationDestination(for: String.self) { name in
                if name == Self.manualRoute { manualForm(school: nil) }
                else { routes(for: name) }
            }
            .navigationTitle(imported == nil ? "选择学校" : "导入完成")
            .appInlineNavigationTitle()
            .modifier(ImportSearchToolbar(hideSearch: imported != nil))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(imported == nil ? "取消" : "完成") {
                        if let imported, imported.termID == nil {
                            store.updateSemesterStart(WeekCalculator.format(WeekCalculator.monday(of: semesterStart)))
                        }
                        if imported != nil { onFinish?() }
                        dismiss()
                    }
                }
            }
            .alert("未能完成首次导入", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("知道了", role: .cancel) { importError = nil }
            } message: { Text(importError ?? "") }
            .sheet(item: $webSchool) { school in
                WebImporterView(school: school, initialMode: .newTable, requiresCourses: requiresImport) { schedule, mode in
                    guard !requiresImport || !schedule.courses.isEmpty else {
                        importError = "没有读取到课程，请确认学期和导入入口后重试。"
                        return
                    }
                    // 覆盖和追加沿用原课表的名字，完成页要显示实际写进去的那张。
                    var installed = schedule
                    installed.name = store.install(payload: schedule, mode: mode).name
                    semesterStart = WeekCalculator.parseDay(store.semesterStartMonday) ?? WeekCalculator.monday(of: Date())
                    path = []
                    imported = installed
                }
            }
        }
    }

    private func routes(for name: String) -> some View {
        List {
            Section("从学校系统导入") {
                ForEach(SchoolCatalog.all.filter { $0.schoolName == name && $0.hasExtractor }) { route in
                    Button {
                        webSchool = route
                    } label: {
                        Label(route.title.replacingOccurrences(of: name, with: ""), systemImage: "arrow.down.doc")
                    }
                }
            }
            Section { NavigationLink("手动创建课表") { manualForm(school: name) } }
        }
        .appListBackground()
        .navigationTitle(name)
        .appInlineNavigationTitle()
    }

    /// 学校不在列表里，或者列表里的学校想自己填：一步步设好学期、节次，再逐门加课。
    private func manualForm(school: String?) -> some View {
        ManualScheduleWizard(school: school, requiresCourses: requiresImport) {
            onFinish?()
            dismiss()
        }
    }
}

/// 移除完成页不再使用的系统搜索项，避免留下空的玻璃搜索容器。
private struct ImportSearchToolbar: ViewModifier {
    let hideSearch: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            content.toolbar(removing: hideSearch ? .search : nil)
        } else {
            content
        }
    }
}

extension SchoolConfig {
    var schoolName: String {
        ["南京大学", "中山大学", "南京林业大学", "南京审计大学", "南京工业大学", "复旦大学", "西安交通大学", "浙江大学", "东南大学", "上海交通大学", "上海科技大学", "西北农林科技大学", "中国人民大学", "清华大学", "中国科学院大学"]
            .first { title.hasPrefix($0) } ?? title
    }
}

/// The parse summary plus the destination picker. It is embedded inside whatever
/// sheet performed the import, so a successful login never has to stack a second
/// sheet on top of one that is still dismissing.
struct ImportedScheduleForm: View {
    let schedule: ImportedSchedule
    @Binding var mode: AppStore.ImportMode
    /// 用户改过的课表名称；清空就用解析出来的默认名。
    @Binding var tableName: String
    /// 名称留空时用的名字，已经避开了同名课表。
    var defaultName: String = ""
    /// 填的名称和别的课表重复，导入按钮会被禁用。
    var nameTaken = false
    /// 同一时段撞在一起的课。空数组表示这次导入没有冲突。
    var conflicts: [ImportConflictGroup] = []
    /// 每组选中优先显示的那一节：组 id -> `ImportedSchedule.courses` 下标。
    @Binding var conflictChoice: [Int: Int]
    @State private var availableModes: [AppStore.ImportMode] = []

    @EnvironmentObject private var store: AppStore

    init(
        schedule: ImportedSchedule,
        mode: Binding<AppStore.ImportMode>,
        tableName: Binding<String> = .constant(""),
        defaultName: String = "",
        nameTaken: Bool = false,
        conflicts: [ImportConflictGroup] = [],
        conflictChoice: Binding<[Int: Int]> = .constant([:])
    ) {
        self.schedule = schedule
        _mode = mode
        _tableName = tableName
        self.defaultName = defaultName
        self.nameTaken = nameTaken
        self.conflicts = conflicts
        _conflictChoice = conflictChoice
    }

    var body: some View {
        List {
            Section("解析结果") {
                Label("解析成功", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Color.accentColor)
                // 覆盖和追加都沿用当前课表的名字，只有新建课表才能起名。
                if mode == .newTable {
                    LabeledContent("课表名称") {
                        TextField("课表名称", text: $tableName, prompt: Text(defaultName.isEmpty ? schedule.name : defaultName))
                            .multilineTextAlignment(.trailing)
                    }
                    if nameTaken {
                        Label("已有同名课表，换个名称吧", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                LabeledContent("课程条数", value: "\(schedule.courses.count)")
                if let start = schedule.semesterStartMonday, !start.isEmpty {
                    LabeledContent("学期开始", value: start)
                }
                if !conflicts.isEmpty {
                    Label("\(conflicts.count) 组时间重叠，请选择优先显示", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            // 所有组必须选好优先级，但每条课程的实际安排都完整保留。
            ForEach(conflicts) { group in
                Section {
                    ForEach(group.members) { member in
                        conflictRow(group: group, member: member)
                    }
                } header: {
                    Text("优先显示 · \(group.title)")
                } footer: {
                    Text(conflictFooter(group))
                }
            }
            Section("导入到") {
                if availableModes == [.newTable] {
                    LabeledContent("导入方式", value: AppStore.ImportMode.newTable.title)
                } else {
                    ForEach(availableModes) { item in
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
                }
                if availableModes.contains(.appendToCurrent) && !canAppend {
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
        .appListBackground()
        .onAppear {
            // Keep the choices stable while installation updates the store and
            // this confirmation sheet is animating out.
            if availableModes.isEmpty {
                availableModes = store.tables.isEmpty ? [.newTable] : AppStore.ImportMode.allCases
            }
            if !availableModes.contains(mode) || (mode == .appendToCurrent && !canAppend) {
                mode = .newTable
            }
        }
    }

    private func conflictFooter(_ group: ImportConflictGroup) -> String {
        "所有课程都会完整导入并计入课表。每组都必须选择优先显示的课程，选完才能导入。剩余课程如果仍有重叠，需要继续选择，确保每个周次、节次都有明确的显示顺序。之后长按可切换编辑同一时段的全部课程。"
    }

    @ViewBuilder
    private func conflictRow(group: ImportConflictGroup, member: ImportConflictGroup.Member) -> some View {
        let picked = conflictChoice[group.id] == member.id
        Button {
            conflictChoice[group.id] = member.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(picked ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.course.name)
                        .foregroundStyle(.primary)
                    if mode == .appendToCurrent && member.course.id > 0 {
                        Text("当前课表已有").font(.caption).foregroundStyle(.secondary)
                    }
                    if picked { Text("优先显示").font(.caption).foregroundStyle(Color.accentColor) }
                    let subtitle = member.subtitle
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(member.weeksText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
