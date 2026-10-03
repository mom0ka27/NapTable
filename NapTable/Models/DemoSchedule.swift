import Foundation

/// 首次使用时可主动导入的示例；以导入当天所在周为第一周。
nonisolated enum DemoSchedule {
    static let weekCount = 16

    static func make(referenceDate: Date = Date()) -> ImportedSchedule {
        let everyWeek = WeekSeries.full(from: 1, to: weekCount)

        func meeting(
            _ name: String, day: Int, start: Int,
            classroom: String, teacher: String,
            weeks: [Int]? = nil, info: String? = nil
        ) -> Course {
            Course(
                tableId: 0, name: name, weeks: weeks ?? everyWeek,
                weekTime: day, startTime: start, timeCount: 1,
                importType: ImportKind.manual,
                classroom: classroom, teacher: teacher, info: info
            )
        }

        return ImportedSchedule(
            name: "示例课表",
            courses: [
                meeting("数据结构", day: 1, start: 1, classroom: "教学楼 A101", teacher: "陈老师"),
                meeting("计算机组成原理", day: 1, start: 5, classroom: "教学楼 A203", teacher: "李老师"),
                meeting("操作系统", day: 2, start: 3, classroom: "教学楼 B201", teacher: "王老师"),
                meeting("数据库原理", day: 3, start: 1, classroom: "教学楼 B102", teacher: "刘老师"),
                meeting("计算机网络", day: 4, start: 3, classroom: "教学楼 A302", teacher: "张老师"),
                meeting("算法设计与分析", day: 5, start: 1, classroom: "教学楼 B203", teacher: "周老师"),
                meeting(
                    "数据结构实验", day: 3, start: 5, classroom: "计算机实验室 301", teacher: "陈老师",
                    weeks: WeekSeries.single(from: 1, to: weekCount),
                    info: "单周上课。切换到双周，同一时段会显示「操作系统实验」。"
                ),
                meeting(
                    "操作系统实验", day: 3, start: 5, classroom: "计算机实验室 301", teacher: "王老师",
                    weeks: WeekSeries.double(from: 1, to: weekCount),
                    info: "双周上课，与「数据结构实验」交替使用同一时段。"
                ),
                meeting(
                    "人工智能专题", day: 4, start: 7, classroom: "研讨室 C205", teacher: "赵老师",
                    weeks: [1, 4, 8, 12, 16],
                    info: "指定周次示例：仅在第 1、4、8、12、16 周安排专题讨论。"
                ),
                Course(
                    tableId: 0, name: "软件工程实践", weeks: everyWeek,
                    weekTime: 0, startTime: 0, timeCount: 0,
                    importType: ImportKind.manual,
                    classroom: "创新实践中心 / 线上协作", teacher: "孙老师",
                    info: "自由时间课程，没有固定星期和节次。小组自行安排项目开发，可从课表上方的自由时间课程入口查看。"
                )
            ],
            classTimeList: SchoolDefaults.classTimeList,
            semesterStartMonday: WeekCalculator.format(WeekCalculator.monday(of: referenceDate))
        )
    }
}

extension AppStore {
    @discardableResult
    func installDemoSchedule(referenceDate: Date = Date()) -> CourseTable {
        let table = install(payload: DemoSchedule.make(referenceDate: referenceDate), mode: .newTable)
        updateWeekCount(DemoSchedule.weekCount, tableId: table.id)
        // 示例始终展示排课，避免导入当天恰逢假期而看到空课表。
        setUnifiedHolidaysEnabled(false, tableId: table.id)
        return tables.first { $0.id == table.id } ?? table
    }
}
