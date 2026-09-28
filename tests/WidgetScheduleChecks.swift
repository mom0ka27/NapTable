import Foundation

/// 小组件数据模型里「今天」的判断：寒暑假、课表过期、刷新边界。
///
/// 只编译 WidgetCore，不需要模拟器：`tests/check-widget-schedule.sh`
@main
struct WidgetScheduleChecks {
    static func main() {
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            guard condition else {
                FileHandle.standardError.write(Data("FAIL: \(message())\n".utf8))
                exit(1)
            }
        }
        func moment(_ date: String, hour: Int = 12, minute: Int = 0) -> Date {
            let pieces = date.split(separator: "-").compactMap { Int($0) }
            var components = DateComponents()
            (components.year, components.month, components.day, components.hour, components.minute) =
                (pieces[0], pieces[1], pieces[2], hour, minute)
            return ChineseCalendarInfo.gregorian.date(from: components)!
        }
        func course(_ name: String, start: String = "08:00", end: String = "09:40") -> WidgetCourse {
            WidgetCourse(name: name, teacher: nil, location: nil, note: nil, slotNote: nil,
                         startTime: start, endTime: end, startSlot: 1, endSlot: 2)
        }
        func day(_ date: String, courses: [WidgetCourse] = []) -> WidgetDay {
            let empty = WidgetDay.empty(date: date, offset: 0)
            return WidgetDay(day: empty.day, label: empty.label, date: date, week: 1, isToday: false, courses: courses)
        }
        func payload(
            today: WidgetDay?,
            weekDays: [WidgetDay]? = nil,
            nextWeekDays: [WidgetDay]? = nil,
            termStart: String? = nil,
            weeks: Int? = nil
        ) -> WidgetSchedulePayload {
            WidgetSchedulePayload(
                title: nil, sourceLabel: nil, generatedAt: nil, semester: nil, currentWeek: 1,
                today: today, days: nil, weekDays: weekDays, nextWeekDays: nextWeekDays,
                termStart: termStart, termWeeks: weeks
            )
        }

        // MARK: 寒暑假

        // 秋季学期（2026-08-31 起 20 周）结束之后是寒假
        let autumn = payload(today: day("2027-01-25"), termStart: "2026-08-31", weeks: 20)
        expect(autumn.termRange?.end == "2027-01-17", "秋季学期最后一天：\(autumn.termRange?.end ?? "nil")")
        expect(autumn.vacation(on: "2027-01-25")?.kind == .winter, "秋季学期结束后是寒假")
        expect(autumn.vacation(on: "2027-01-25")?.title == "寒假ing", "寒假文案")
        expect(autumn.vacation(on: "2026-12-01") == nil, "学期内不是假期")

        // 春季学期（2027-02-22 起 18 周）结束之后是暑假
        let spring = payload(today: day("2027-07-05"), termStart: "2027-02-22", weeks: 18)
        expect(spring.vacation(on: "2027-07-05")?.kind == .summer, "春季学期结束后是暑假")
        expect(spring.vacation(on: "2027-07-05")?.title == "暑假ing", "暑假文案")

        // 学期还没开始：春季学期（3 月开学）之前是寒假，寒假里能报开学倒计时
        let beforeSpring = payload(today: day("2027-02-20"), termStart: "2027-03-01", weeks: 18)
        expect(beforeSpring.vacation(on: "2027-02-20")?.kind == .winter, "春季学期开学前还是寒假")
        expect(beforeSpring.vacation(on: "2027-02-20")?.countdown == "距开学还有 9 天",
               "开学倒计时：\(beforeSpring.vacation(on: "2027-02-20")?.countdown ?? "nil")")
        // 秋季学期（9 月开学）之前是暑假
        let beforeAutumn = payload(today: day("2026-08-20"), termStart: "2026-09-07", weeks: 20)
        expect(beforeAutumn.vacation(on: "2026-08-20")?.kind == .summer, "秋季学期开学前是暑假")
        // 已经结束的学期不知道下学期什么时候开学，没有倒计时
        expect(autumn.vacation(on: "2027-01-25")?.countdown == nil, "学期结束后没有开学倒计时")

        // 期末和开学之间隔太远（几个月没打开 App）就不看学期，按月份判断
        let longGone = payload(today: day("2027-07-20"), termStart: "2026-08-31", weeks: 20)
        expect(longGone.vacation(on: "2027-07-20")?.kind == .summer, "离学期半年按月份算暑假（学期看会说寒假）")
        let odd = payload(today: day("2027-04-20"), termStart: "2027-04-01", weeks: 4)
        expect(odd.vacation(on: "2027-05-20")?.kind == .other, "月份和学期都说不清时只说放假")
        expect(odd.vacation(on: "2027-05-20")?.title == "放假ing", "说不清时的文案")

        // 没有学期信息：不判断放假，老老实实按数据里的日子显示
        let noTerm = payload(today: day("2027-01-25"), weekDays: [day("2027-01-25", courses: [course("药剂学")])])
        expect(noTerm.notice(now: moment("2027-01-25")) == nil, "旧 payload 不判断寒暑假")

        // MARK: 假期里不显示课

        // payload 里恰好有今天（放假前写的最后一周），是假期也不列课
        let holidayWeek = payload(
            today: day("2027-01-25", courses: [course("药剂学")]),
            weekDays: [day("2027-01-25", courses: [course("药剂学")]), day("2027-01-26", courses: [course("药物化学")])],
            termStart: "2026-08-31", weeks: 20
        )
        let holidayNow = moment("2027-01-25")
        expect(holidayWeek.notice(now: holidayNow) == .vacation(WidgetVacation(kind: .winter, daysUntilTerm: nil)),
               "假期里照旧报假期")
        expect(holidayWeek.currentDay(now: holidayNow).courseList.isEmpty, "假期里今天是空的")
        expect(holidayWeek.nextCourseDay(after: holidayNow) == nil, "假期里不往后找课")
        expect(holidayWeek.remainingCourses(in: holidayWeek.currentDay(now: holidayNow), now: holidayNow).isEmpty,
               "假期里没有剩余课程")

        // MARK: 课表过期

        // 学期内，但数据里没有今天：提示更新，也不按星期几挑别的周
        let staleDays = [day("2026-09-14", courses: [course("药剂学")]), day("2026-09-15", courses: [course("药物化学")])]
        let stale = payload(today: day("2026-09-14", courses: [course("药剂学")]), weekDays: staleDays,
                            termStart: "2026-08-31", weeks: 20)
        // 2026-10-19 是周一，数据里的周一在五周前
        let staleNow = moment("2026-10-19", hour: 9)
        expect(stale.notice(now: staleNow) == .stale, "学期内没有今天就是过期")
        expect(stale.currentDay(now: staleNow).courseList.isEmpty, "过期时今天是空的")
        expect(stale.fullDay(for: "2026-10-19", fallbackOffset: 0).courseList.isEmpty, "过期时不再按星期几挑课")
        expect(stale.nextCourseDay(after: staleNow) == nil, "过期时不往后找课")

        // 旧版 payload 没有 date：照旧按星期几匹配
        let legacy = WidgetSchedulePayload(
            title: nil, sourceLabel: nil, generatedAt: nil, semester: nil, currentWeek: 4,
            today: nil, days: [
                WidgetDay(day: 1, label: "周一", date: nil, week: 4, isToday: false, courses: [course("药剂学")]),
            ], weekDays: nil, nextWeekDays: nil
        )
        expect(!legacy.hasDatedDays, "只有星期几的 payload 认得出")
        expect(legacy.notice(now: staleNow) == nil, "旧 payload 不说过期")
        expect(legacy.fullDay(for: "2026-10-19", fallbackOffset: 0).courseList.count == 1, "旧 payload 仍按星期几挑课")

        // MARK: 刷新边界

        let boundary = payload(
            today: day("2026-09-14", courses: [course("药剂学", start: "08:00", end: "09:40"), course("药物化学", start: "10:00", end: "11:40")]),
            termStart: "2026-08-31", weeks: 20
        )
        // 下课那一分钟里课还没结束，刷新要排在下课边界之后，不能漏掉这一下
        let inLastMinute = boundary.nextRefreshBoundary(now: moment("2026-09-14", hour: 9, minute: 40))
        expect(inLastMinute > moment("2026-09-14", hour: 9, minute: 40), "下课那一分钟里的刷新排在将来")
        expect(inLastMinute == moment("2026-09-14", hour: 9, minute: 41), "下课边界后一分钟刷新")
        let afterEnd = boundary.nextRefreshBoundary(now: moment("2026-09-14", hour: 9, minute: 41))
        expect(afterEnd == moment("2026-09-14", hour: 10, minute: 1), "下课边界后刷新排到下一节课开始")
        let between = boundary.nextRefreshBoundary(now: moment("2026-09-14", hour: 9, minute: 45))
        expect(between == moment("2026-09-14", hour: 10, minute: 1), "课间刷新排到下一节课开始")
        let afterAll = boundary.nextRefreshBoundary(now: moment("2026-09-14", hour: 12))
        expect(afterAll == moment("2026-09-15", hour: 0, minute: 1), "课上完了排到次日零点")
        // 假期里不按假课排，也是次日零点
        let vacationBoundary = holidayWeek.nextRefreshBoundary(now: holidayNow)
        expect(vacationBoundary == moment("2027-01-26", hour: 0, minute: 1), "假期里排到次日零点")

        print("ok")
    }
}
