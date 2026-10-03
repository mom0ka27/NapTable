import SwiftUI
import UniformTypeIdentifiers

/// The Settings tab.
///
/// The version and entitlements on top, then the settings groups: 外观 / 桌面与锁屏 / 课表 / 数据与关于.
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
    @ObservedObject private var cloudSync = ICloudSyncService.shared
    @ObservedObject private var purchases = PurchaseManager.shared
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
                subscriptionGroup
                helpGroup
                appearanceGroup
                NativeDeviceSettingsContent(
                    scheduleStore: scheduleStore,
                    widgetSettings: widgetSettings
                )
                tablesGroup
                dataGroup
            }
            .appListBackground()
            .navigationTitle("设置")
            .appSoftTopScrollEdge()
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
        #if os(macOS)
        .onAppear { cloudSync.usesSettingsReviewHost = true }
        .onDisappear { cloudSync.usesSettingsReviewHost = false }
        .sheet(isPresented: Binding(
            get: { cloudSync.usesSettingsReviewHost && cloudSync.isReviewPresented },
            set: { if !$0 { cloudSync.deferReview() } }
        )) {
            NavigationStack { ICloudSyncReviewView() }.environmentObject(store)
        }
        #endif
    }

    // MARK: Top-level groups

    private var subscriptionGroup: some View {
        Section {
            SettingsDestinationRow(
                title: purchases.versionTitle,
                detail: purchases.versionDetail,
                systemImage: purchases.versionSystemImage
            ) {
                SubscriptionView()
            }
        } header: {
            Text("版本与权益")
        }
    }

    private var helpGroup: some View {
        Section {
            SettingsDestinationRow(
                title: "使用指南",
                detail: "添加、编辑桌面小组件与修改课程",
                systemImage: "questionmark.circle"
            ) {
                ScheduleUsageGuideScreen()
            }
        } header: {
            Text("帮助")
        }
    }

    private var appearanceGroup: some View {
        Section {
            SettingsDestinationRow(
                title: "主题与外观",
                detail: "\(themeSettings.theme.title) · \(store.settings.appearance.title)",
                systemImage: "paintpalette"
            ) {
                Form { GlobalThemeSettingsSection() }
                    .appListBackground()
                    .navigationTitle("主题与外观")
                    .appInlineNavigationTitle()
                    .appSoftTopScrollEdge()
            }

            SettingsDestinationRow(
                title: "课表显示",
                detail: "默认视图、卡片密度与节次",
                systemImage: "calendar"
            ) {
                ScheduleDisplaySettingsScreen()
                    .navigationTitle("课表显示")
                    .appInlineNavigationTitle()
                    .appSoftTopScrollEdge()
            }

            SettingsDestinationRow(
                title: "背景图片",
                detail: backgroundSummary,
                systemImage: "photo.on.rectangle"
            ) {
                ScheduleBackgroundSettingsScreen()
                    .navigationTitle("背景图片")
                    .appInlineNavigationTitle()
                    .appSoftTopScrollEdge()
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
        guard schedulePreferences.backgroundEnabled else { return "已隐藏" }
        let percent = { (value: Double) in "\(Int((value * 100).rounded()))%" }
        return (light && dark ? "浅色、深色各一张" : "两种模式共用一张")
            + " · 浅色 \(percent(schedulePreferences.backgroundOpacity))"
            + " · 深色 \(percent(schedulePreferences.backgroundOpacityDark))"
    }

    private var tablesGroup: some View {
        Section {
            SettingsDestinationRow(
                title: "编辑课表",
                detail: "课程、上课周次与节次",
                systemImage: "square.and.pencil"
            ) {
                ScheduleEditingView(tableID: store.selectedTableId)
            }
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
            Text("学期、周次与节次时间按课表分别设置，请在「我的课表」中修改。")
        }
    }

    private var dataGroup: some View {
        Section {
            SettingsDestinationRow(
                title: "iCloud 同步",
                detail: cloudSync.statusText,
                systemImage: "icloud"
            ) {
                ICloudSyncSettingsView()
            }
            SettingsDestinationRow(
                title: "隐私与数据",
                detail: privacyConsent.liveAccepted ? "已允许上传实时通知信息" : "仅上传基础统计",
                systemImage: "hand.raised"
            ) {
                PrivacySettingsView()
            }
            SettingsDestinationRow(
                title: "数据与备份",
                detail: "\(store.courses.count) 门课程 · \(cloudSync.isEnabled ? "已开启 iCloud 同步" : "本机备份")",
                systemImage: "externaldrive"
            ) {
                Form { dataSection }
                    .appListBackground()
                    .navigationTitle("数据与备份")
                    .appInlineNavigationTitle()
                    .appSoftTopScrollEdge()
            }

            SettingsDestinationRow(
                title: "关于",
                detail: "用户 QQ 群、版本信息与开源鸣谢",
                systemImage: "info.circle"
            ) {
                AboutView(
                    tableCount: store.tables.count,
                    courseCount: store.courses.count,
                    dailyPeriodCount: store.classTimeList.count
                )
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
                Label("暂无课表，请从学校导入", systemImage: "calendar")
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
            Text("进入课表可设置学期、周次与节次时间，也可切换、重命名或删除课表。")
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
            Text("恢复备份将追加课表，并覆盖当前的显示设置。")
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
                Text(cloudSync.isEnabled
                     ? "所有自己的课表与课程都将被删除，并同步删除 iCloud 和其他设备上的对应课表。建议先导出备份。"
                     : "所有课表与课程都将被删除，此操作无法撤销。")
            }
        } header: {
            Text("清除")
        } footer: {
            Text("此操作无法撤销，建议先导出备份。如需清空单张课表的课程，请在该课表中操作。")
        }
    }

    // MARK: Helpers

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
                case .failure: message = "导出失败，请稍后重试。"
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
                        message = "恢复失败，请确认备份文件完整后重试。"
                    }
                case .failure:
                    message = "恢复失败，请确认备份文件完整后重试。"
                }
            }
            .alert("提示", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("确定") { message = nil }
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
