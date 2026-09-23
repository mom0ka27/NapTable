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
    @State private var tableName = ""
    @State private var semesterStart = WeekCalculator.monday(of: Date())

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
                            LabeledContent("课程", value: "\(imported.courses.count) 门")
                        }
                        if imported.termID == nil {
                            Section("学期开始日期") {
                                DatePicker("第一周星期一", selection: $semesterStart, displayedComponents: .date)
                            }
                        }

                    }
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
                                Text(requiresImport ? "未找到学校，请修改搜索条件。" : "未找到学校，可以手动创建课表。")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !requiresImport {
                            Section { NavigationLink("其他学校 / 手动创建", value: "manual") }
                        }
                    }
                    .searchable(text: $search, prompt: "搜索学校")
                }
            }
            .navigationDestination(for: String.self) { name in
                if name == "manual" { manualForm(school: nil) }
                else { routes(for: name) }
            }
            .navigationTitle(imported == nil ? "选择学校" : "导入完成")
            .appInlineNavigationTitle()
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
                    store.install(payload: schedule, mode: mode)
                    semesterStart = WeekCalculator.parseDay(store.semesterStartMonday) ?? WeekCalculator.monday(of: Date())
                    path = []
                    imported = schedule
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
            if !requiresImport {
                Section { NavigationLink("手动创建课表") { manualForm(school: name) } }
            }
        }
        .navigationTitle(name)
        .appInlineNavigationTitle()
    }

    private func manualForm(school: String?) -> some View {
        Form {
            Section("课表信息") {
                TextField("课表名称", text: $tableName)
                DatePicker("第一周星期一", selection: $semesterStart, displayedComponents: .date)
            }
            Section {
                Button("创建课表") {
                    store.addTable(name: tableName, semesterStartMonday: WeekCalculator.format(WeekCalculator.monday(of: semesterStart)))
                    dismiss()
                }
                .disabled(tableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text("创建后，长按课表空白处添加课程。")
            }
        }
        .navigationTitle("手动创建")
        .appInlineNavigationTitle()
        .onAppear {
            if tableName.isEmpty { tableName = school.map { "\($0)课表" } ?? "我的课表" }
        }
    }
}

extension SchoolConfig {
    var schoolName: String {
        ["南京大学", "东南大学", "上海交通大学", "西北农林科技大学", "中国人民大学", "清华大学", "中国科学院大学"]
            .first { title.hasPrefix($0) } ?? title
    }
}

/// The parse summary plus the destination picker. It is embedded inside whatever
/// sheet performed the import, so a successful login never has to stack a second
/// sheet on top of one that is still dismissing.
struct ImportedScheduleForm: View {
    let schedule: ImportedSchedule
    @Binding var mode: AppStore.ImportMode
    @State private var availableModes: [AppStore.ImportMode] = []

    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            Section("解析结果") {
                Label("解析成功", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Color.accentColor)
                LabeledContent("课表名称", value: schedule.name)
                LabeledContent("课程条数", value: "\(schedule.courses.count)")
                if let start = schedule.semesterStartMonday, !start.isEmpty {
                    LabeledContent("学期开始", value: start)
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
