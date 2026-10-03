import PhotosUI
import SwiftUI
import WidgetKit

#if os(iOS)
import ActivityKit
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The widget / Live Activity rows, shown in the Settings tab.
struct NativeDeviceSettingsContent: View {
    @ObservedObject var scheduleStore: NativeScheduleStore
    @ObservedObject var widgetSettings: NativeWidgetSettings

    @ViewBuilder
    var body: some View {
        Section {
            SettingsDestinationRow(
                title: "桌面小组件",
                detail: widgetSettings.isConfigured ? "已同步，可添加到桌面" : "暂无可显示的课表",
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

/// 「课表显示」整页。
struct ScheduleDisplaySettingsScreen: View {
    var body: some View {
        Form {
            ScheduleSettingsSection()
        }
        .appListBackground()
    }
}

// MARK: - 背景图片

/// 「背景图片」整页。编辑页从这里推进去，跳转挂在 Form 外面：挂在列表
/// 里的 Section 上，惰性加载的行不一定在屏幕上，跳转可能触发不了。
struct ScheduleBackgroundSettingsScreen: View {
    @ObservedObject private var preferences = NativeSchedulePreferences.shared
    @State private var editingBackground: PendingBackground?

    var body: some View {
        Form {
            if preferences.hasAnyBackground {
                Section {
                    Toggle("显示背景图片", isOn: $preferences.backgroundEnabled)
                } footer: {
                    Text("关闭后课表不显示背景，图片与设置仍会保留。")
                }
            }
            ScheduleBackgroundSection(preferences: preferences, dark: false, pendingBackground: $editingBackground)
            ScheduleBackgroundSection(preferences: preferences, dark: true, pendingBackground: $editingBackground)
        }
        .appListBackground()
        .navigationDestination(item: $editingBackground) { pending in
            // 另一个外观有自己的图，这张就只属于当前外观，预览和不透明度都锁在它上面。
            BackgroundCropEditor(
                image: pending.image,
                initialPlacement: pending.placement,
                opacity: Binding(
                    get: { .init(light: preferences.backgroundOpacity, dark: preferences.backgroundOpacityDark) },
                    set: {
                        preferences.backgroundOpacity = $0.light
                        preferences.backgroundOpacityDark = $0.dark
                    }
                ),
                initialPreviewDark: pending.dark,
                locksPreviewAppearance: preferences.hasOwnBackground(dark: !pending.dark),
                commitsOnAppear: pending.isNew,
                onCommit: { data, placement in
                    try preferences.setBackground(cropped: data, source: pending.source,
                                                  placement: placement, dark: pending.dark)
                }
            )
        }
    }
}

/// 等着进编辑页的一张背景图。
struct PendingBackground: Identifiable, Hashable {
    let id = UUID()
    let image: CGImage
    /// 写回磁盘的原图字节。重新调整时原样写回，不会一次次重新压缩变糊。
    let source: Data
    let placement: NativeSchedulePreferences.BackgroundPlacement
    /// 存到深色还是浅色那张。
    let dark: Bool
    /// 刚从相册选的，进编辑页就要先存一次；重新调整已有的图则不用。
    var isNew = false

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

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
                Text("宽松").tag("relaxed")
                Text("舒适").tag("comfortable")
                Text("紧凑").tag("compact")
            }
            Toggle("显示周末", isOn: $preferences.showWeekend)
            Toggle("显示日期栏", isOn: $preferences.showDateHeader)
            Toggle("显示自由时间课程", isOn: $preferences.showFreeTimeCourses)
        } header: {
            Text("布局")
        }

        Section {
            Toggle("隐藏晚间空行", isOn: $preferences.hideLateSlots)
            if preferences.hideLateSlots {
                Stepper(
                    "隐藏第 \(preferences.hideSlotsAfter) 节之后",
                    value: $preferences.hideSlotsAfter,
                    in: hideSlotRange
                )
            }
        } header: {
            Text("节次")
        } footer: {
            Text("隐藏无课的晚间节次。若本周有更晚的课程，则显示至最后一节课。")
        }
    }

    /// 1 到倒数第二节；当前值超出（换了节次更少的课表）时上限放宽到当前值，免得步进器卡住。
    private var hideSlotRange: ClosedRange<Int> {
        1...max(ScheduleSlot.all.count - 1, preferences.hideSlotsAfter, 1)
    }
}

/// 「背景图片」里一个外观的那一组。没单独设图的外观沿用另一个外观的图。
private struct ScheduleBackgroundSection: View {
    @ObservedObject var preferences: NativeSchedulePreferences
    let dark: Bool
    @State private var selectedBackground: PhotosPickerItem?
    @State private var backgroundBusy = false
    @State private var backgroundError = ""
    @State private var confirmingRemoval = false
    @Binding var pendingBackground: PendingBackground?

    private var name: String { dark ? "深色模式" : "浅色模式" }
    private var otherName: String { dark ? "浅色模式" : "深色模式" }

    var body: some View {
        let ownImage = preferences.hasOwnBackground(dark: dark) ? ownBackground : nil
        let followsOther = ownImage == nil && preferences.hasOwnBackground(dark: !dark)
        Section {
            if let image = ownImage {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if followsOther {
                LabeledContent("当前", value: "跟随\(otherName)的图片")
            }

            PhotosPicker(selection: $selectedBackground, matching: .images) {
                Label(pickerTitle(hasOwn: ownImage != nil, followsOther: followsOther), systemImage: "photo.on.rectangle")
            }
            .disabled(backgroundBusy)

            if ownImage != nil {
                Button {
                    adjustCurrentBackground()
                } label: {
                    Label("调整位置和大小", systemImage: "crop")
                }
                .disabled(backgroundBusy)
                Button(role: .destructive) {
                    confirmingRemoval = true
                } label: {
                    Text(preferences.hasOwnBackground(dark: !dark) ? "移除，改用\(otherName)的图片" : "移除背景图片")
                }
                .disabled(backgroundBusy)
                .confirmationDialog("移除\(name)的背景图片？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                    Button("移除", role: .destructive) {
                        try? preferences.setBackgroundData(nil, dark: dark)
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(preferences.hasOwnBackground(dark: !dark)
                         ? "移除后，\(name)将改用\(otherName)的图片，原图与调整记录将一并删除。"
                         : "原图与调整记录将一并删除。如仅需暂时隐藏，请关闭「显示背景图片」。")
                }
            }
        } header: {
            Text(name)
        } footer: {
            if ownImage == nil {
                Text(followsOther
                     ? "未单独设置时，\(name)沿用\(otherName)的图片。"
                     : (dark ? "仅设置一张时，浅色与深色模式共用。" : ""))
            }
        }
        .onChange(of: selectedBackground) { _, item in
            guard let item else { return }
            backgroundBusy = true
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = BackgroundCropEditor.decode(data),
                          let source = BackgroundCropEditor.jpegData(image) else { throw BackgroundError.invalidData }
                    // 先进编辑页摆好位置和大小，按「使用」才写进课表。原图存的是
                    // 缩小并转正之后的版本，不留相册里的几十兆原文件。
                    pendingBackground = PendingBackground(image: image, source: source, placement: .init(),
                                                          dark: dark, isNew: true)
                } catch {
                    backgroundError = "无法读取该图片，请更换后重试。"
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

    private var ownBackground: ScheduleBackgroundImage? {
        dark ? preferences.backgroundImageDark : preferences.backgroundImage
    }

    private func pickerTitle(hasOwn: Bool, followsOther: Bool) -> String {
        if backgroundBusy { return "正在读取图片…" }
        if hasOwn { return "更换图片" }
        return followsOther ? "为\(name)单独设置" : (dark ? "为深色模式单独设置" : "选择背景图片")
    }

    /// 用留着的原图和上次的摆放重新打开编辑页。
    private func adjustCurrentBackground() {
        guard let source = preferences.backgroundSourceData(dark: dark),
              let image = BackgroundCropEditor.decode(source) else {
            backgroundError = "无法读取原图，请重新选择图片。"
            return
        }
        pendingBackground = PendingBackground(image: image, source: source,
                                              placement: preferences.backgroundPlacement(dark: dark), dark: dark)
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
                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
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
                Text("课表会自动同步，仅在小组件长时间未更新时需要手动同步。\n"
                     + "长按桌面空白处即可添加小组件；长按小组件并选择「编辑小组件」可调整显示内容。")
            }

            Section {
                Toggle("课程名称", isOn: optionBinding(\.showCourseName))
                Toggle("教室", isOn: optionBinding(\.showRoom))
                Toggle("老师", isOn: optionBinding(\.showTeacher))
                Toggle("上课时间", isOn: optionBinding(\.showTime))
            } header: {
                Text("显示内容")
            }

            Section {
                Toggle("农历日期", isOn: optionBinding(\.showLunarDate))
                Toggle("节假日提示", isOn: optionBinding(\.showHoliday))
                Toggle("始终显示最近节假日", isOn: optionBinding(\.holidayAlwaysVisible))
                    .disabled(!settings.options.showHoliday)
            } header: {
                Text("日期信息")
            } footer: {
                Text("仅标注法定节假日与传统节日，没课时显示最近假期的倒计时；开启「始终显示最近节假日」后，有课时日期栏也会显示。调休安排由学校配置提供，并直接体现在课表与小组件中。")
            }
        }
        .appListBackground()
        .navigationTitle("桌面小组件")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
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
            settings.status = "暂无可同步的课表"
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
                ColorPicker("自定义颜色", selection: customColorBinding, supportsOpacity: false)
            }
        } header: {
            Text("主题色")
        } footer: {
            Text("应用于课表、小组件、实时活动与灵动岛。")
        }

        Section {
            Toggle("纯色模式", isOn: Binding(
                get: { settings.solidCourseColors },
                set: { settings.setSolidCourseColors($0) }
            ))
        } footer: {
            Text("开启后，所有课程均使用主题色；关闭时，每门课程使用各自的颜色。")
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
    @ObservedObject private var purchases = PurchaseManager.shared
    @State private var showPrivacyConsent = false
    @State private var showEntitlementNotice = false
    @ObservedObject private var controller = NativeLiveActivityController.shared
    @State private var enabled: Bool
    @State private var perPeriod: Bool
    @State private var leadMinutes: Int
    @State private var sharedLeadMinutes: Int

    init() {
        _enabled = State(initialValue: NativeLiveActivityController.shared.isEnabled)
        _perPeriod = State(initialValue: NativeLiveActivityController.shared.perPeriod)
        _leadMinutes = State(initialValue: NativeLiveActivityController.shared.leadMinutes)
        _sharedLeadMinutes = State(initialValue: NativeLiveActivityController.shared.sharedLeadMinutes)
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
                        if value && !purchases.allowsLiveActivities { showEntitlementNotice = true; return }
                        enabled = value
                        NativeLiveActivityController.shared.setEnabled(value)
                    }
                ))
            } header: {
                Text("总开关")
            } footer: {
                Text(purchases.isBeta ? "在锁屏与灵动岛上显示上课、下课倒计时。Beta 版本免费使用，无需试用或购买。" : "在锁屏与灵动岛上显示上课、下课倒计时。试用或买断后可使用。")
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
                if controller.following {
                    Picker("共享课程提前显示", selection: Binding(
                        get: { sharedLeadMinutes },
                        set: { value in
                            sharedLeadMinutes = value
                            NativeLiveActivityController.shared.setSharedLeadMinutes(value)
                        }
                    )) {
                        ForEach(NativeLiveActivityController.leadMinuteOptions, id: \.self) { minutes in
                            Text(leadLabel(minutes)).tag(minutes)
                        }
                    }
                    .disabled(!enabled)
                }
            } header: {
                Text("提醒时间")
            } footer: {
                Text(controller.following
                     ? "自己的课程和共享课表分别按各自的提前时间显示。"
                     : "课程会在上一门课结束前保持显示，并在最后一节结束时收起。")
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
                Text("计时方式")
            } footer: {
                Text("开启后按每一节分别倒计时；关闭后倒计时至整堂课结束。")
            }

            if !ActivityAuthorizationInfo().areActivitiesEnabled {
                Section {
                    Label("请在系统设置中允许「实时活动」", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } footer: {
                    Text("系统关闭实时活动时，课程提醒仍会按通知设置发送。")
                }
            }
        }
        .appListBackground()
        .navigationTitle("实时活动")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
        .onAppear { enabled = controller.isEnabled }
        .task { await purchases.load() }
        .onChange(of: controller.status) { _, _ in enabled = controller.isEnabled }
        .onChange(of: consent.liveAccepted) { _, _ in enabled = controller.isEnabled }
        .sheet(isPresented: $showPrivacyConsent) {
            LiveActivityConsentView {
                guard purchases.allowsLiveActivities else { showEntitlementNotice = true; return }
                controller.setEnabled(true)
                enabled = controller.isEnabled
            }
        }
        .alert("需要实时活动权益", isPresented: $showEntitlementNotice) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text(purchases.accessMode == .unavailable || purchases.accessMode == .loading
                 ? "连接失败，请联网后重试。"
                 : "请先返回设置首页，在“版本与权益”中开始试用或买断实时活动。")
        }
    }
}

#endif
