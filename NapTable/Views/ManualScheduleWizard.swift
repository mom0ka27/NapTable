import SwiftUI

/// 学校不在列表里时的手动创建向导：学期 → 节次 → 课程 → 确认。
///
/// 没有教务系统可读，学期、周数、作息和每门课都得用户自己给，所以按这个顺序一步步问：
/// 课程的节次和周次要用到前两步的结果。所有输入先存在 `ManualScheduleDraft` 里，
/// 最后一步才建表，中途退出什么也不会留下。
struct ManualScheduleWizard: View {
    let school: String?
    /// 首次使用时必须至少有一门课才能进主界面，这时课程这一步不能跳过。
    var requiresCourses = false
    let onCreated: () -> Void

    @EnvironmentObject private var store: AppStore
    @State private var step: Step = .semester
    @State private var draft = ManualScheduleDraft(classTimes: ClassTimeGenerator().make())
    @State private var generator = ClassTimeGenerator()
    @State private var editingCourse: ManualCourseDraft?

    enum Step: Int, CaseIterable {
        case semester, periods, courses, review

        var title: String {
            switch self {
            case .semester: return "学期与周数"
            case .periods: return "节次时间"
            case .courses: return "添加课程"
            case .review: return "确认"
            }
        }
    }

    var body: some View {
        Form {
            switch step {
            case .semester: semesterStep
            case .periods: periodsStep
            case .courses: coursesStep
            case .review: reviewStep
            }
        }
        .navigationTitle(step.title)
        .appInlineNavigationTitle()
        .navigationBarBackButtonHidden(step != .semester)
        .toolbar {
            if let previous = Step(rawValue: step.rawValue - 1) {
                ToolbarItem(placement: .navigation) {
                    Button { withAnimation { step = previous } } label: {
                        Label("上一步", systemImage: "chevron.backward")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .sheet(item: $editingCourse) { course in
            ManualCourseEditor(
                course: course,
                classTimes: draft.classTimes,
                weekCount: draft.weekCount,
                isNew: !draft.courses.contains { $0.id == course.id }
            ) { saved in
                if let index = draft.courses.firstIndex(where: { $0.id == saved.id }) {
                    draft.courses[index] = saved
                } else {
                    draft.courses.append(saved)
                }
            }
        }
        .onAppear {
            if draft.name.isEmpty { draft.name = school.map { "\($0)课表" } ?? "我的课表" }
        }
        .onChange(of: draft.classTimes.count) { _, count in clampMeetings(periodCount: count) }
    }

    // MARK: 底栏

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 3)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("第 \(step.rawValue + 1) 步，共 \(Step.allCases.count) 步，\(step.title)")

            if let blocker {
                Text(blocker)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: advance) {
                Text(primaryTitle)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .disabled(blocker != nil)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var primaryTitle: String {
        switch step {
        case .courses: return draft.courses.isEmpty && !requiresCourses ? "先跳过，稍后再加" : "下一步"
        case .review: return "创建课表"
        default: return "下一步"
        }
    }

    /// 当前这一步还不能往下走的原因。
    private var blocker: String? {
        switch step {
        case .semester:
            return draft.trimmedName.isEmpty ? "请填写课表名称" : nil
        case .periods:
            return draft.classTimesProblem
        case .courses, .review:
            return requiresCourses && draft.courses.isEmpty ? "首次使用至少要添加一门课" : nil
        }
    }

    private func advance() {
        guard blocker == nil else { return }
        if let next = Step(rawValue: step.rawValue + 1) {
            withAnimation { step = next }
        } else {
            store.installManualSchedule(draft)
            onCreated()
        }
    }

    // MARK: 1. 学期与周数

    @ViewBuilder
    private var semesterStep: some View {
        Section {
            TextField("课表名称", text: $draft.name)
        } header: {
            Text("课表名称")
        }

        Section {
            DatePicker("第一周的星期一", selection: semesterStartBinding, displayedComponents: .date)
            Stepper(
                "学期总周数：\(draft.weekCount) 周",
                value: $draft.weekCount,
                in: ManualScheduleDraft.weekCountRange
            )
        } header: {
            Text("学期")
        } footer: {
            Text("选哪天都会对齐到那周的星期一，周次从这天开始往后数。\(todayHint)")
        }
    }

    private var semesterStartBinding: Binding<Date> {
        Binding(
            get: { WeekCalculator.parseDay(draft.semesterStartMonday) ?? WeekCalculator.monday(of: Date()) },
            set: { draft.semesterStartMonday = WeekCalculator.format(WeekCalculator.monday(of: $0)) }
        )
    }

    private var todayHint: String {
        guard let monday = WeekCalculator.parseDay(draft.semesterStartMonday) else { return "" }
        let today = WeekCalculator.monday(of: Date())
        let days = WeekCalculator.calendar.dateComponents([.day], from: monday, to: today).day ?? 0
        let week = days >= 0 ? days / 7 + 1 : 0
        if days < 0 { return "按这个日期，还有 \(-days / 7) 周开学。" }
        if week > draft.weekCount { return "按这个日期，这学期已经结束了。" }
        return "按这个日期，本周是第 \(week) 周。"
    }

    // MARK: 2. 节次时间

    @ViewBuilder
    private var periodsStep: some View {
        Section {
            Stepper("每节课 \(generator.lessonMinutes) 分钟", value: $generator.lessonMinutes, in: 20...180, step: 5)
            Stepper("课间 \(generator.breakMinutes) 分钟", value: $generator.breakMinutes, in: 0...60, step: 5)
            ForEach($generator.blocks) { $block in
                HStack {
                    Text(block.title)
                    Spacer()
                    DatePicker("", selection: minutesBinding($block.start), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Stepper("\(block.count) 节", value: $block.count, in: 0...8)
                        .fixedSize()
                }
            }
            Button {
                draft.classTimes = generator.make()
            } label: {
                Label("按这个作息生成 \(generator.periodCount) 节", systemImage: "wand.and.stars")
            }
            .disabled(generator.periodCount == 0)
        } header: {
            Text("快速生成")
        } footer: {
            Text("填上午、下午、晚上第一节几点开始、各几节，再按课时和课间排出每节时间。生成后可以在下面逐节改，比如大课间。")
        }

        Section {
            ForEach(Array(draft.classTimes.indices), id: \.self) { index in
                HStack {
                    Text("第 \(index + 1) 节")
                        .monospacedDigit()
                    Spacer()
                    DatePicker("", selection: timeBinding(index, \.start), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("–").foregroundStyle(.secondary)
                    DatePicker("", selection: timeBinding(index, \.end), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            }
            .onDelete { draft.classTimes.remove(atOffsets: $0) }

            if draft.classTimes.count < ManualScheduleDraft.maxPeriods {
                Button {
                    let lastEnd = draft.classTimes.last.flatMap { ClassTimeValidator.minutes($0.end) } ?? 8 * 60 - generator.breakMinutes
                    let start = lastEnd + generator.breakMinutes
                    draft.classTimes.append(ClassTime(
                        start: ClassTimeValidator.format(start),
                        end: ClassTimeValidator.format(start + generator.lessonMinutes)
                    ))
                } label: {
                    Label("加一节", systemImage: "plus")
                }
            }
        } header: {
            Text("每天 \(draft.classTimes.count) 节")
        } footer: {
            Text("左滑删除一节。以后可以在「设置 › 我的课表」里再改。")
        }
    }

    private func minutesBinding(_ value: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Self.date(minutes: value.wrappedValue) },
            set: { value.wrappedValue = Self.minutes(of: $0) }
        )
    }

    private func timeBinding(_ index: Int, _ keyPath: WritableKeyPath<ClassTime, String>) -> Binding<Date> {
        Binding(
            get: {
                guard draft.classTimes.indices.contains(index) else { return Self.date(minutes: 8 * 60) }
                return Self.date(minutes: ClassTimeValidator.minutes(draft.classTimes[index][keyPath: keyPath]) ?? 8 * 60)
            },
            set: { value in
                guard draft.classTimes.indices.contains(index) else { return }
                draft.classTimes[index][keyPath: keyPath] = ClassTimeValidator.format(Self.minutes(of: value))
            }
        )
    }

    private static func date(minutes: Int) -> Date {
        let calendar = WeekCalculator.calendar
        return calendar.date(
            bySettingHour: minutes / 60, minute: minutes % 60, second: 0,
            of: calendar.startOfDay(for: Date())
        ) ?? Date()
    }

    private static func minutes(of date: Date) -> Int {
        let parts = WeekCalculator.calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// 删了几节之后，已经填好的课可能落到不存在的节次上，收回到最后一节。
    private func clampMeetings(periodCount: Int) {
        guard periodCount > 0 else { return }
        for c in draft.courses.indices {
            for m in draft.courses[c].meetings.indices {
                draft.courses[c].meetings[m].endPeriod = min(draft.courses[c].meetings[m].endPeriod, periodCount)
                draft.courses[c].meetings[m].startPeriod = min(
                    draft.courses[c].meetings[m].startPeriod, draft.courses[c].meetings[m].endPeriod
                )
            }
        }
    }

    // MARK: 3. 课程

    @ViewBuilder
    private var coursesStep: some View {
        if draft.courses.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("一门一门加", systemImage: "books.vertical")
                        .font(.headline)
                    Text("每门课填上星期、节次和周次。同一门课一周上几次，就在这门课里加几个上课时间；单双周、只上某几周都能选。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(requiresCourses
                         ? "先加至少一门课就能开始用，剩下的以后在课表上长按空白处添加。"
                         : "也可以先跳过，以后在课表上长按空白处添加。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        } else {
            Section {
                ForEach(draft.courses) { course in
                    Button { editingCourse = course } label: {
                        courseRow(course)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { draft.courses.remove(atOffsets: $0) }
            } header: {
                Text("已添加 \(draft.courses.count) 门")
            } footer: {
                Text("点一门课修改，左滑删除。")
            }
        }

        Section {
            Button {
                editingCourse = ManualCourseDraft()
            } label: {
                Label("添加课程", systemImage: "plus.circle.fill")
            }
        }

        let warnings = draft.overlapWarnings
        if !warnings.isEmpty {
            Section {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("时间冲突")
            } footer: {
                Text("冲突的课会在课表里并排显示。如果是填错了，点进那门课改一下。")
            }
        }
    }

    private func courseRow(_ course: ManualCourseDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(course.trimmedName).font(.body.weight(.medium))
                if !course.teacher.isEmpty {
                    Text(course.teacher).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            ForEach(course.meetings) { meeting in
                Text(meeting.summary(weekCount: draft.weekCount, classTimes: draft.classTimes)
                     + (meeting.classroom.isEmpty ? "" : " · \(meeting.classroom)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    // MARK: 4. 确认

    @ViewBuilder
    private var reviewStep: some View {
        Section("课表") {
            LabeledContent("名称", value: draft.trimmedName)
            LabeledContent("第一周的星期一", value: draft.semesterStartMonday)
            LabeledContent("学期总周数", value: "\(draft.weekCount) 周")
        }
        Section("节次") {
            LabeledContent("每天", value: "\(draft.classTimes.count) 节")
            if let first = draft.classTimes.first, let last = draft.classTimes.last {
                LabeledContent("时间", value: "\(first.start) – \(last.end)")
            }
        }
        Section {
            LabeledContent("课程", value: "\(draft.courses.count) 门")
            LabeledContent("每周上课", value: "\(draft.courses.reduce(0) { $0 + $1.meetings.count }) 次")
        } header: {
            Text("课程")
        } footer: {
            Text("创建后会切换到这张课表。学期、周数和节次时间以后都能在「设置 › 我的课表」里改，课程可以在课表上长按添加或点开修改。")
        }
    }
}

// MARK: - 单门课程编辑

/// 一门课的编辑表单：名字、老师，以及它每周的若干个上课时间。
private struct ManualCourseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var course: ManualCourseDraft
    let classTimes: [ClassTime]
    let weekCount: Int
    let isNew: Bool
    let onSave: (ManualCourseDraft) -> Void
    @State private var error: String?

    private var periodCount: Int { max(1, classTimes.count) }

    var body: some View {
        NavigationStack {
            Form {
                Section("课程") {
                    TextField("课程名称", text: $course.name)
                    TextField("老师（选填）", text: $course.teacher)
                }

                ForEach($course.meetings) { $meeting in
                    meetingSection($meeting)
                }

                Section {
                    Button {
                        var next = course.meetings.last ?? ManualMeetingDraft()
                        next.id = UUID()
                        next.weekday = min(next.weekday + 2, 7)
                        course.meetings.append(next)
                    } label: {
                        Label("再加一个上课时间", systemImage: "plus")
                    }
                } footer: {
                    Text("同一门课一周上几次，就加几个；每个上课时间的教室和周次可以不一样。")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isNew ? "添加课程" : "编辑课程")
            .appInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let problem = course.problem(periodCount: periodCount, weekCount: weekCount) {
                            error = problem
                            return
                        }
                        onSave(course)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .appSheetDetents([.large])
    }

    private func meetingSection(_ meeting: Binding<ManualMeetingDraft>) -> some View {
        let index = course.meetings.firstIndex { $0.id == meeting.wrappedValue.id } ?? 0
        return Section {
            Picker("星期", selection: meeting.weekday) {
                ForEach(1...7, id: \.self) { Text(WeekCalculator.weekdayName($0)).tag($0) }
            }
            Picker("开始", selection: meeting.startPeriod) {
                ForEach(1...periodCount, id: \.self) { Text(periodLabel($0, start: true)).tag($0) }
            }
            .onChange(of: meeting.wrappedValue.startPeriod) { _, start in
                if meeting.wrappedValue.endPeriod < start { meeting.wrappedValue.endPeriod = min(start + 1, periodCount) }
            }
            Picker("结束", selection: meeting.endPeriod) {
                ForEach(meeting.wrappedValue.startPeriod...periodCount, id: \.self) {
                    Text(periodLabel($0, start: false)).tag($0)
                }
            }
            TextField("教室（选填）", text: meeting.classroom)

            Picker("周次", selection: kindBinding(meeting)) {
                Text("每周").tag(WeekSeries.Kind.full)
                Text("单周").tag(WeekSeries.Kind.single)
                Text("双周").tag(WeekSeries.Kind.double)
                Text("自选").tag(WeekSeries.Kind.custom)
            }
            .pickerStyle(.segmented)

            if meeting.wrappedValue.kind == .custom {
                WeekChipGrid(weekCount: weekCount, selection: meeting.customWeeks)
            } else {
                Picker("从", selection: meeting.firstWeek) {
                    ForEach(1...weekCount, id: \.self) { Text("第 \($0) 周").tag($0) }
                }
                Picker("到", selection: lastWeekBinding(meeting)) {
                    ForEach(max(1, meeting.wrappedValue.firstWeek)...weekCount, id: \.self) {
                        Text($0 == weekCount ? "第 \($0) 周（最后一周）" : "第 \($0) 周").tag($0)
                    }
                }
            }
        } header: {
            HStack {
                Text(course.meetings.count > 1 ? "上课时间 \(index + 1)" : "上课时间")
                Spacer()
                if course.meetings.count > 1 {
                    Button("删除", role: .destructive) {
                        course.meetings.removeAll { $0.id == meeting.wrappedValue.id }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        } footer: {
            let weeks = meeting.wrappedValue.weeks(weekCount: weekCount)
            Text(weeks.isEmpty ? "还没选周次" : "\(WeekSeries.summary(weeks))，共 \(weeks.count) 次")
        }
    }

    private func periodLabel(_ period: Int, start: Bool) -> String {
        guard classTimes.indices.contains(period - 1) else { return "第 \(period) 节" }
        let time = classTimes[period - 1]
        return "第 \(period) 节 \(start ? time.start : time.end)"
    }

    /// 切到「自选」时，把当前范围算出来的周先勾上，在它的基础上增减。
    private func kindBinding(_ meeting: Binding<ManualMeetingDraft>) -> Binding<WeekSeries.Kind> {
        Binding(
            get: { meeting.wrappedValue.kind },
            set: { kind in
                if kind == .custom, meeting.wrappedValue.kind != .custom {
                    meeting.wrappedValue.customWeeks = Set(meeting.wrappedValue.weeks(weekCount: weekCount))
                }
                meeting.wrappedValue.kind = kind
            }
        )
    }

    /// 选最后一周时存 `nil`，这样之后改学期总周数，这门课也跟着到最后一周。
    private func lastWeekBinding(_ meeting: Binding<ManualMeetingDraft>) -> Binding<Int> {
        Binding(
            get: { meeting.wrappedValue.resolvedLastWeek(weekCount: weekCount) },
            set: { meeting.wrappedValue.lastWeek = $0 >= weekCount ? nil : $0 }
        )
    }
}

/// 逐周勾选，附带全选 / 单周 / 双周 / 清空的快捷键。
private struct WeekChipGrid: View {
    let weekCount: Int
    @Binding var selection: Set<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                quick("全选") { selection = Set(1...weekCount) }
                quick("单周") { selection = Set(WeekSeries.single(from: 1, to: weekCount)) }
                quick("双周") { selection = Set(WeekSeries.double(from: 1, to: weekCount)) }
                quick("清空") { selection = [] }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 30), spacing: 6), count: 6), spacing: 6) {
                ForEach(1...weekCount, id: \.self) { week in
                    let on = selection.contains(week)
                    Button {
                        if on { selection.remove(week) } else { selection.insert(week) }
                    } label: {
                        Text("\(week)")
                            .font(.caption.weight(.medium).monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .foregroundStyle(on ? Color.cpuBrand : .secondary)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(on ? Color.cpuBrand.opacity(0.14) : Color.appSecondaryGroupedBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(on ? Color.cpuBrand : Color.appSeparator.opacity(0.45), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("第 \(week) 周")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func quick(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}
