import SwiftUI
import UniformTypeIdentifiers

/// The Settings tab.
///
/// Four groups, a few rows each: 外观 / 桌面与锁屏 / 课表 / 数据与关于.
/// Every row says what it currently is, so the common case — "did I already
/// set that?" — is answered without opening it.
///
/// 学期、周次和节次时间不在这里：它们是学校给的、跟着每张课表走，所以放在
/// `CourseTableSettingsView` 里，从「我的课表」点进对应的课表修改。
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var themeSettings = NativeThemeSettings.shared
    @ObservedObject private var schedulePreferences = NativeSchedulePreferences.shared
    @ObservedObject private var sharingService = ScheduleSharingService.shared
    @ObservedObject private var privacyConsent = PrivacyConsent.shared
    @Binding var showImport: Bool
    @ObservedObject var scheduleStore: NativeScheduleStore
    @ObservedObject var widgetSettings: NativeWidgetSettings

    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var confirmEraseAll = false
    @State private var exporting = false
    @State private var importingBackup = false
    @State private var exportDocument = BackupDocument()
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                appearanceGroup
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
                detail: "打开时的视图、卡片密度和显示的节次",
                systemImage: "calendar"
            ) {
                ScheduleDisplaySettingsScreen()
                    .navigationTitle("课表显示")
                    .appInlineNavigationTitle()
            }

            SettingsDestinationRow(
                title: "背景图片",
                detail: backgroundSummary,
                systemImage: "photo.on.rectangle"
            ) {
                ScheduleBackgroundSettingsScreen()
                    .navigationTitle("背景图片")
                    .appInlineNavigationTitle()
            }
        } header: {
            Text("外观")
        }
    }

    /// 「共用一张 · 浅色 18% · 深色 28%」这样的一行摘要。
    private var backgroundSummary: String {
        let light = schedulePreferences.hasOwnBackground(dark: false)
        let dark = schedulePreferences.hasOwnBackground(dark: true)
        guard light || dark else { return "未设置" }
        let percent = { (value: Double) in "\(Int((value * 100).rounded()))%" }
        return (light && dark ? "浅色、深色各一张" : "两种模式共用一张")
            + " · 浅色 \(percent(schedulePreferences.backgroundOpacity))"
            + " · 深色 \(percent(schedulePreferences.backgroundOpacityDark))"
    }

    private var tablesGroup: some View {
        Section {
            SettingsDestinationRow(
                title: "我的课表",
                detail: tablesSummary,
                systemImage: "square.stack"
            ) {
                MySchedulesView(showImport: $showImport) { tablesSection }
            }
        } header: {
            Text("课表")
        } footer: {
            Text("学期、周次和节次时间每张课表各自设置，在「我的课表」里点进对应的课表修改。")
        }
    }

    private var dataGroup: some View {
        Section {
            SettingsDestinationRow(
                title: "隐私与数据",
                detail: privacyConsent.liveAccepted ? "已允许实时通知信息上传" : "只上传基础统计",
                systemImage: "hand.raised"
            ) {
                PrivacySettingsView()
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

    // MARK: 我的课表

    private var tablesSummary: String {
        let counts = "自己的 \(store.tables.count) 张 · 共享 \(sharingService.sharedSchedules.count) 张"
        guard let current = store.selectedTable else { return counts }
        return "正在使用「\(current.name)」 · " + counts
    }

    private var tablesSection: some View {
        Section {
            if store.tables.isEmpty {
                Label("还没有课表，从学校导入一张吧", systemImage: "calendar")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.tables) { table in
                NavigationLink {
                    CourseTableSettingsView(tableId: table.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(table.name).foregroundStyle(.primary)
                            Text(tableRowSummary(table))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if table.id == store.selectedTableId {
                            Text("使用中")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .contextMenu {
                    if table.id != store.selectedTableId {
                        Button("切换到这张课表") { store.selectTable(table.id) }
                    }
                }
            }
        } header: {
            Text("自己的课表")
        } footer: {
            Text("点进去设置学期、周次和节次时间，也可以在里面切换、重命名或删除这张课表。")
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
                confirmEraseAll = true
            } label: {
                Label("清除全部本地数据", systemImage: "trash")
            }
            // 挂在按钮上：iOS 26 起确认框从触发它的视图旁边弹出。
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
        } header: {
            Text("清除")
        } footer: {
            Text("无法撤销，清除前先导出备份。清空某张课表的课程，到那张课表里操作。")
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

    private func tableRowSummary(_ table: CourseTable) -> String {
        var parts = ["\(courseCount(table.id)) 门课程"]
        if let school = table.schoolID, table.termID != nil { parts.append(school) }
        let week = store.liveWeek(of: table)
        if week > 0 { parts.append("第 \(week) 周") }
        return parts.joined(separator: " · ")
    }
}

/// Every alert, confirmation dialog and file panel the settings screens raise.
/// Split out so `SettingsView.body` stays readable.
private struct SettingsDialogs: ViewModifier {
    let store: AppStore
    @Binding var exporting: Bool
    @Binding var importingBackup: Bool
    @Binding var exportDocument: BackupDocument
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
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
