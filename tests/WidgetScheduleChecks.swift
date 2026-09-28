import Foundation

/// 小组件数据模型里「今天」的判断：寒暑假、课表过期、时间线条目。
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

        // 旧 payload 的星期几按要找的日期本身算，不看真实的今天：零点那一条画的是明天
        let legacyWeek = WidgetSchedulePayload(
            title: nil, sourceLabel: nil, generatedAt: nil, semester: nil, currentWeek: 4,
            today: nil, days: [
                WidgetDay(day: 1, label: "周一", date: nil, week: 4, isToday: false, courses: [course("药剂学")]),
                WidgetDay(day: 2, label: "周二", date: nil, week: 4, isToday: false, courses: [course("药物化学")]),
            ], weekDays: nil, nextWeekDays: nil
        )
        expect(legacyWeek.fullDay(for: "2026-10-20", fallbackOffset: 0).courseList.first?.name == "药物化学",
               "旧 payload 按日期本身的星期几挑课")

        // MARK: 时间线条目

        func clock(_ dates: [Date]) -> String {
            let formatter = DateFormatter()
            formatter.timeZone = ChineseCalendarInfo.timeZone
            formatter.dateFormat = "MM-dd HH:mm:ss"
            return dates.map { formatter.string(from: $0) }.joined(separator: ", ")
        }
        let school = payload(
            today: day("2026-09-14", courses: [
                course("药剂学", start: "08:00", end: "09:40"),
                course("药物化学", start: "10:00", end: "11:40"),
                course("药理学", start: "14:00", end: "15:40"),
            ]),
            weekDays: [
                day("2026-09-14", courses: [
                    course("药剂学", start: "08:00", end: "09:40"),
                    course("药物化学", start: "10:00", end: "11:40"),
                    course("药理学", start: "14:00", end: "15:40"),
                ]),
                day("2026-09-15", courses: [course("生药学", start: "08:00", end: "09:40")]),
            ],
            termStart: "2026-08-31", weeks: 20
        )
        let midnight = moment("2026-09-15", hour: 0)
        let tomorrowBoundaries = [moment("2026-09-15", hour: 8), moment("2026-09-15", hour: 9, minute: 41)]

        // 早上生成：现在一条，每节课开始、下课后一分钟各一条，零点一条，再带上明天的上下课
        let morningNow = moment("2026-09-14", hour: 7, minute: 12)
        let morning = school.timelinePlan(from: morningNow)
        let expectedMorning = [
            morningNow,
            moment("2026-09-14", hour: 8), moment("2026-09-14", hour: 9, minute: 41),
            moment("2026-09-14", hour: 10), moment("2026-09-14", hour: 11, minute: 41),
            moment("2026-09-14", hour: 14), moment("2026-09-14", hour: 15, minute: 41),
            midnight,
        ] + tomorrowBoundaries
        expect(morning.dates == expectedMorning, "早上的条目：\(clock(morning.dates))")
        expect(morning.reload == midnight, "次日零点再要新的时间线：\(clock([morning.reload]))")
        // 条目按这些时刻画出来的样子确实在变：开始那一分钟算上课中，下课后一分钟才算上完
        let first = school.today!.courseList[0]
        expect(first.isInProgress(at: WidgetSchedulePayload.minutesSinceMidnight(moment("2026-09-14", hour: 8))),
               "8:00 这一条已经是上课中")
        expect(!first.hasEnded(at: WidgetSchedulePayload.minutesSinceMidnight(moment("2026-09-14", hour: 9, minute: 40))),
               "9:40 那一分钟课还没上完")
        expect(first.hasEnded(at: WidgetSchedulePayload.minutesSinceMidnight(moment("2026-09-14", hour: 9, minute: 41))),
               "9:41 这一条课已经上完")

        // 下课那一分钟里生成：下课边界不能丢
        let lastMinuteNow = moment("2026-09-14", hour: 9, minute: 40).addingTimeInterval(30)
        let lastMinute = school.timelinePlan(from: lastMinuteNow)
        expect(lastMinute.dates.first == lastMinuteNow, "第一条是现在")
        expect(lastMinute.dates.dropFirst().first == moment("2026-09-14", hour: 9, minute: 41),
               "下课那一分钟里生成，下一条就是下课后一分钟：\(clock(lastMinute.dates))")
        // 正好在边界上生成：现在这一条就是边界，不再重复
        let onBoundary = school.timelinePlan(from: moment("2026-09-14", hour: 9, minute: 41))
        expect(onBoundary.dates.filter { $0 == moment("2026-09-14", hour: 9, minute: 41) }.count == 1, "边界不重复")
        expect(onBoundary.dates.dropFirst().first == moment("2026-09-14", hour: 10), "边界之后排到下一节课开始")
        // 课上时间生成：这节的开始已经过了，不再排
        let during = school.timelinePlan(from: moment("2026-09-14", hour: 10, minute: 30))
        expect(!during.dates.contains(moment("2026-09-14", hour: 10)), "过去的边界不排")
        expect(during.dates.dropFirst().first == moment("2026-09-14", hour: 11, minute: 41), "课上排到这节下课后")

        // 放学后生成：只剩零点和明天的课
        let evening = school.timelinePlan(from: moment("2026-09-14", hour: 20))
        expect(evening.dates == [moment("2026-09-14", hour: 20), midnight] + tomorrowBoundaries,
               "放学后的条目：\(clock(evening.dates))")

        // 23:59 生成：零点那一条就在一分钟后，刷新也在这个零点，不会跳过一天
        let lateNow = moment("2026-09-14", hour: 23, minute: 59).addingTimeInterval(20)
        let late = school.timelinePlan(from: lateNow)
        expect(late.dates == [lateNow, midnight] + tomorrowBoundaries, "23:59 的条目：\(clock(late.dates))")
        expect(late.reload == midnight, "23:59 生成也在今晚零点刷新")

        // 23:59 下课的课：下课后一分钟就是零点，并进零点那一条
        let nightOwl = payload(
            today: day("2026-09-14", courses: [course("夜观天象", start: "22:00", end: "23:59")]),
            weekDays: [day("2026-09-14", courses: [course("夜观天象", start: "22:00", end: "23:59")]), day("2026-09-15")],
            termStart: "2026-08-31", weeks: 20
        )
        let night = nightOwl.timelinePlan(from: moment("2026-09-14", hour: 21))
        expect(night.dates == [moment("2026-09-14", hour: 21), moment("2026-09-14", hour: 22), midnight],
               "23:59 下课并进零点：\(clock(night.dates))")

        // 放假：只有现在和零点
        let vacationPlan = holidayWeek.timelinePlan(from: holidayNow)
        expect(vacationPlan.dates == [holidayNow, moment("2027-01-26", hour: 0)], "假期只有现在和零点：\(clock(vacationPlan.dates))")
        expect(vacationPlan.reload == moment("2027-01-26", hour: 0), "假期里次日零点刷新")
        // 课表过期：同样只有现在和零点
        let stalePlan = stale.timelinePlan(from: staleNow)
        expect(stalePlan.dates == [staleNow, moment("2026-10-20", hour: 0)], "过期只有现在和零点：\(clock(stalePlan.dates))")

        // 没有具体时间的课不产生边界；只有开始时间的按 45 分钟算下课
        let loose = payload(
            today: day("2026-09-14"),
            weekDays: [
                day("2026-09-14", courses: [
                    WidgetCourse(name: "自习", teacher: nil, location: nil, note: nil, slotNote: nil,
                                 startTime: nil, endTime: nil, startSlot: nil, endSlot: nil),
                    WidgetCourse(name: "讲座", teacher: nil, location: nil, note: nil, slotNote: nil,
                                 startTime: "19:00", endTime: nil, startSlot: nil, endSlot: nil),
                ]),
                day("2026-09-15"),
            ],
            termStart: "2026-08-31", weeks: 20
        )
        let loosePlan = loose.timelinePlan(from: moment("2026-09-14", hour: 18))
        expect(loosePlan.dates == [moment("2026-09-14", hour: 18), moment("2026-09-14", hour: 19),
                                   moment("2026-09-14", hour: 19, minute: 46), midnight],
               "没时间的课不排、只有开始时间的按 45 分钟：\(clock(loosePlan.dates))")

        // 一天的课再多，条目也有数
        let packed = (0..<14).map { index in
            course("第\(index)节", start: String(format: "%02d:00", 7 + index), end: String(format: "%02d:45", 7 + index))
        }
        let busy = payload(today: day("2026-09-14", courses: packed),
                           weekDays: [day("2026-09-14", courses: packed), day("2026-09-15", courses: packed)],
                           termStart: "2026-08-31", weeks: 20)
        let busyPlan = busy.timelinePlan(from: moment("2026-09-14", hour: 0))
        expect(busyPlan.dates.count == 58, "十四节课两天的条目数：\(busyPlan.dates.count)")
        expect(busyPlan.dates == busyPlan.dates.sorted(), "条目按时间排好")

        print("ok")
    }
}
