import SwiftUI

/// 导入时让位、被收起来的课。
///
/// 导入遇到同一时段撞车时用户只能留一节，但另一节不是错的，只是这次没选它。
/// 所以它留在课表里，只是不显示；在这里可以随时改主意，也可以彻底删掉。
struct HiddenCoursesView: View {
    @EnvironmentObject private var store: AppStore
    let tableId: Int

    private var hidden: [Course] { store.hiddenCourses(inTable: tableId) }

    var body: some View {
        Form {
            Section {
                if hidden.isEmpty {
                    Text("这张课表没有收起来的课。")
                        .foregroundStyle(.secondary)
                }
                ForEach(hidden) { course in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(course.name)
                            Text(slotText(course))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(WeekSeries.summary(course.weeks))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("恢复") { store.setCourse(id: course.id, hidden: false) }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) { store.deleteCourse(id: course.id) }
                    }
                }
            } footer: {
                Text("恢复之后这节课会回到原来的时段，和当初让位的那节并排显示。左滑可以彻底删掉。")
            }
        }
        .navigationTitle("收起的课程")
        .appInlineNavigationTitle()
    }

    private func slotText(_ course: Course) -> String {
        guard !course.isFreeTime else { return "自由时间" }
        let day = WeekCalculator.weekdayName(course.weekTime)
        return course.startTime == course.endTime
            ? "\(day) 第\(course.startTime)节"
            : "\(day) 第\(course.startTime)-\(course.endTime)节"
    }
}
