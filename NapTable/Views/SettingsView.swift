import SwiftUI
import UniformTypeIdentifiers

/// 按使用场景组织设置：课表、显示与外观、桌面与锁屏、同步与数据、帮助与关于。
/// 当前课表提供直达入口；学期、周次和节次时间仍由各张课表分别保存。
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var themeSettings = NativeThemeSettings.shared
    @ObservedObject private var schedulePreferences = NativeSchedulePreferences.shared
    @ObservedObject private var sharingService = ScheduleSharingService.shared
    @ObservedObject private var privacyConsent = PrivacyConsent.shared
    @ObservedObject private var cloudSync = ICloudSyncService.shared
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
    @State private var showSubscription = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showSubscription = true
                    } label: {
                        SubscriptionSettingsCard()
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityHint("查看专业版专属功能、试用状态和购买选项")
                }
                tablesGroup
                appearanceGroup
                NativeDeviceSettingsContent(
                    scheduleStore: scheduleStore,
                    widgetSettings: widgetSettings
                )
                dataGroup
                supportGroup
            }
            .appListBackground()
            .navigationTitle("设置")
            .navigationDestination(isPresented: $showSubscription) { SubscriptionView() }
            .appSoftTopScrollEdge()
            #if os(iOS)
            .listStyle(.insetGrouped)
            .listSectionSpacing(20)
            .navigationBarTitleDisplayMode(.large)
            #endif
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

    private var tablesGroup: some View {
        Section {
            if let shared = scheduleStore.viewedSharedSchedule {
                NavigationLink {
                    SharedScheduleInfoView(code: shared.meta.code)
                } label: {
                    currentScheduleLabel(shared.name)
                }
                .accessibilityHint("查看这张共享课表的信息，只读")
            } else if !scheduleStore.isReadOnly, let table = store.selectedTable {
                NavigationLink {
                    CourseTableSettingsView(tableId: table.id)
                } label: {
                    currentScheduleLabel(table.name)
                }
                .accessibilityHint("设置这张课表的学期、周次与上课时间")
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
        }
    }

    private func currentScheduleLabel(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前课表")
                .font(.caption.weight(.semibold))
                .foregroundStyle(themeSettings.brandColor)
            Text(name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    private var appearanceGroup: some View {
        Section {
            SettingsDestinationRow(
                title: "课表显示",
                detail: displaySummary,
                systemImage: "rectangle.split.3x3",
                tint: themeSettings.brandColor
            ) {
                ScheduleDisplaySettingsScreen()
                    .navigationTitle("课表显示")
                    .appInlineNavigationTitle()
                    .appSoftTopScrollEdge()
            }

            SettingsDestinationRow(
                title: "主题与外观",
                detail: "\(themeSettings.theme.title) · \(store.settings.appearance.title)",
                systemImage: "paintpalette",
                tint: themeSettings.brandColor
            ) {
                Form { GlobalThemeSettingsSection() }
                    .appListBackground()
                    .navigationTitle("主题与外观")
                    .appInlineNavigationTitle()
                    .appSoftTopScrollEdge()
            }

            SettingsDestinationRow(
                title: "背景图片",
                detail: backgroundSummary,
                systemImage: "photo.on.rectangle",
                tint: themeSettings.brandColor
            ) {
                ScheduleBackgroundSettingsScreen()
                    .navigationTitle("背景图片")
                    .appInlineNavigationTitle()
                    .appSoftTopScrollEdge()
            }
        } header: {
            Text("显示与外观")
        }
    }

    private var displaySummary: String {
        let view = switch schedulePreferences.defaultView {
        case "day": "日课表"
        case "month": "月历"
        default: "周课表"
        }
        let density = switch schedulePreferences.density {
        case "relaxed": "宽松"
        case "compact": "紧凑"
        default: "舒适"
        }
        return "\(view) · \(density)布局"
    }

    private var backgroundSummary: String {
        // 这一行打开的是默认背景，不看课表页此刻激活的是哪张课表。
        let profile = schedulePreferences.defaultBackgroundProfile
        let light = !profile.backgroundPath.isEmpty
        let dark = !profile.backgroundPathDark.isEmpty
        guard light || dark else { return "默认背景 · 未设置" }
        guard profile.backgroundEnabled else { return "默认背景 · 已隐藏" }
        return light && dark ? "默认背景 · 浅色、深色各一张" : "默认背景 · 浅色、深色共用"
    }

    private var dataGroup: some View {
        Section {
            SettingsDestinationRow(
                title: "iCloud 同步",
                detail: cloudSync.statusText,
                systemImage: "icloud",
                tint: .blue
            ) {
                ICloudSyncSettingsView()
            }
            SettingsDestinationRow(
                title: "数据与备份",
                detail: "导出备份、恢复与清除数据",
                systemImage: "externaldrive",
                tint: .blue
            ) {
                Form { dataSection }
                    .appListBackground()
                    .navigationTitle("数据与备份")
                    .appInlineNavigationTitle()
                    .appSoftTopScrollEdge()
            }
            SettingsDestinationRow(
                title: "隐私与数据",
                detail: privacyConsent.liveAccepted ? "已允许上传实时通知信息" : "仅上传基础统计",
                systemImage: "hand.raised",
                tint: .blue
            ) {
                PrivacySettingsView()
            }
        } header: {
            Text("同步与数据")
        }
    }

    private var supportGroup: some View {
        Section {
            SettingsDestinationRow(
                title: "使用指南",
                detail: "课程编辑、小组件与常见操作",
                systemImage: "questionmark.circle",
                tint: .secondary
            ) {
                ScheduleUsageGuideScreen()
            }

            SettingsDestinationRow(
                title: "更新与通知",
                detail: "查看新版本与重要消息",
                systemImage: "bell.badge",
                tint: .secondary
            ) {
                AnnouncementCenterView()
            }

            SettingsDestinationRow(
                title: "关于",
                detail: "用户 QQ 群、版本信息与开源鸣谢",
                systemImage: "info.circle",
                tint: .secondary
            ) {
                AboutView(
                    tableCount: store.tables.count,
                    courseCount: Set(store.courses.compactMap(\.courseKey)).count,
                    dailyPeriodCount: store.classTimeList.count
                )
            }
        } header: {
            Text("帮助与关于")
        }
    }

    // MARK: 我的课表

    private var tablesSummary: String {
        if store.tables.isEmpty && sharingService.sharedSchedules.isEmpty {
            return "添加、导入与管理课表"
        }
        return "自己的 \(store.tables.count) 张 · 共享 \(sharingService.sharedSchedules.count) 张"
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
        Set(store.courses.filter { $0.tableId == tableId }.map(\.name)).count
    }

    private func tableRowSummary(_ table: CourseTable) -> String {
        var parts = ["\(courseCount(table.id)) 门课程"]
        if let school = table.schoolID, table.termID != nil { parts.append(school) }
        let week = store.liveWeek(of: table)
        if week > 0 { parts.append("第 \(week) 周") }
        return parts.joined(separator: " · ")
    }
}

/// 共享课表的信息由分享者维护，不提供本地课表的编辑入口。
private struct SharedScheduleInfoView: View {
    @ObservedObject private var service = ScheduleSharingService.shared
    let code: String

    private var schedule: FollowedSchedule? {
        service.sharedSchedules.first { $0.meta.code == code }
    }

    var body: some View {
        Group {
            if let schedule {
                Form {
                    Section {
                        LabeledContent("名称", value: schedule.name)
                        LabeledContent("类型", value: "共享课表 · 只读")
                        if let owner = schedule.meta.ownerName {
                            LabeledContent("分享者", value: owner)
                        }
                        LabeledContent("学校", value: schedule.meta.schoolName)
                        LabeledContent("课程", value: "\(Set(schedule.courses.map(\.name)).count) 门")
                        if schedule.isRevoked {
                            Label("分享已撤销，不会再更新", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("课程、学期与上课时间由分享者维护。")
                    }
                    Section("学期") {
                        LabeledContent("学期", value: schedule.meta.termID)
                        LabeledContent("第一周的星期一", value: schedule.meta.semesterStartMonday)
                        LabeledContent("学期总周数", value: "\(schedule.meta.weekCount) 周")
                    }
                }
                .appListBackground()
            } else {
                ContentUnavailableView("这张共享课表已移除", systemImage: "calendar.badge.minus")
            }
        }
        .navigationTitle(schedule?.name ?? "共享课表")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
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
