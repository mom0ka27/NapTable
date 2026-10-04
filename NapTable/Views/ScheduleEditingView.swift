import SwiftUI

/// 设置中的完整课程列表，非本周和已收起的安排也能编辑。
struct ScheduleEditingView: View {
    @EnvironmentObject private var app: AppStore
    let tableID: Int
    @State private var selectedCourse: Course?
    @State private var addingCourse = false
    @State private var search = ""

    private var rows: [Course] { app.courses.filter { $0.tableId == tableID } }
    private var families: [[Course]] {
        var seen = Set<String>()
        return rows.compactMap { course in
            let key = course.courseKey.map { "family:\($0)" } ?? "row:\(course.id)"
            guard seen.insert(key).inserted else { return nil }
            return app.courseFamily(containing: course)
        }
        .filter { search.isEmpty || $0.contains { course in
            course.name.localizedCaseInsensitiveContains(search)
                || (course.teacher ?? "").localizedCaseInsensitiveContains(search)
                || (course.classroom ?? "").localizedCaseInsensitiveContains(search)
        } }
        .sorted { ($0.first?.name ?? "", $0.first?.id ?? 0) < ($1.first?.name ?? "", $1.first?.id ?? 0) }
    }

    var body: some View {
        List {
            if let table = app.tables.first(where: { $0.id == tableID }) {
                Section {
                    Text(table.name)
                } footer: {
                    Text("同名课程归为一门课，保留所有上课安排。点课程可编辑不同周次的节次。")
                }
                Section {
                    if families.isEmpty {
                        Text(search.isEmpty ? "这张课表还没有课程。" : "没有找到课程。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(families, id: \.[0].id) { family in
                        if let course = family.first {
                            Button { selectedCourse = course } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(course.name).foregroundStyle(.primary)
                                        Spacer()
                                        if family.contains(where: { ($0.displayPriority ?? 0) > 0 })
                                            && app.hasCourseOverlap(in: [CourseScheduleDraft(courses: family)], selectedIndex: 0, tableID: tableID) {
                                            Text("优先显示").font(.caption).foregroundStyle(Color.cpuBrand)
                                        }
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }
                                    ForEach(family) { row in
                                        Text(summary(row))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("\(families.count) 门课程 · \(families.reduce(0) { $0 + $1.count }) 条安排")
                }
            } else {
                Text("这张课表已删除。")
                    .foregroundStyle(.secondary)
            }
        }
        .appListBackground()
        .navigationTitle("编辑课表")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
        .searchable(text: $search, prompt: "搜索课程、教师或教室")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addingCourse = true } label: {
                    Label("添加课程", systemImage: "plus")
                }
                .disabled(!app.tables.contains { $0.id == tableID })
            }
        }
        .sheet(item: $selectedCourse) { course in
            CourseScheduleEditorSheet(tableID: course.tableId, courses: app.courseFamily(containing: course),
                                      alternatives: app.coursesInTimeRange(of: course))
                .appSheetDetents([.large])
                .appDragIndicatorVisible()
        }
        .sheet(isPresented: $addingCourse) {
            CourseScheduleEditorSheet(tableID: tableID, courses: [])
                .appSheetDetents([.large])
                .appDragIndicatorVisible()
        }
    }

    private func summary(_ course: Course) -> String {
        let time = course.isFreeTime ? "自由时间"
            : "\(WeekCalculator.weekdayName(course.weekTime)) 第\(course.startTime)-\(course.endTime)节"
        return [WeekSeries.summary(course.weeks), time, course.classroom ?? "", course.isHidden ? "已收起" : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
