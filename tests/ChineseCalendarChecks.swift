import Foundation

/// 农历换算、节日与法定假期的离线校验。
///
/// 只编译 `WidgetCore/ChineseCalendar.swift`，不需要模拟器：
/// `tests/check-chinese-calendar.sh`
@main
struct ChineseCalendarChecks {
    static func main() {
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            guard condition else {
                FileHandle.standardError.write(Data("FAIL: \(message())\n".utf8))
                exit(1)
            }
        }
        func day(_ value: String) -> ChineseCalendarDay {
            guard let info = ChineseCalendarInfo.info(forDate: value) else {
                FileHandle.standardError.write(Data("FAIL: 没有 \(value) 的农历数据\n".utf8))
                exit(1)
            }
            return info
        }

        // 农历换算与干支
        let springFestival = day("2026-02-17")
        expect(springFestival.lunar.fullLabel == "正月初一", "春节农历为 \(springFestival.lunar.fullLabel)")
        expect(springFestival.lunar.yearLabel == "丙午马年", "干支为 \(springFestival.lunar.yearLabel)")
        expect(day("2025-01-29").festivals.first == "春节", "2025 年春节")
        expect(day("2026-03-03").lunar.dayLabel == "十五", "元宵农历日")
        expect(day("2026-09-17").displayLabel == "初七", "平常日显示农历日期")
        expect(day("2026-09-11").displayLabel == "八月", "初一显示月名")

        // 除夕跟着腊月的大小月走，不是固定的腊月三十
        let eve = day("2026-02-16")
        expect(eve.lunar.fullLabel == "腊月廿九", "除夕农历为 \(eve.lunar.fullLabel)")
        expect(eve.festivals.first == "除夕", "除夕节日")
        expect(eve.holiday == "春节", "除夕放假")

        // 今天没课时那句问候：只有法定假日道贺，周末和工作日都交给调用方说「今日无课」
        expect(ChineseCalendarInfo.restGreeting(forDate: "2026-09-25") == "中秋快乐", "中秋当天的问候")
        expect(ChineseCalendarInfo.restGreeting(forDate: "2026-10-01") == "国庆快乐", "国庆当天的问候")
        expect(ChineseCalendarInfo.restGreeting(forDate: "2026-09-19") == nil, "周六不道「周末快乐」")
        expect(ChineseCalendarInfo.restGreeting(forDate: "2026-09-20") == nil, "周日不道「周末快乐」")
        expect(ChineseCalendarInfo.restGreeting(forDate: "2026-09-18") == nil, "普通工作日不道喜")
        // 清明也是周日，假期优先，且不说「快乐」
        expect(ChineseCalendarInfo.restGreeting(forDate: "2026-04-05") == "清明安康", "清明的问候")
        expect(ChineseCalendarInfo.restGreeting(forDate: "2026-06-19") == "端午安康", "端午说安康")

        // 法定假期区间：春节自除夕起 4 天
        expect(day("2026-02-19").holiday == "春节", "正月初三放假")
        expect(day("2026-02-20").holiday == nil, "正月初四不在法定假期内")
        expect(day("2026-06-19").holiday == "端午节", "端午")
        expect(day("2026-09-25").holiday == "中秋节", "中秋")
        expect(day("2026-04-05").solarTerm == "清明", "2026 清明")
        expect(day("2025-04-04").holiday == "清明节", "2025 清明放假")
        expect(day("2026-05-02").holiday == "劳动节", "劳动节两天")
        expect(day("2026-05-03").holiday == nil, "5 月 3 日不是法定假日")
        expect(day("2026-10-03").holiday == "国庆节", "国庆三天")
        expect(day("2026-10-04").holiday == nil, "10 月 4 日不是法定假日")

        // 假期倒计时，包括跨年
        let reference = ChineseCalendarInfo.date(fromDate: "2026-09-17")!
        let next = ChineseCalendarInfo.nextHoliday(from: reference)!
        expect(next.window.name == "中秋节" && next.daysAway == 8, "下一个假期是 \(next.window.name) \(next.daysAway) 天后")
        let during = ChineseCalendarInfo.nextHoliday(from: ChineseCalendarInfo.date(fromDate: "2026-10-02")!)!
        expect(during.window.name == "国庆节" && during.daysAway == 0, "假期当天倒计时为 0")
        let crossYear = ChineseCalendarInfo.nextHoliday(from: ChineseCalendarInfo.date(fromDate: "2026-12-28")!)!
        expect(crossYear.window.name == "元旦" && crossYear.daysAway == 4, "跨年取下一年的元旦")
        expect(
            ChineseCalendarInfo.nextHoliday(from: ChineseCalendarInfo.date(fromDate: "2026-10-05")!, withinDays: 7) == nil,
            "窗口外不返回假期"
        )

        // 倒计时文案：假期到来前统一报剩余天数，连休带上天数
        func countdown(_ date: String) -> ChineseHolidayCountdown {
            ChineseCalendarInfo.countdown(from: ChineseCalendarInfo.date(fromDate: date)!, withinDays: 120)!
        }
        let far = countdown("2026-09-17")
        expect(far.phrase == "距中秋节还有 8 天", "远处的假期报天数：\(far.phrase)")
        expect(far.amount == "8" && far.trailing == "天", "天数要能单独取出来上色")
        expect(far.dateLabel == "9.25 周五", "单日假期带星期：\(far.dateLabel)")
        let tomorrowHoliday = countdown("2026-09-24")
        expect(tomorrowHoliday.phrase == "距中秋节还有 1 天" && tomorrowHoliday.amount == "1",
               "一天也报天数：\(tomorrowHoliday.phrase)")
        expect(countdown("2026-09-23").phrase == "距中秋节还有 2 天", "两天也报天数")
        let national = countdown("2026-09-26")
        expect(national.window.name == "国庆节" && national.phrase == "距国庆节还有 5 天", "中秋过后接国庆：\(national.phrase)")
        expect(national.dateLabel == "10.1 - 10.3 · 休 3 天", "连休报区间和天数：\(national.dateLabel)")
        expect(national.window.dayCount == 3, "国庆放三天")
        let springFestivalWindow = ChineseCalendarInfo.holidays(inYear: 2026).first { $0.name == "春节" }!
        expect(springFestivalWindow.dayCount == 4, "春节放四天")

        // 服务端下发的放假安排：调休表放假行的说明就是节日名，连休里的周末也在内
        func offDays(_ note: String, _ from: String, _ to: String) -> [(date: String, note: String)] {
            var rows: [(date: String, note: String)] = []
            var cursor = ChineseCalendarInfo.date(fromDate: from)!
            while ChineseCalendarInfo.dateString(cursor) <= to {
                rows.append((ChineseCalendarInfo.dateString(cursor), note))
                cursor = ChineseCalendarInfo.gregorian.date(byAdding: .day, value: 1, to: cursor)!
            }
            return rows
        }
        let published = PublishedHoliday.fromOffDays(
            offDays("国庆节、中秋节", "2025-10-01", "2025-10-08")
                + offDays("元旦", "2025-12-31", "2026-01-02")
                + offDays("春节", "2026-02-15", "2026-02-23")
                + offDays("中秋节", "2026-09-25", "2026-09-27")
                + offDays("国庆节", "2026-10-01", "2026-10-07")
                + [("2026-11-06", "校运会停课"), ("2026-10-10", "")]
        )
        expect(published.first?.name == "国庆节", "合并的说明取先出现的节日")
        expect(!published.contains { $0.date == "2026-11-06" || $0.date == "2026-10-10" }, "学校自己的停课不算法定假日")
        ChineseCalendarInfo.usePublishedHolidays(published)

        expect(day("2026-09-26").holiday == "中秋节", "中秋连休的周六")
        expect(ChineseCalendarInfo.restGreeting(forDate: "2026-09-26") == "中秋快乐", "连休里的周末道节日的贺")
        expect(ChineseCalendarInfo.restGreeting(forDate: "2026-10-04") == "国庆快乐", "国庆连休的周日")
        expect(day("2026-10-07").holiday == "国庆节" && day("2026-10-08").holiday == nil, "国庆放到 10.7")
        expect(day("2026-02-23").holiday == "春节" && day("2026-02-24").holiday == nil, "春节按安排放九天")
        expect(countdown("2026-09-17").dateLabel == "9.25 - 9.27 · 休 3 天", "中秋连休三天")
        let publishedNational = countdown("2026-09-28")
        expect(publishedNational.phrase == "距国庆节还有 3 天", "中秋过后接国庆：\(publishedNational.phrase)")
        expect(publishedNational.dateLabel == "10.1 - 10.7 · 休 7 天", "国庆连休七天：\(publishedNational.dateLabel)")
        // 2025 年中秋（10.6）并进国庆，不再单列一段
        expect(day("2025-10-06").holiday == "国庆节", "2025 中秋并进国庆")
        expect(!ChineseCalendarInfo.holidays(inYear: 2025).contains { $0.name == "中秋节" }, "被连休盖住的法定中秋让位")
        // 跨年的元旦两边年份都认，倒计时不重复
        expect(day("2025-12-31").holiday == "元旦" && day("2026-01-02").holiday == "元旦", "跨年元旦")
        let newYear = countdown("2025-12-20")
        expect(newYear.dateLabel == "12.31 - 1.2 · 休 3 天", "跨年元旦报整段：\(newYear.dateLabel)")
        // 服务端没给的节日照旧按法定算
        expect(day("2026-05-02").holiday == "劳动节" && day("2026-05-03").holiday == nil, "没下发的劳动节按法定")
        // 清空后退回法定假日
        ChineseCalendarInfo.usePublishedHolidays([])
        expect(day("2026-09-26").holiday == nil, "清空后 9.26 不再是假期")
        expect(countdown("2026-09-28").dateLabel == "10.1 - 10.3 · 休 3 天", "清空后国庆按法定三天")

        // 小组件显示设置：旧版本存的 JSON 缺字段时要按默认值补齐，而不是整份作废
        let legacy = Data("""
        {"showCourseName":true,"showRoom":false,"showTeacher":false,"showTime":true}
        """.utf8)
        let decoded = try! JSONDecoder().decode(ScheduleWidgetDisplayOptions.self, from: legacy)
        expect(!decoded.showRoom && !decoded.showTeacher, "旧设置里的开关要保留")
        expect(decoded.showLunarDate && decoded.showHoliday, "新开关缺字段时用默认值")
        // 旧版本还存着已经去掉的「课后显示」「节假日常驻」，解码时忽略
        let removedFields = Data("""
        {"showCourseName":true,"showRoom":true,"showTeacher":true,"showTime":true,"showHoliday":false,"holidayAlwaysVisible":true,"afterClass":"tomorrow"}
        """.utf8)
        let withRemoved = try! JSONDecoder().decode(ScheduleWidgetDisplayOptions.self, from: removedFields)
        expect(!withRemoved.showHoliday, "带着旧字段的设置照样解得出来")

        // 「明天」跨周：周日晚上的明天在下一周里
        func course(_ name: String) -> WidgetCourse {
            WidgetCourse(
                name: name, teacher: nil, location: nil, note: nil, slotNote: nil,
                startTime: "08:00", endTime: "09:40", startSlot: 1, endSlot: 2
            )
        }
        func widgetDay(_ date: String, day: Int, week: Int, courses: [WidgetCourse]) -> WidgetDay {
            WidgetDay(day: day, label: "周\(day)", date: date, week: week, isToday: false, courses: courses)
        }
        let sunday = "2026-09-20"
        let monday = "2026-09-21"
        let payload = WidgetSchedulePayload(
            title: nil, sourceLabel: nil, generatedAt: nil, semester: nil, currentWeek: 4,
            today: widgetDay(sunday, day: 7, week: 4, courses: []),
            days: nil,
            weekDays: [widgetDay(sunday, day: 7, week: 4, courses: [])],
            nextWeekDays: [widgetDay(monday, day: 1, week: 5, courses: [course("有机化学")])]
        )
        let sundayDate = ChineseCalendarInfo.date(fromDate: sunday)!
        let tomorrow = payload.knownDay(for: monday)
        expect(tomorrow?.courseList.first?.displayName == "有机化学", "跨周取到的是下一周的课")
        expect(payload.knownDay(for: "2026-09-28") == nil, "没同步到的日期返回 nil")

        // 放学后：今天的课全部结束，upcoming 为空，明天的数据要拿得到
        func moment(_ date: String, hour: Int) -> Date {
            var components = DateComponents()
            let pieces = date.split(separator: "-").compactMap { Int($0) }
            components.year = pieces[0]
            components.month = pieces[1]
            components.day = pieces[2]
            components.hour = hour
            return ChineseCalendarInfo.gregorian.date(from: components)!
        }
        let thursday = "2026-09-17"
        let friday = "2026-09-18"
        let schoolDay = WidgetSchedulePayload(
            title: nil, sourceLabel: nil, generatedAt: nil, semester: nil, currentWeek: 4,
            today: widgetDay(thursday, day: 4, week: 4, courses: [course("药剂学")]),
            days: nil,
            weekDays: [
                widgetDay(thursday, day: 4, week: 4, courses: [course("药剂学")]),
                widgetDay(friday, day: 5, week: 4, courses: [course("有机化学")]),
            ],
            nextWeekDays: nil
        )
        expect(!schoolDay.upcoming(now: moment(thursday, hour: 8)).1.isEmpty, "上课时间还有课")
        expect(schoolDay.remainingCourses(in: schoolDay.currentDay(now: moment(thursday, hour: 18)), now: moment(thursday, hour: 18)).isEmpty, "放学后今天没有剩余课程")
        expect(schoolDay.knownDay(for: friday) != nil, "放学后能取到明天")

        // 「接着显示下一次课」：放学后换到下一个有课的日期，中间空着的日子跳过
        let afterSchool = moment(thursday, hour: 18)
        let rolled = schoolDay.upcoming(now: afterSchool)
        expect(rolled.0.date == friday && rolled.1.first?.displayName == "有机化学", "放学后临近课程默认换到明天的课")
        let stayed = schoolDay.upcoming(now: afterSchool, afterClass: .todayOnly)
        expect(stayed.0.date == thursday && stayed.1.isEmpty, "「只看今天」放学后不换日子")
        // 中号两栏的标题靠它区分「当前」和「下一节」
        let first = course("药剂学")
        expect(first.isInProgress(at: 8 * 60 + 30), "上课中")
        expect(!first.isInProgress(at: 7 * 60 + 50) && !first.isInProgress(at: 10 * 60), "课前、课后都不算上课中")
        expect(schoolDay.nextCourseDay(after: moment(thursday, hour: 8))?.day.date == friday, "两日课表右边是今天之后最近有课的一天")
        expect(payload.nextCourseDay(after: sundayDate)?.day.date == monday, "最近有课的一天可以跨到下一周")
        let quietWeek = WidgetSchedulePayload(
            title: nil, sourceLabel: nil, generatedAt: nil, semester: nil, currentWeek: 4,
            today: widgetDay(thursday, day: 4, week: 4, courses: []),
            days: nil,
            weekDays: [widgetDay(thursday, day: 4, week: 4, courses: [])],
            nextWeekDays: nil
        )
        expect(quietWeek.nextCourseDay(after: afterSchool) == nil, "三周内都没课时返回 nil")
        // 长假：下一节课在十三天以后也要找得到；隔了二十二天就不找了。
        // 9.8、9.9 也要在数据里：数据里没有「今天」就是课表过期，不往后找课。
        let longBreak = WidgetSchedulePayload(
            title: nil, sourceLabel: nil, generatedAt: nil, semester: nil, currentWeek: 4,
            today: widgetDay(thursday, day: 4, week: 4, courses: []),
            days: nil,
            weekDays: [
                widgetDay("2026-09-08", day: 2, week: 3, courses: []),
                widgetDay("2026-09-09", day: 3, week: 3, courses: []),
                widgetDay(thursday, day: 4, week: 4, courses: []),
            ],
            nextWeekDays: [
                widgetDay("2026-09-27", day: 7, week: 5, courses: []),
                widgetDay("2026-09-30", day: 3, week: 6, courses: [course("假期后的课")]),
            ]
        )
        let rolledAfterBreak = longBreak.nextCourseDay(after: afterSchool)
        expect(rolledAfterBreak?.day.date == "2026-09-30" && rolledAfterBreak?.offset == 13, "十三天后的课要找得到")
        expect(longBreak.nextCourseDay(after: moment("2026-09-09", hour: 18))?.offset == 21, "隔了二十一天也要找得到")
        expect(longBreak.nextCourseDay(after: moment("2026-09-08", hour: 18)) == nil, "隔了二十二天就不找了")
        expect(ScheduleWidgetAfterClassStyle(rawValue: "nextCourseDay")?.title == "接着显示下一次课", "默认选项的名字")
        expect(ScheduleWidgetAfterClassStyle.allCases == [.nextCourseDay, .todayOnly], "课后只剩两个选项")

        // 旧 payload 没有 nextWeekDays，解码后应为 nil 而不是失败
        let legacyPayload = Data("""
        {"title":"课表","currentWeek":4,"weekDays":[]}
        """.utf8)
        let restored = try! JSONDecoder().decode(WidgetSchedulePayload.self, from: legacyPayload)
        expect(restored.nextWeekDays == nil && restored.currentWeek == 4, "旧 payload 仍可解码")
        expect(restored.knownDay(for: monday) == nil, "旧 payload 查不到明天")

        print("ok")
    }
}
