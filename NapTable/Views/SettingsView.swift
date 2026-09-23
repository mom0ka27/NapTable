import SwiftUI
import UniformTypeIdentifiers

/// The Settings tab.
///
/// Five groups, two or three rows each, and never more than two levels deep:
/// 外观 / 学期与节次 / 桌面与锁屏 / 课表 / 数据与关于. Every row says what it
/// currently is, so the common case — "did I already set that?" — is answered
/// without opening it.
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var themeSettings = NativeThemeSettings.shared
    @ObservedObject private var sharingService = ScheduleSharingService.shared
    @Binding var showImport: Bool
    @ObservedObject var scheduleStore: NativeScheduleStore
    @ObservedObject var widgetSettings: NativeWidgetSettings

    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var tableBeingRenamed: CourseTable?
    @State private var renameText = ""
    @State private var confirmDeleteTable: CourseTable?
    @State private var confirmClearCourses = false
    @State private var confirmEraseAll = false
    @State private var exporting = false
    @State private var importingBackup = false
    @State private var exportDocument = BackupDocument()
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                appearanceGroup
                if store.selectedTable != nil { termGroup }
                NativeDeviceSettingsContent(
                    scheduleStore: scheduleStore,
                    widgetSettings: widgetSettings
                )
                tablesGroup
                dataGroup
            }
            .navigationTitle("设置")
            .appInlineNavigationTitle()
            #if os(macOS)
            // The Mac presents settings as a sheet, so it needs a way out. On
            // iPhone this is a tab and `dismiss()` would do nothing.
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            #endif
            .modifier(SettingsDialogs(
                store: store,
                tableBeingRenamed: $tableBeingRenamed,
                renameText: $renameText,
                confirmDeleteTable: $confirmDeleteTable,
                confirmClearCourses: $confirmClearCourses,
                confirmEraseAll: $confirmEraseAll,
                exporting: $exporting,
                importingBackup: $importingBackup,
                exportDocument: $exportDocument,
                message: $message
            ))
        }
    }

    // MARK: Top-level groups

    private var appearanceGroup: some View {
        Section {
            SettingsDestinationRow(
                title: "主题与外观",
                detail: "\(themeSettings.theme.title) · \(store.settings.appearance.title)",
                systemImage: "paintpalette"
            ) {
                Form { GlobalThemeSettingsSection() }
                    .navigationTitle("主题与外观")
                    .appInlineNavigationTitle()
            }

            SettingsDestinationRow(
                title: "课表显示",
                detail: "打开时的视图、卡片密度和背景图",
                systemImage: "calendar"
            ) {
                Form { ScheduleSettingsSection() }
                    .navigationTitle("课表显示")
                    .appInlineNavigationTitle()
            }
        } header: {
            Text("外观")
        }
    }

    private var termGroup: some View {
        Section {
            SettingsDestinationRow(
                title: "学期与周次",
                detail: weekSummary,
                systemImage: "calendar.badge.clock"
            ) {
                Form { semesterSection }
                    .navigationTitle("学期与周次")
                    .appInlineNavigationTitle()
            }

            SettingsDestinationRow(
                title: "节次时间",
                detail: "共 \(store.classTimeList.count) 节" + (isServerManaged ? "（学校提供）" : ""),
                systemImage: "clock"
            ) {
                Form { periodsSection }
                    .navigationTitle("节次时间")
                    .appInlineNavigationTitle()
            }
        } header: {
            Text("学期与节次")
        }
    }

    private var tablesGroup: some View {
        Section {
            SettingsDestinationRow(
                title: "我的课表",
                detail: "自己的 \(store.tables.count) 张 · 共享 \(sharingService.sharedSchedules.count) 张",
                systemImage: "square.stack"
            ) {
                MySchedulesView(showImport: $showImport) { tablesSection }
            }
        } header: {
            Text("课表")
        }
    }

    private var dataGroup: some View {
        Section {
            NavigationLink { PrivacySettingsView() } label: {
                Label("隐私与数据", systemImage: "hand.raised")
            }
            SettingsDestinationRow(
                title: "数据与备份",
                detail: "\(store.courses.count) 门课程 · 全部存在本机",
                systemImage: "externaldrive"
            ) {
                Form { dataSection }
                    .navigationTitle("数据与备份")
                    .appInlineNavigationTitle()
            }

            SettingsDestinationRow(
                title: "关于",
                detail: "版本信息与开源鸣谢",
                systemImage: "info.circle"
            ) {
                Form {
                    aboutSection
                    creditsSection
                }
                .navigationTitle("关于")
                .appInlineNavigationTitle()
            }
        } header: {
            Text("数据与关于")
        }
    }

    // MARK: 学期与周次

    private var isServerManaged: Bool { store.selectedTable?.termID != nil }

    private var weekSummary: String {
        store.liveWeek > 0 ? "第 \(store.liveWeek) 周 / 共 \(store.maxWeeks) 周" : "还没设置学期开始日期"
    }

    private var semesterSection: some View {
        Section {
            HStack {
                Text("当前周次")
                Spacer()
                Text(store.liveWeek > 0 ? "第 \(store.liveWeek) 周" : "—")
                    .foregroundStyle(.secondary)
            }

            if isServerManaged {
                LabeledContent("第一周的星期一", value: store.semesterStartMondayDisplay)
                LabeledContent("学期总周数", value: "\(store.maxWeeks) 周")
            } else {
                DatePicker(
                    "第一周的星期一",
                    selection: Binding(
                        get: { WeekCalculator.parseDay(store.effectiveSemesterStartMonday) ?? WeekCalculator.monday(of: Date()) },
                        set: { value in store.updateSemesterStart(WeekCalculator.format(WeekCalculator.monday(of: value))) }
                    ),
                    displayedComponents: .date
                )
                Stepper("学期总周数：\(store.settings.weekCount) 周", value: binding(\.weekCount), in: 1...40)
                if !store.semesterStartMonday.isEmpty {
                    Button("清除开学日期", role: .destructive) { store.updateSemesterStart("") }
                }
            }
        } header: {
            Text("学期")
        } footer: {
            if isServerManaged {
                Text("由学校的学期配置提供，不用自己填。")
            } else if store.semesterStartMonday.isEmpty, BundledConfig.fallbackSemesterStartMonday != nil {
                Text("还没填，暂时按内置校历（\(store.semesterStartMondayDisplay)）算。对不上就改掉。")
            } else {
                Text("填开学那周的星期一，周次会自动往后推。")
            }
        }
    }

    private var periodsSection: some View {
        Section {
            ForEach(Array(store.classTimeList.enumerated()), id: \.offset) { index, time in
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
                var list = store.classTimeList
                list.remove(atOffsets: offsets)
                store.updateClassTimeList(list)
            }

            if !isServerManaged {
                Button {
                    var list = store.classTimeList
                    let last = list.last ?? ClassTime(start: "08:00", end: "08:50")
                    list.append(ClassTime(start: last.end, end: last.end))
                    store.updateClassTimeList(list)
                } label: {
                    Label("加一节", systemImage: "plus")
                }
                if !(store.selectedTable?.classTimeList.isEmpty ?? true) {
                    Button("恢复默认节次时间", role: .destructive) { store.updateClassTimeList([]) }
                }
            }
        } header: {
            Text("每节课的起止时间")
        } footer: {
            if isServerManaged {
                Text("由学校的学期配置提供，改不了。")
            } else {
                Text("24 小时制，如 08:00。左滑可删。")
            }
        }
    }

    // MARK: 我的课表

    private var tablesSection: some View {
        Section {
            if store.tables.isEmpty {
                Label("还没有课表，从学校导入一张吧", systemImage: "calendar")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.tables) { table in
                Button {
                    store.selectTable(table.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(table.name).foregroundStyle(.primary)
                            Text("\(courseCount(table.id)) 门课程")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if table.id == store.selectedTableId {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("重命名") { renameText = table.name; tableBeingRenamed = table }
                    Button("删除", role: .destructive) { confirmDeleteTable = table }
                }
                .swipeActions(edge: .trailing) {
                    Button("删除", role: .destructive) { confirmDeleteTable = table }
                    Button("重命名") {
                        renameText = table.name
                        tableBeingRenamed = table
                    }
                }
            }
        } header: {
            Text("自己的课表")
        } footer: {
            Text("点一下切换，左滑可重命名或删除。")
        }
    }

    // MARK: 数据与备份

    @ViewBuilder
    private var dataSection: some View {
        Section {
            Button {
                showImport = true
            } label: {
                Label("导入课表", systemImage: "square.and.arrow.down")
            }
            Button {
                exportDocument = BackupDocument(data: (try? store.makeExportData()) ?? Data())
                exporting = true
            } label: {
                Label("导出备份文件", systemImage: "square.and.arrow.up")
            }
            Button {
                importingBackup = true
            } label: {
                Label("从备份文件恢复", systemImage: "tray.and.arrow.down")
            }
            if let error = store.loadErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("导入与备份")
        } footer: {
            Text("恢复备份会追加课表，并覆盖显示设置。")
        }

        Section {
            Button(role: .destructive) {
                confirmClearCourses = true
            } label: {
                Label("清空当前课表的课程", systemImage: "eraser")
            }
            Button(role: .destructive) {
                confirmEraseAll = true
            } label: {
                Label("清除全部本地数据", systemImage: "trash")
            }
        } header: {
            Text("清除")
        } footer: {
            Text("都无法撤销，清除前先导出备份。")
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("应用", value: "我上早八")
            LabeledContent("版本", value: appVersion)
            LabeledContent("课表", value: "\(store.tables.count) 张")
            LabeledContent("课程", value: "\(store.courses.count) 门")
            LabeledContent("每天节次", value: "\(store.classTimeList.count) 节")
        } header: {
            Text("应用信息")
        }
    }

    /// Credits for the two open-source projects this app stands on: the schedule
    /// surface is a port of CpuTime's iOS client, and the import parsing, school
    /// catalogue and calendar data come from 南哪课表.
    private var creditsSection: some View {
        Section {
            creditRow(
                name: "南哪课表",
                detail: "课程解析、学校配置与校历数据",
                urlString: "https://github.com/WheretoSleepinNJU/NJU-Class-Shedule-Flutter"
            )
            creditRow(
                name: "CpuTime",
                detail: "课表界面与玻璃拟态设计",
                urlString: "https://github.com/sx120609/CPU-web"
            )
        } header: {
            Text("开源鸣谢")
        }
    }

    @ViewBuilder
    private func creditRow(name: String, detail: String, urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).foregroundStyle(.primary)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    private func courseCount(_ tableId: Int) -> Int {
        store.courses.filter { $0.tableId == tableId }.count
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { value in store.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private func timeBinding(_ index: Int, _ keyPath: WritableKeyPath<ClassTime, String>) -> Binding<String> {
        Binding(
            get: {
                let list = store.classTimeList
                guard list.indices.contains(index) else { return "" }
                return list[index][keyPath: keyPath]
            },
            set: { value in
                var list = store.classTimeList
                guard list.indices.contains(index) else { return }
                list[index][keyPath: keyPath] = value
                store.updateClassTimeList(list)
            }
        )
    }
}

/// Every alert, confirmation dialog and file panel the settings screens raise.
/// Split out so `SettingsView.body` stays readable.
private struct SettingsDialogs: ViewModifier {
    let store: AppStore
    @Binding var tableBeingRenamed: CourseTable?
    @Binding var renameText: String
    @Binding var confirmDeleteTable: CourseTable?
    @Binding var confirmClearCourses: Bool
    @Binding var confirmEraseAll: Bool
    @Binding var exporting: Bool
    @Binding var importingBackup: Bool
    @Binding var exportDocument: BackupDocument
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .alert("重命名课表", isPresented: Binding(
                get: { tableBeingRenamed != nil },
                set: { if !$0 { tableBeingRenamed = nil } }
            )) {
                TextField("名称", text: $renameText)
                Button("取消", role: .cancel) { tableBeingRenamed = nil }
                Button("保存") {
                    if let table = tableBeingRenamed { store.renameTable(table.id, to: renameText) }
                    tableBeingRenamed = nil
                }
            }
            .confirmationDialog(
                "删除课表「\(confirmDeleteTable?.name ?? "")」？",
                isPresented: Binding(
                    get: { confirmDeleteTable != nil },
                    set: { if !$0 { confirmDeleteTable = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除课表及其课程", role: .destructive) {
                    if let table = confirmDeleteTable { store.deleteTable(table.id) }
                    confirmDeleteTable = nil
                }
                Button("取消", role: .cancel) { confirmDeleteTable = nil }
            } message: {
                Text("这张课表里的课程会一起删掉，无法撤销。")
            }
            .confirmationDialog(
                "清空当前课表的课程？",
                isPresented: $confirmClearCourses,
                titleVisibility: .visible
            ) {
                Button("清空课程", role: .destructive) { store.deleteAllCourses() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("课表本身保留，里面的课程全部删除，无法撤销。")
            }
            .confirmationDialog(
                "清除全部本地数据？",
                isPresented: $confirmEraseAll,
                titleVisibility: .visible
            ) {
                Button("全部清除", role: .destructive) { store.eraseEverything() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("所有课表和课程都会被删除，无法撤销。")
            }
            .fileExporter(
                isPresented: $exporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "NapTable-backup"
            ) { result in
                switch result {
                case .success: message = "备份已导出。"
                case .failure(let error): message = "导出失败：\(error.localizedDescription)"
                }
            }
            .fileImporter(
                isPresented: $importingBackup,
                allowedContentTypes: [.json]
            ) { result in
                switch result {
                case .success(let url):
                    do {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        try store.importData(data)
                        message = "已从备份恢复。"
                    } catch {
                        message = "恢复失败：\(error.localizedDescription)"
                    }
                case .failure(let error):
                    message = "恢复失败：\(error.localizedDescription)"
                }
            }
            .alert("提示", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("好") { message = nil }
            } message: {
                Text(message ?? "")
            }
    }
}

/// Wrapper so `fileExporter` can write the JSON the store produces.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
