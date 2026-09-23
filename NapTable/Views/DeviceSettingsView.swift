import PhotosUI
import SwiftUI
import WidgetKit

#if os(iOS)
import ActivityKit
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The compact settings sheet reachable from the timetable header.
///
/// It is a shortcut, not a second settings tree: every row here opens the same
/// screen the Settings tab opens, so there is only one place per setting.
struct NativeDeviceSettingsView: View {
    @ObservedObject var scheduleStore: NativeScheduleStore
    @ObservedObject var widgetSettings: NativeWidgetSettings
    @ObservedObject private var themeSettings = NativeThemeSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SettingsDestinationRow(
                        title: "主题与外观",
                        detail: themeSettings.theme.title,
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

                NativeDeviceSettingsContent(
                    scheduleStore: scheduleStore,
                    widgetSettings: widgetSettings
                )
            }
            .navigationTitle("快捷设置")
            .appInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .appTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(themeSettings.brandColor)
    }
}

/// The widget / Live Activity rows, shared by the Settings tab and the header shortcut.
struct NativeDeviceSettingsContent: View {
    @ObservedObject var scheduleStore: NativeScheduleStore
    @ObservedObject var widgetSettings: NativeWidgetSettings

    @ViewBuilder
    var body: some View {
        Section {
            SettingsDestinationRow(
                title: "桌面小组件",
                detail: widgetSettings.isConfigured ? "已同步，可在桌面添加" : "还没有可显示的课表",
                systemImage: "square.grid.2x2"
            ) {
                WidgetSettingsScreen(settings: widgetSettings, store: scheduleStore)
            }
            #if os(iOS)
            SettingsDestinationRow(
                title: "实时活动",
                detail: NativeLiveActivityController.shared.isEnabled ? "已开启" : "已关闭",
                systemImage: "rectangle.topthird.inset.filled"
            ) {
                LiveActivitySettingsScreen()
            }
            #endif
        } header: {
            Text("桌面与锁屏")
        }
    }
}

/// One navigation row: icon, title, and a one-line summary of the current value.
struct SettingsDestinationRow<Destination: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.cpuBrand)
                    .frame(width: 28, height: 28)
                    .background(Color.cpuBrand.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.vertical, 3)
        }
    }
}

// MARK: - 课表显示

struct ScheduleSettingsSection: View {
    @ObservedObject private var preferences = NativeSchedulePreferences.shared

    @ViewBuilder
    var body: some View {
        Section {
            Picker("打开时显示", selection: $preferences.defaultView) {
                Text("周课表").tag("week")
                Text("日课表").tag("day")
                Text("月历").tag("month")
            }
            Picker("卡片密度", selection: $preferences.density) {
                Text("舒适").tag("comfortable")
                Text("紧凑").tag("compact")
            }
            Toggle("显示周末", isOn: $preferences.showWeekend)
            Toggle("显示日期栏", isOn: $preferences.showDateHeader)
        } header: {
            Text("布局")
        }

        Section {
            Toggle("教室", isOn: $preferences.showLocation)
            Toggle("老师", isOn: $preferences.showTeacher)
            Toggle("周次", isOn: $preferences.showWeeks)
        } header: {
            Text("课程卡片上显示什么")
        }

        ScheduleBackgroundSection(preferences: preferences)
    }
}

/// Background image picker. Lives inline in 课表显示 so the setting is one tap
/// away instead of two.
private struct ScheduleBackgroundSection: View {
    @ObservedObject var preferences: NativeSchedulePreferences
    @State private var selectedBackground: PhotosPickerItem?
    @State private var backgroundBusy = false
    @State private var backgroundError = ""

    var body: some View {
        Section {
            PhotosPicker(selection: $selectedBackground, matching: .images) {
                Label(
                    backgroundBusy ? "正在读取图片…" : (preferences.backgroundImage == nil ? "选择背景图片" : "更换背景图片"),
                    systemImage: "photo.on.rectangle"
                )
            }
            .disabled(backgroundBusy)

            if let image = preferences.backgroundImage {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack {
                    Text("不透明度")
                    Slider(value: $preferences.backgroundOpacity, in: 0.05...0.5, step: 0.01)
                    Text("\(Int(preferences.backgroundOpacity * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                Button("移除背景图片", role: .destructive) {
                    try? preferences.setBackgroundData(nil)
                }
                .disabled(backgroundBusy)
            }
        } header: {
            Text("背景图片")
        }
        .onChange(of: selectedBackground) { _, item in
            guard let item else { return }
            backgroundBusy = true
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw BackgroundError.invalidData }
                    try preferences.setBackgroundData(data)
                } catch {
                    backgroundError = "这张图片读不出来，换一张再试。"
                }
                backgroundBusy = false
                selectedBackground = nil
            }
        }
        .alert("背景图片", isPresented: Binding(
            get: { !backgroundError.isEmpty },
            set: { if !$0 { backgroundError = "" } }
        )) {
            Button("知道了", role: .cancel) { backgroundError = "" }
        } message: {
            Text(backgroundError)
        }
    }

    private enum BackgroundError: Error { case invalidData }
}

// MARK: - 小组件

/// The widget screen, split so each group carries only the explanation it needs.
struct WidgetSettingsScreen: View {
    @ObservedObject var settings: NativeWidgetSettings
    @ObservedObject var store: NativeScheduleStore

    var body: some View {
        Form {
            Section {
                LabeledContent("课表数据", value: settings.isConfigured ? "已同步" : "尚未同步")
                Button {
                    sync()
                } label: {
                    Label("立即同步一次", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.snapshot(useSharedNotifications: false) == nil)

                if let status = settings.status {
                    Label(status, systemImage: status.contains("失败") ? "exclamationmark.triangle" : "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(status.contains("失败") ? .orange : Color.cpuBrand)
                }
            } header: {
                Text("状态")
            } footer: {
                Text("平时自动同步，迟迟不更新时才用这个按钮催一次。\n"
                     + "长按桌面空白处添加「临近课程」「今日课表」或「两日课表」。")
            }

            Section {
                Toggle("课程名称", isOn: optionBinding(\.showCourseName))
                Toggle("教室", isOn: optionBinding(\.showRoom))
                Toggle("老师", isOn: optionBinding(\.showTeacher))
                Toggle("上课时间", isOn: optionBinding(\.showTime))
            } header: {
                Text("小组件上显示什么")
            }

            Section {
                Toggle("农历日期", isOn: optionBinding(\.showLunarDate))
                Toggle("节假日提示", isOn: optionBinding(\.showHoliday))
            Toggle("最近节假日常驻", isOn: optionBinding(\.holidayAlwaysVisible))
                .disabled(!settings.options.showHoliday)
            } header: {
                Text("日期信息")
            } footer: {
                Text("只标法定假日和传统节日。当年的调休上班安排来自学校配置，会直接改课表和小组件里的课程。")
            }

            Section {
                Picker("今天的课上完后", selection: Binding(
                    get: { settings.options.afterClass },
                    set: { value in
                        var options = settings.options
                        options.afterClass = value
                        settings.setDisplayOptions(options)
                    }
                )) {
                    ForEach(ScheduleWidgetAfterClassStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } header: {
                Text("下课之后")
            } footer: {
                Text("明天也没课时自动改显示假期。「两日课表」不受影响。")
            }
        }
        .navigationTitle("桌面小组件")
        .appInlineNavigationTitle()
    }

    private func optionBinding(_ keyPath: WritableKeyPath<NativeWidgetSettings.WidgetDisplayOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.options[keyPath: keyPath] },
            set: { value in
                var options = settings.options
                options[keyPath: keyPath] = value
                settings.setDisplayOptions(options)
            }
        )
    }

    private func sync() {
        guard let snapshot = store.snapshot(useSharedNotifications: false) else {
            settings.status = "当前没有可同步的课表"
            return
        }
        settings.writePayload(from: snapshot, selectedWeek: store.localSelectedWeek)
    }
}

// MARK: - 主题

struct GlobalThemeSettingsSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var settings = NativeThemeSettings.shared

    var body: some View {
        Section {
            Picker("外观", selection: Binding(
                get: { store.settings.appearance },
                set: { value in store.updateSettings { $0.appearance = value } }
            )) {
                Text("跟随系统").tag(AppearancePreference.system)
                Text("深色").tag(AppearancePreference.dark)
                Text("浅色").tag(AppearancePreference.light)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
        } header: {
            Text("深色 / 浅色")
        }

        Section {
            ForEach(ScheduleLiveActivityTheme.allCases) { theme in
                Button {
                    settings.setTheme(theme)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: theme.systemImage)
                            .foregroundStyle(themeColor(theme))
                            .frame(width: 24)
                        Text(theme.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if settings.theme == theme {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(themeColor(theme))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(settings.theme == theme ? [.isSelected] : [])
            }

            if settings.theme == .custom {
                ColorPicker("挑一个颜色", selection: customColorBinding, supportsOpacity: false)
            }
        } header: {
            Text("主题色")
        } footer: {
            Text("同时应用到课表、小组件、实时活动和灵动岛。")
        }
    }

    private func themeColor(_ theme: ScheduleLiveActivityTheme) -> Color {
        let value = theme == .custom ? settings.customColor : theme.brandColor
        return Color(red: value.red, green: value.green, blue: value.blue)
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: {
                let value = settings.customColor
                return Color(red: value.red, green: value.green, blue: value.blue)
            },
            set: { color in
                guard let value = rgbComponents(from: color) else { return }
                settings.setCustomColor(value)
            }
        )
    }

    private func rgbComponents(from color: Color) -> ScheduleLiveActivityRGB? {
        #if os(macOS)
        guard let platformColor = PlatformColor(color).usingColorSpace(.sRGB) else { return nil }
        return ScheduleLiveActivityRGB(
            red: Double(platformColor.redComponent),
            green: Double(platformColor.greenComponent),
            blue: Double(platformColor.blueComponent)
        )
        #else
        let platformColor = PlatformColor(color)
        var red = CGFloat.zero
        var green = CGFloat.zero
        var blue = CGFloat.zero
        var alpha = CGFloat.zero
        if platformColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return ScheduleLiveActivityRGB(red: Double(red), green: Double(green), blue: Double(blue))
        }

        var white = CGFloat.zero
        guard platformColor.getWhite(&white, alpha: &alpha) else { return nil }
        return ScheduleLiveActivityRGB(red: Double(white), green: Double(white), blue: Double(white))
        #endif
    }
}

// MARK: - 实时活动

#if os(iOS)
@available(iOS 16.1, *)
struct LiveActivitySettingsScreen: View {
    @ObservedObject private var consent = PrivacyConsent.shared
    @State private var showPrivacyConsent = false
    @ObservedObject private var controller = NativeLiveActivityController.shared
    @State private var enabled: Bool
    @State private var perPeriod: Bool
    @State private var leadMinutes: Int

    init() {
        _enabled = State(initialValue: NativeLiveActivityController.shared.isEnabled)
        _perPeriod = State(initialValue: NativeLiveActivityController.shared.perPeriod)
        _leadMinutes = State(initialValue: NativeLiveActivityController.shared.leadMinutes)
    }

    private func leadLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) 分钟" : (minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分")
    }

    var body: some View {
        Form {
            Section {
                Toggle("显示实时活动", isOn: Binding(
                    get: { enabled },
                    set: { value in
                        if value && !consent.liveAccepted { showPrivacyConsent = true; return }
                        enabled = value
                        NativeLiveActivityController.shared.setEnabled(value)
                    }
                ))
            } header: {
                Text("总开关")
            } footer: {
                Text("在锁屏和灵动岛上倒计时到上课 / 下课。")
            }

            Section {
                Picker("提前显示", selection: Binding(
                    get: { leadMinutes },
                    set: { value in
                        leadMinutes = value
                        NativeLiveActivityController.shared.setLeadMinutes(value)
                    }
                )) {
                    ForEach(NativeLiveActivityController.leadMinuteOptions, id: \.self) { minutes in
                        Text(leadLabel(minutes)).tag(minutes)
                    }
                }
                .disabled(!enabled)
            } header: {
                Text("什么时候出现")
            } footer: {
                Text("提醒不会占用上一门课的上课时间；每门课程在最后一节结束时收起。")
            }

            Section {
                Toggle("分节计时", isOn: Binding(
                    get: { perPeriod },
                    set: { value in
                        perPeriod = value
                        NativeLiveActivityController.shared.setPerPeriod(value)
                    }
                ))
                .disabled(!enabled)
            } header: {
                Text("课程内计时")
            } footer: {
                Text("开启后分别倒计时到每节课的边界；关闭后倒计时到整堂课结束。连堂课的课间保留同一活动。")
            }

            Section("实际安排") {
                Text(controller.coverage)
                if controller.omitted > 0 { Text("\(controller.omitted) 项课程缺少可靠时间或来源身份，未安排。") }
                if let detail = controller.status.detail { Text(detail).foregroundStyle(.secondary) }
                if let notice = controller.tokenNotice { Text(notice).foregroundStyle(.secondary) }
                Text("iOS 26 及以上预约未来 168 小时，回到前台后补充；离线漏收广播可能延迟收起。iOS 18 使用远程启动，iOS 17 仅支持前台本地提醒。关心共享课表时，由服务端逐个推送刷新。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !controller.conflicts.isEmpty {
                Section("选择冲突课程") {
                    ForEach(controller.conflicts) { conflict in
                        Picker("\(conflict.date) 第 \(conflict.period) 节", selection: Binding(
                            get: { controller.selectedSource(for: conflict) },
                            set: { controller.selectSource($0, for: conflict) }
                        )) {
                            Text("请选择").tag("")
                            ForEach(conflict.choices) { choice in Text(choice.name).tag(choice.id) }
                        }
                    }
                }
            }

            Section {
                if enabled, ActivityAuthorizationInfo().areActivitiesEnabled {
                    Button {
                        if controller.isPreviewActive {
                            controller.endPreview()
                        } else {
                            controller.startPreview()
                        }
                    } label: {
                        Label(
                            controller.isPreviewActive ? "结束预览" : "预览效果",
                            systemImage: controller.isPreviewActive ? "stop.circle" : "play.circle"
                        )
                    }
                }
                if enabled {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: statusSymbol)
                            .foregroundStyle(statusColor)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(controller.status.title)
                                .font(.subheadline.weight(.medium))
                            if controller.isPreviewActive {
                                Text("正在显示一节演示课程，锁屏后可以看到完整布局。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else if controller.status == .active {
                                Text("回到主屏幕或锁屏后即可看到。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !ActivityAuthorizationInfo().areActivitiesEnabled {
                    Label("系统设置里还没允许「实时活动」", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("当前状态")
            }
        }
        .navigationTitle("实时活动")
        .appInlineNavigationTitle()
        .onAppear { enabled = controller.isEnabled }
        .onChange(of: consent.liveAccepted) { _, _ in enabled = controller.isEnabled }
        .sheet(isPresented: $showPrivacyConsent) {
            LiveActivityConsentView {
                controller.setEnabled(true)
                enabled = controller.isEnabled
            }
        }
    }

    private var statusSymbol: String {
        switch controller.status {
        case .active: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .unavailable: return "minus.circle"
        case .disabled: return "pause.circle"
        case .waiting, .limited: return "clock"
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .active: return .cpuBrand
        case .failed, .unavailable, .limited: return .orange
        case .disabled, .waiting: return .secondary
        }
    }
}

#endif
