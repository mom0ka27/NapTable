import SwiftUI

/// Keep the native editor's identity byte-for-byte compatible with Web's
/// `courseEditKey`. The bridge does not have to send a source key for every
/// untouched official course, so deriving the key here is what makes hiding or
/// editing one of those courses replace the original instead of duplicating it.
func nativeCourseEditKey(day: Int, bigSlot: Int, course: NativeScheduleCourse) -> String {
    if let sourceKey = course.sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceKey.isEmpty {
        return sourceKey
    }
    func part(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
    return [
        "jwxt", String(day), String(bigSlot),
        course.startSlot.map(String.init) ?? "",
        course.endSlot.map(String.init) ?? "",
        part(course.name), part(course.teacher), part(course.location), part(course.weeks),
    ].joined(separator: "|")
}

/// 课表长按与设置列表共用同一个本地课程编辑器。
struct NativeCourseEditorSheet: View {
    let selection: SelectedCourse?
    @ObservedObject var store: NativeScheduleStore
    var defaultDay = 1
    var defaultWeek = 1
    var defaultStartSlot = 1
    @EnvironmentObject private var app: AppStore

    private var original: Course? {
        guard let id = selection?.course.customId,
              let rowID = Int(id.replacingOccurrences(of: "course:", with: "")) else { return nil }
        return app.courses.first { $0.id == rowID }
    }

    var body: some View {
        if store.isReadOnly {
            Text("共享课表只读")
        } else if selection != nil && original == nil {
            Text("课程已不存在，请关闭后重新打开")
        } else {
            CourseScheduleEditorSheet(
                tableID: original?.tableId ?? app.selectedTableId,
                courses: original.map { app.courseFamily(containing: $0) } ?? [],
                alternatives: original.map { app.coursesInTimeRange(of: $0) } ?? [],
                defaultDay: defaultDay,
                defaultWeek: defaultWeek,
                defaultSlot: defaultStartSlot
            )
        }
    }
}

struct CourseScheduleEditorSheet: View {
    let tableID: Int
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drafts: [CourseScheduleDraft]
    @State private var selectedIndex = 0
    @State private var deletedIDs: Set<Int> = []
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    @State private var meetingToRemove: UUID?
    @ScaledMetric(relativeTo: .body) private var noteEditorHeight: CGFloat = 160

    init(tableID: Int, courses: [Course], alternatives: [[Course]] = [], defaultDay: Int = 1, defaultWeek: Int = 1, defaultSlot: Int = 1) {
        self.tableID = tableID
        let otherFamilies = alternatives.filter { family in
            !family.contains { row in courses.contains { $0.id == row.id } }
        }
        _drafts = State(initialValue: ([courses] + otherFamilies).map { family in
            CourseScheduleDraft(courses: family, defaultDay: defaultDay, defaultWeek: defaultWeek, defaultSlot: defaultSlot)
        })
    }

    private var draft: CourseScheduleDraft {
        get { drafts.indices.contains(selectedIndex) ? drafts[selectedIndex] : CourseScheduleDraft(courses: []) }
        nonmutating set { if drafts.indices.contains(selectedIndex) { drafts[selectedIndex] = newValue } }
    }
    private var draftBinding: Binding<CourseScheduleDraft> {
        Binding(get: { draft }, set: { draft = $0 })
    }

    private func meetingBinding(for initialMeeting: CourseScheduleMeeting) -> Binding<CourseScheduleMeeting> {
        let draftIndex = selectedIndex
        return Binding(
            get: {
                guard drafts.indices.contains(draftIndex) else { return initialMeeting }
                // 移除动画期间，旧行的控件仍可能读取绑定；此时保留最后显示的值。
                return drafts[draftIndex].meetings.first { $0.id == initialMeeting.id } ?? initialMeeting
            },
            set: { value in
                guard drafts.indices.contains(draftIndex),
                      let index = drafts[draftIndex].meetings.firstIndex(where: { $0.id == initialMeeting.id }) else { return }
                drafts[draftIndex].meetings[index] = value
            }
        )
    }

    private var table: CourseTable? { app.tables.first { $0.id == tableID } }
    private var weekCount: Int { table.map(app.weekCount(of:)) ?? app.maxWeeks }
    private var slotCount: Int {
        max(SchoolDefaults.maxClasses, table?.effectiveClassTimeList.count ?? 0,
            table?.effectiveSeasonalPeriods?.map { $0.periods.count }.max() ?? 0)
    }
    private var hasOverlappingCourses: Bool {
        app.hasCourseOverlap(in: drafts, selectedIndex: selectedIndex, tableID: tableID, deleting: deletedIDs)
    }

    private var priorityRank: Int {
        max(app.courses.filter { $0.tableId == tableID }.compactMap(\.displayPriority).max() ?? 0,
            drafts.compactMap(\.displayPriority).max() ?? 0)
    }
    private var isPreferred: Bool { (draft.displayPriority ?? 0) > 0 && draft.displayPriority == drafts.compactMap(\.displayPriority).max() }

    var body: some View {
        NavigationStack {
            Form {
                if drafts.count > 1 {
                    Section {
                        Picker("编辑课程", selection: $selectedIndex) {
                            ForEach(drafts.indices, id: \.self) { index in
                                Text(courseLabel(at: index)).tag(index)
                            }
                        }
                        .pickerStyle(.menu)
                    } footer: {
                        Text("同一时段共 \(drafts.count) 门课程，包含其他周次和已收起的安排。切换会保留修改，点保存一起生效。")
                    }
                }
                if !drafts.isEmpty {
                    Section("课程信息") {
                        CourseIdentityFields(name: draftBinding.name, teacher: draftBinding.teacher)
                        if hasOverlappingCourses {
                            Button {
                                draft.displayPriority = priorityRank < Int.max ? priorityRank + 1 : priorityRank
                            } label: {
                                Label(isPreferred ? "当前优先显示" : "优先显示这门课", systemImage: isPreferred ? "checkmark.circle.fill" : "circle")
                            }
                            .disabled(isPreferred)
                        }
                    }
                    ForEach(draft.meetings) { initialMeeting in
                        let meetingID = initialMeeting.id
                        let meeting = meetingBinding(for: initialMeeting)
                        Section {
                            LabeledContent("教室") {
                                TextField("教室", text: meeting.classroom, prompt: Text("选填"))
                                    .multilineTextAlignment(.trailing)
                                    .accessibilityLabel("教室，选填")
                            }
                            Toggle("自由时间", isOn: meeting.isFreeTime)
                            if !meeting.wrappedValue.isFreeTime {
                                Picker("星期", selection: meeting.day) {
                                    ForEach(1...7, id: \.self) { day in
                                        Text(WeekCalculator.weekdayName(day)).tag(day)
                                    }
                                }
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("上课周次").font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Menu("快捷选择") {
                                        Button("全部周") { meeting.weeks.wrappedValue = Set(1...weekCount) }
                                        Button("单周") { meeting.weeks.wrappedValue = Set((1...weekCount).filter { $0 % 2 == 1 }) }
                                        Button("双周") { meeting.weeks.wrappedValue = Set((1...weekCount).filter { $0 % 2 == 0 }) }
                                        Button("清空") { meeting.weeks.wrappedValue = [] }
                                    }
                                    .font(.caption)
                                }
                                numberPicker(values: Array(1...weekCount), selection: meeting.weeks, unit: "周")
                            }
                            .padding(.vertical, 6)
                            if !meeting.wrappedValue.isFreeTime {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("上课节次").font(.subheadline.weight(.semibold))
                                    numberPicker(values: Array(1...slotCount), selection: meeting.slots, unit: "节")
                                }
                                .padding(.vertical, 6)
                            }
                            Toggle("隐藏这组安排", isOn: meeting.hidden)
                            if draft.meetings.count > 1 {
                                Button("移除这组安排", role: .destructive) {
                                    meetingToRemove = meetingID
                                }
                                // 确认框跟随触发按钮；按稳定 ID 移除，避免动画期间读取已删除的绑定。
                                .confirmationDialog(
                                    "移除这组上课安排？",
                                    isPresented: Binding(
                                        get: { meetingToRemove == meetingID },
                                        set: { if !$0 && meetingToRemove == meetingID { meetingToRemove = nil } }
                                    ),
                                    titleVisibility: .visible
                                ) {
                                    Button("移除", role: .destructive) {
                                        guard draft.meetings.count > 1 else { return }
                                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                                            draft.meetings.removeAll { $0.id == meetingID }
                                        }
                                        meetingToRemove = nil
                                    }
                                    Button("取消", role: .cancel) { meetingToRemove = nil }
                                } message: {
                                    Text("只移除这组安排，其他安排保留。点「保存」后生效。")
                                }
                            }
                        } header: {
                            Text("上课安排 \(arrangementNumber(meetingID))")
                        } footer: {
                            Text("可选择多个周次和节次。不同周的节次不同，可添加另一组安排。")
                        }
                    }
                    Section {
                        Button {
                            var meeting = CourseScheduleMeeting(day: 1, weeks: Set(1...weekCount), slots: [1, 2])
                            meeting.classroom = draft.meetings.last?.classroom ?? ""
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                                draft.meetings.append(meeting)
                            }
                        } label: {
                            Label("添加上课安排", systemImage: "plus.circle")
                        }
                    }
                }
                if !deletedIDs.isEmpty {
                    Section { Text("已移除的课程将在保存后删除。").font(.caption).foregroundStyle(.secondary) }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                if !drafts.isEmpty {
                    Section {
                        TextEditor(text: draftBinding.note)
                            .font(.body)
                            .frame(height: noteEditorHeight)
                            .scrollContentBackground(.hidden)
                            .overlay(alignment: .topLeading) {
                                if draft.note.isEmpty {
                                    Text("记录作业、考试安排或课堂提醒…")
                                        .font(.body)
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 8)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.vertical, 4)
                            .accessibilityLabel("备注（选填）")
                    } header: {
                        HStack {
                            Text("备注")
                            Spacer()
                            Text("选填")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .appListBackground()
            .appSoftTopScrollEdge()
            .onChange(of: selectedIndex) { _, _ in meetingToRemove = nil }
            .navigationTitle(!drafts.isEmpty && draft.originals.isEmpty ? "添加课程" : "编辑课程")
                .appInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label("取消", systemImage: "xmark").labelStyle(.iconOnly)
                    }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if !draft.originals.isEmpty {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("删除课程", systemImage: "trash").labelStyle(.iconOnly)
                        }
                        .tint(.red)
                        .confirmationDialog("删除这门课的全部上课安排？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                            Button("删除", role: .destructive) {
                                deletedIDs.formUnion(draft.originals.map(\.id))
                                drafts.remove(at: selectedIndex)
                                selectedIndex = min(selectedIndex, max(0, drafts.count - 1))
                            }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("只移除当前课程，其他课程的修改保留；点保存后生效。")
                        }
                    }
                    Button { saveAll() } label: {
                        Label("保存", systemImage: "checkmark").labelStyle(.iconOnly)
                    }
                }
            }
        }
    }

    private func saveAll() {
        do {
            try app.saveCourseSchedules(drafts, tableID: tableID, deleting: deletedIDs)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func courseLabel(at index: Int) -> String {
        let value = drafts[index]
        let room = value.meetings.first?.classroom ?? ""
        let weeks = WeekSeries.summary(Array(value.meetings.first?.weeks ?? []))
        return "\(index + 1). \(value.name)" + (room.isEmpty ? "" : " · \(room)") + " · \(weeks)"
    }

    private func arrangementNumber(_ id: UUID) -> Int {
        (draft.meetings.firstIndex { $0.id == id } ?? 0) + 1
    }

    private func numberPicker(values: [Int], selection: Binding<Set<Int>>, unit: String) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 8) {
            ForEach(values, id: \.self) { value in
                let selected = selection.wrappedValue.contains(value)
                Button {
                    if selected { selection.wrappedValue.remove(value) }
                    else { selection.wrappedValue.insert(value) }
                } label: {
                    Text("\(value)\(unit)")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundStyle(selected ? Color.cpuBrand : .secondary)
                        .background(selected ? Color.cpuBrand.opacity(0.14) : Color.appSecondaryGroupedBackground,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selected ? Color.cpuBrand : Color.appSeparator.opacity(0.4), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("第 \(value) \(unit)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// 新增与编辑课程共用：固定标签在上，输入内容放在独立输入框内。
struct CourseIdentityFields: View {
    @Binding var name: String
    @Binding var teacher: String
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case name, teacher }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            input("课程名称", requirement: "必填", text: $name, field: .name)
            input("教师", requirement: "选填", text: $teacher, field: .teacher)
        }
        .padding(.vertical, 8)
    }

    private func input(
        _ title: String, requirement: String,
        text: Binding<String>, field: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(requirement)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)

            TextField(title, text: text, prompt: Text(""))
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .focused($focusedField, equals: field)
                .submitLabel(field == .name ? .next : .done)
                .onSubmit { focusedField = field == .name ? .teacher : nil }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            focusedField == field ? Color.cpuBrand : Color.appSeparator.opacity(0.55),
                            lineWidth: focusedField == field ? 1.5 : 1
                        )
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("\(title)，\(requirement)")
        }
    }
}
