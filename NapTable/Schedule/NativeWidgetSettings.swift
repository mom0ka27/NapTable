import Combine
import Foundation
import WidgetKit

/// `WidgetCenter` needs a newer system than this target builds against on
/// visionOS, where NapTable has no widget extension anyway.
@MainActor
func reloadScheduleWidgetTimelines() {
    #if os(visionOS)
    if #available(visionOS 26.0, *) { WidgetCenter.shared.reloadAllTimelines() }
    #else
    WidgetCenter.shared.reloadAllTimelines()
    #endif
}

/// The app-side half of the iPhone widgets.
///
/// CpuTime's `NativeWidgetSettings` fetched a per-account widget endpoint from
/// the Web bridge and stored it in the App Group so the extension could call the
/// server itself. NapTable is local-only, so the app instead projects its own
/// timetable into `WidgetSchedulePayload` and writes it into the App Group; the
/// extension never needs the network. Display options keep the same shared
/// key as CpuTime; the accent theme is managed globally by
/// `NativeThemeSettings`.
@MainActor
final class NativeWidgetSettings: ObservableObject {
    @Published var status: String?
    @Published var options: WidgetDisplayOptions

    private let defaults: UserDefaults?

    /// Mirrors CpuTime's `WidgetDisplayOptions`; the shared key is read by the
    /// extension through `ScheduleWidgetDisplayOptions`.
    struct WidgetDisplayOptions: Equatable {
        var showCourseName: Bool
        var showRoom: Bool
        var showTeacher: Bool
        var showTime: Bool
        var showLunarDate: Bool
        var showHoliday: Bool
        var holidayAlwaysVisible: Bool
        var afterClass: ScheduleWidgetAfterClassStyle

        static let `default` = WidgetDisplayOptions(
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

        init(_ value: ScheduleWidgetDisplayOptions) {
            self.init(
                showCourseName: value.showCourseName,
                showRoom: value.showRoom,
                showTeacher: value.showTeacher,
                showTime: value.showTime,
                showLunarDate: value.showLunarDate,
                showHoliday: value.showHoliday,
                holidayAlwaysVisible: value.holidayAlwaysVisible,
                afterClass: value.afterClass
            )
        }

        var shared: ScheduleWidgetDisplayOptions {
            ScheduleWidgetDisplayOptions(
                showCourseName: showCourseName,
                showRoom: showRoom,
                showTeacher: showTeacher,
                showTime: showTime,
                showLunarDate: showLunarDate,
                showHoliday: showHoliday,
                holidayAlwaysVisible: holidayAlwaysVisible,
                afterClass: afterClass
            )
        }
    }

    init() {
        let defaults = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)
        self.defaults = defaults
        options = WidgetDisplayOptions(
            ScheduleWidgetDisplayOptions.load(defaults: defaults)
        )
    }

    var isConfigured: Bool {
        defaults?.data(forKey: NextWidgetConfiguration.payloadKey) != nil
    }

    func setDisplayOptions(_ value: WidgetDisplayOptions) {
        options = value
        guard let defaults, let data = try? JSONEncoder().encode(value.shared) else { return }
        defaults.set(data, forKey: NextWidgetConfiguration.widgetDisplayOptionsKey)
        defaults.synchronize()
        reloadScheduleWidgetTimelines()
    }

    func resetDisplayOptions() {
        setDisplayOptions(.default)
    }

    /// Writes the current timetable into the App Group. Safe to call on every
    /// store rebuild: it is one small JSON encode.
    @discardableResult
    func writePayload(from snapshot: NativeScheduleSnapshot, selectedWeek: Int?) -> Bool {
        guard let payload = Self.payload(from: snapshot, selectedWeek: selectedWeek) else {
            status = "暂无可同步的课表"
            return false
        }
        do {
            try ScheduleWidgetStore.save(payload)
        } catch {
            status = "同步失败，请稍后重试"
            return false
        }
        reloadScheduleWidgetTimelines()
        status = "已同步 \(payload.weekDays?.count ?? 0) 天课表"
        return true
    }

    /// Projects the native snapshot into the flat shape the widgets decode.
    /// `selectedWeek` is what the timetable is showing; `today` always comes
    /// from the calendar's real current week so a widget never reports a
    /// browsed week as "today".
    static func payload(from snapshot: NativeScheduleSnapshot, selectedWeek: Int?) -> WidgetSchedulePayload? {
        guard let data = snapshot.data, let calendar = snapshot.calendar,
              let weekNumber = selectedWeek ?? Int(data.currentWeek) ?? calendar.weeks.first?.week,
              let week = calendar.weeks.first(where: { $0.week == weekNumber }) else {
            return nil
        }
        let periods = snapshot.periods.isEmpty ? NativeSchedulePeriod.bundledTimetable : snapshot.periods
        let semesterLabel = data.semesters.first(where: { $0.value == data.currentSemester })?.label
            ?? data.currentSemester

        func days(for week: NativeCalendarWeek) -> [WidgetDay] {
            week.days.enumerated().map { index, date in
                let day = index + 1
                // 调休：放假那天没课，补班那天上的是另一天的课。
                let adjustment = calendar.adjustments[date]
                let sourceDay = adjustment?.sourceDay ?? day
                let sourceWeek = adjustment?.sourceWeek ?? week.week
                let courseList = adjustment?.suppressesCourses == true
                    ? []
                    : courses(day: sourceDay, week: sourceWeek, data: data, periods: periods)
                return WidgetDay(
                    day: day,
                    label: widgetDayLabel(day),
                    date: date,
                    week: week.week,
                    isToday: date == calendar.weeks.first(where: { $0.week == calendar.currentWeek })?.days[safe: index],
                    courses: courseList,
                    note: adjustment?.detail
                )
            }
        }

        let weekDays = days(for: week)
        let currentWeekData = calendar.weeks.first(where: { $0.week == calendar.currentWeek }) ?? week
        // 周日晚上要显示「明天」，那一天属于下一周；「最近有课的一天」最多往后看三周。
        // 所以按真正的当前周带上这一周和之后三周（翻到别的周时 weekDays 不是当前周），去掉和 weekDays 重复的日子。
        var knownDates = Set(weekDays.compactMap(\.date))
        let nextWeekDays = (0...3)
            .compactMap { offset in calendar.weeks.first(where: { $0.week == currentWeekData.week + offset }) }
            .flatMap(days(for:))
            .filter { day in day.date.map { knownDates.insert($0).inserted } ?? false }
        let todayDate = WidgetSchedulePayload.dateString(.now)
        let today = days(for: currentWeekData).first(where: { $0.date == todayDate })
            ?? days(for: currentWeekData).first(where: { $0.day == Self.chinaWeekday })
            ?? weekDays.first

        return WidgetSchedulePayload(
            title: semesterLabel,
            sourceLabel: snapshot.sourceLabel,
            generatedAt: ISO8601DateFormatter().string(from: .now),
            semester: semesterLabel,
            currentWeek: week.week,
            today: today,
            days: weekDays,
            weekDays: weekDays,
            nextWeekDays: nextWeekDays
        )
    }

    private static func courses(
        day: Int,
        week: Int,
        data: NativeScheduleResult,
        periods: [NativeSchedulePeriod]
    ) -> [WidgetCourse] {
        data.cells
            .filter { $0.day == day }
            .flatMap { cell in
                cell.courses.compactMap { course -> WidgetCourse? in
                    let weeks = course.weekList.filter { $0 > 0 }
                    if !weeks.isEmpty, !weeks.contains(week) { return nil }
                    let range = NativeSchedulePeriod.normalizedRange(
                        bigSlot: cell.bigSlot,
                        startSlot: course.startSlot,
                        endSlot: course.endSlot,
                        periods: periods
                    )
                    return WidgetCourse(
                        name: course.name,
                        teacher: course.teacher,
                        location: course.location,
                        note: nil,
                        slotNote: course.slotNote,
                        startTime: periods.first(where: { $0.number == range.start })?.startTime,
                        endTime: periods.first(where: { $0.number == range.end })?.endTime,
                        startSlot: range.start,
                        endSlot: range.end
                    )
                }
            }
            .sorted { lhs, rhs in
                (lhs.startSlot ?? 0, lhs.name ?? "") < (rhs.startSlot ?? 0, rhs.name ?? "")
            }
    }

    private static func widgetDayLabel(_ day: Int) -> String {
        let labels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return labels.indices.contains(day - 1) ? labels[day - 1] : "周\(day)"
    }

    private static var chinaWeekday: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let weekday = calendar.component(.weekday, from: .now)
        return weekday == 1 ? 7 : weekday - 1
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
