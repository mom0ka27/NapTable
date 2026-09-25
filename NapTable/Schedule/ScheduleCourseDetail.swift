import SwiftUI

struct SharedCourseDetailView: View {
    let course: NativeScheduleCourse
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("课程", value: course.name)
                LabeledContent("老师", value: course.teacher ?? "—")
                LabeledContent("地点", value: course.location ?? "—")
                LabeledContent("周次", value: course.weeks)
                LabeledContent("备注", value: course.slotNote ?? "—")
                Text("共享课表只读").foregroundStyle(.secondary)
            }
            .navigationTitle("课程详情")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}
