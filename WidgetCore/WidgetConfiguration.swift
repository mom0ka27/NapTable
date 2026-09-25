import Foundation

/// Keys and the deep link shared by the app and its extensions.
enum NextWidgetConfiguration {
    static var appGroup: String { AppGroupIdentifier.resolved() }
    static let payloadKey = "naptable.scheduleWidgetPayload"
    static let widgetThemeKey = "scheduleWidgetTheme"
    static let widgetDisplayOptionsKey = "scheduleWidgetDisplayOptions"
    static let globalThemeKey = "scheduleGlobalTheme"
    static let globalCustomColorKey = "scheduleGlobalCustomColor"
    // Kept for migration from the first Live Activity-only theme setting.
    /// Written by the app's Live Activity settings. The widget extension reads
    /// it so a stale render can tell "carry on to the next class" apart from
    /// "this activity is on its way out".
    static let liveActivityPersistentKey = "scheduleLiveActivityPersistent"
    static let liveActivityThemeKey = "scheduleLiveActivityTheme"
    static let liveActivityCustomColorKey = "scheduleLiveActivityCustomColor"

    /// NapTable's own URL scheme. Opening the widget lands on the exact
    /// timetable context the widget was showing instead of an old browsed week.
    static let appURL = URL(string: "naptable://schedule?source=widget&week=current")!

    static func appURL(semester: String?, currentWeek: Int?) -> URL {
        guard var components = URLComponents(url: appURL, resolvingAgainstBaseURL: false) else {
            return appURL
        }
        var query = components.queryItems ?? []
        if let semester = semester?.trimmingCharacters(in: .whitespacesAndNewlines), !semester.isEmpty {
            query.append(URLQueryItem(name: "widgetSemester", value: semester))
        }
        if let currentWeek, (1...64).contains(currentWeek) {
            query.append(URLQueryItem(name: "widgetWeek", value: String(currentWeek)))
        }
        components.queryItems = query
        return components.url ?? appURL
    }

    static var scheduleTheme: ScheduleWidgetTheme {
        globalTheme.widgetTheme
    }

    static var displayOptions: ScheduleWidgetDisplayOptions {
        ScheduleWidgetDisplayOptions.load(defaults: UserDefaults(suiteName: appGroup))
    }

    static var liveActivityIsPersistent: Bool {
        UserDefaults(suiteName: appGroup)?.object(forKey: liveActivityPersistentKey) as? Bool ?? false
    }

    static var liveActivityTheme: ScheduleLiveActivityTheme {
        globalTheme
    }

    static var liveActivityCustomColor: ScheduleLiveActivityRGB {
        globalCustomColor
    }

    static var globalTheme: ScheduleLiveActivityTheme {
        let defaults = UserDefaults(suiteName: appGroup)
        let saved = defaults?.string(forKey: globalThemeKey)
            ?? defaults?.string(forKey: liveActivityThemeKey)
        if let saved, let theme = ScheduleLiveActivityTheme(rawValue: saved) {
            return theme
        }

        // Nothing saved yet (or the old `color-glass` widget setting): fall back
        // to the logo pink, the brand default.
        switch defaults?.string(forKey: widgetThemeKey) {
        case "blue": return .blue
        case "teal": return .teal
        case "indigo": return .indigo
        case "violet": return .violet
        case "orange": return .orange
        case "rose": return .rose
        case "slate": return .slate
        case "green": return .green
        default: return .bunny
        }
    }

    static var globalCustomColor: ScheduleLiveActivityRGB {
        let defaults = UserDefaults(suiteName: appGroup)
        let data = defaults?.data(forKey: globalCustomColorKey)
            ?? defaults?.data(forKey: liveActivityCustomColorKey)
        guard let data,
              let value = try? JSONDecoder().decode(ScheduleLiveActivityRGB.self, from: data) else {
            return .default
        }
        return value.clamped
    }
}

/// The fields shown by the iPhone schedule widgets. Stored as a small JSON
/// value so the app and the extension can share it through the App Group
/// without linking either one into the other.
struct ScheduleWidgetDisplayOptions: Codable, Equatable {
    var showCourseName: Bool
    var showRoom: Bool
    var showTeacher: Bool
    var showTime: Bool
    /// 日期栏里的农历日期。
    var showLunarDate: Bool
    /// 节日与法定假期提示。
    var showHoliday: Bool
    /// 最近的节假日常驻在日期栏右侧，而不是只在今天课上完之后才出现。
    var holidayAlwaysVisible: Bool
    /// 今天的课上完之后，小组件拿空出来的位置显示什么。
    var afterClass: ScheduleWidgetAfterClassStyle

    static let `default` = ScheduleWidgetDisplayOptions(
        showCourseName: true,
        showRoom: true,
        showTeacher: true,
        showTime: true,
        showLunarDate: true,
        showHoliday: true,
        holidayAlwaysVisible: true,
        afterClass: .tomorrow
    )

    init(
        showCourseName: Bool,
        showRoom: Bool,
        showTeacher: Bool,
        showTime: Bool,
        showLunarDate: Bool = true,
        showHoliday: Bool = true,
        holidayAlwaysVisible: Bool = true,
        afterClass: ScheduleWidgetAfterClassStyle = .tomorrow
    ) {
        self.showCourseName = showCourseName
        self.showRoom = showRoom
        self.showTeacher = showTeacher
        self.showTime = showTime
        self.showLunarDate = showLunarDate
        self.showHoliday = showHoliday
        self.holidayAlwaysVisible = holidayAlwaysVisible
        self.afterClass = afterClass
    }

    /// 旧版本写进 App Group 的 JSON 没有农历、节假日和课后显示字段。缺字段时按默认值补齐，
    /// 否则整份显示设置会解码失败、把用户已经关掉的开关又打开。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            showCourseName: try values.decodeIfPresent(Bool.self, forKey: .showCourseName) ?? true,
            showRoom: try values.decodeIfPresent(Bool.self, forKey: .showRoom) ?? true,
            showTeacher: try values.decodeIfPresent(Bool.self, forKey: .showTeacher) ?? true,
            showTime: try values.decodeIfPresent(Bool.self, forKey: .showTime) ?? true,
            showLunarDate: try values.decodeIfPresent(Bool.self, forKey: .showLunarDate) ?? true,
            showHoliday: try values.decodeIfPresent(Bool.self, forKey: .showHoliday) ?? true,
            holidayAlwaysVisible: try values.decodeIfPresent(Bool.self, forKey: .holidayAlwaysVisible) ?? true,
            afterClass: try values.decodeIfPresent(ScheduleWidgetAfterClassStyle.self, forKey: .afterClass) ?? .tomorrow
        )
    }

    static func load(defaults: UserDefaults?) -> Self {
        guard let data = defaults?.data(forKey: NextWidgetConfiguration.widgetDisplayOptionsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else {
            return .default
        }
        return value
    }

    func metadata(for course: WidgetCourse) -> String? {
        let values = [showRoom ? course.normalizedLocation : nil,
                      showTeacher ? course.normalizedTeacher : nil]
            .compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    /// 今天没有未结束的课程时，`.none` 之外的两种模式会接管那块空间。
    var showsAfterClassPreview: Bool { afterClass != .none }

    /// 日期栏右侧是否常驻显示最近的节假日。关掉节假日提示时一并关掉。
    var showsResidentHoliday: Bool { showHoliday && holidayAlwaysVisible }

    func primaryValue(for course: WidgetCourse) -> String? {
        if showCourseName { return course.displayName }
        if showRoom { return course.normalizedLocation }
        if showTeacher { return course.normalizedTeacher }
        if showTime { return course.timeRange }
        return nil
    }
}

/// 今天的课上完之后小组件显示什么。在每个小组件的「编辑小组件」里单独选；
/// 两日课表本来就带明天，不受这个设置影响。
enum ScheduleWidgetAfterClassStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 保持原来的「今天没有课程」。
    case none
    /// 明天的课程，灰色显示；明天也没课时退回最近的节假日。
    case tomorrow
    /// 最近的一段法定假期。
    case holiday
    /// 整个小组件换成最近一个有课的日期（一周之内），照常显示那天的课；一周内都没课时退回最近的节假日。
    case nextCourseDay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "今天没有课程"
        case .tomorrow: return "明天的课程"
        case .holiday: return "最近的节假日"
        case .nextCourseDay: return "最近有课的一天"
        }
    }
}

enum ScheduleWidgetTheme: String {
    case bunny
    case green
    case blue
    case teal
    case indigo
    case violet
    case orange
    case rose
    case slate
    case custom
    case colorGlass = "color-glass"
}

enum ScheduleLiveActivityTheme: String, CaseIterable, Codable, Identifiable {
    case bunny
    case green
    case blue
    case teal
    case indigo
    case violet
    case orange
    case rose
    case slate
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bunny: return "兔兔粉"
        case .green: return "青绿"
        case .blue: return "晴蓝"
        case .teal: return "湖青"
        case .indigo: return "靛青"
        case .violet: return "紫罗兰"
        case .orange: return "暖橙"
        case .rose: return "玫瑰"
        case .slate: return "石墨"
        case .custom: return "自定义"
        }
    }

    var systemImage: String {
        switch self {
        case .custom: return "eyedropper"
        default: return "circle.fill"
        }
    }

    var brandColor: ScheduleLiveActivityRGB {
        switch self {
        // The rabbit's ear and cheek pink from the app logo, deepened so it
        // still reads as text and tint on light backgrounds.
        case .bunny: return .init(red: 226 / 255, green: 111 / 255, blue: 99 / 255)
        case .green: return .init(red: 15 / 255, green: 143 / 255, blue: 127 / 255)
        case .blue: return .init(red: 37 / 255, green: 99 / 255, blue: 235 / 255)
        case .teal: return .init(red: 8 / 255, green: 145 / 255, blue: 178 / 255)
        case .indigo: return .init(red: 79 / 255, green: 70 / 255, blue: 229 / 255)
        case .violet: return .init(red: 124 / 255, green: 58 / 255, blue: 237 / 255)
        case .orange: return .init(red: 234 / 255, green: 88 / 255, blue: 12 / 255)
        case .rose: return .init(red: 225 / 255, green: 29 / 255, blue: 72 / 255)
        case .slate: return .init(red: 71 / 255, green: 85 / 255, blue: 105 / 255)
        case .custom: return .default
        }
    }

    var widgetTheme: ScheduleWidgetTheme {
        switch self {
        case .bunny: return .bunny
        case .green: return .green
        case .blue: return .blue
        case .teal: return .teal
        case .indigo: return .indigo
        case .violet: return .violet
        case .orange: return .orange
        case .rose: return .rose
        case .slate: return .slate
        case .custom: return .custom
        }
    }
}

struct ScheduleLiveActivityRGB: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let `default` = ScheduleLiveActivityTheme.bunny.brandColor

    var clamped: Self {
        Self(
            red: min(max(red, 0), 1),
            green: min(max(green, 0), 1),
            blue: min(max(blue, 0), 1)
        )
    }
}
