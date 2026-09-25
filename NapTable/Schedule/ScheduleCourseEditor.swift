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

struct NativeCourseEditorSheet: View {
    let selection: SelectedCourse?
    @ObservedObject var store: NativeScheduleStore
    let defaultDay: Int
    let defaultWeek: Int
    let defaultStartSlot: Int
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var teacher: String
    @State private var location: String
    @State private var note: String
    @State private var day: Int
    @State private var isFreeTime: Bool
    @State private var startSlot: Int
    @State private var endSlot: Int
    @State private var weekMode: String
    @State private var selectedWeeks: Set<Int>
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var hiddenCourses: [(String, String)] = []
    @State private var confirmingDelete = false

    init(selection: SelectedCourse?, store: NativeScheduleStore, defaultDay: Int = 1, defaultWeek: Int = 1, defaultStartSlot: Int = 1) {
        self.selection = selection
        self.store = store
        self.defaultDay = defaultDay
        self.defaultWeek = defaultWeek
        self.defaultStartSlot = defaultStartSlot
        let course = selection?.course
        _name = State(initialValue: course?.name ?? "")
        _teacher = State(initialValue: course?.teacher ?? "")
        _location = State(initialValue: course?.location ?? "")
        _note = State(initialValue: course?.slotNote ?? "")
        _day = State(initialValue: selection?.day ?? defaultDay)
        _isFreeTime = State(initialValue: selection?.day == 0)
        _startSlot = State(initialValue: selection?.startSlot ?? defaultStartSlot)
        _endSlot = State(initialValue: selection?.endSlot ?? min(defaultStartSlot + 1, ScheduleSlot.all.count))
        let list = course?.weekList ?? [defaultWeek]
        _weekMode = State(initialValue: list.isEmpty ? "all" : (list == [defaultWeek] ? "current" : "custom"))
        _selectedWeeks = State(initialValue: Set(list.isEmpty ? [defaultWeek] : list))
    }

    /// NapTable's grid renders one row per teaching slot, so the editor offers
    /// the same range instead of the fixed eleven the CpuTime bridge used.
    private var maxSlot: Int { max(1, ScheduleSlot.all.count) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let selection, selection.course.custom || selection.course.orphaned {
                        editorCard { courseStatusCard(selection.course) }
                    }

                    Text("课程信息")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    editorCard {
                        editorFieldRow("课程") {
                            TextField("课程名称", text: $name)
                                .multilineTextAlignment(.trailing)
                        }
                        editorFieldRow("老师") {
                            TextField("选填", text: $teacher)
                                .multilineTextAlignment(.trailing)
                        }
                        editorFieldRow("地点") {
                            TextField("选填", text: $location)
                                .multilineTextAlignment(.trailing)
                        }
                        editorFieldRow("备注") {
                            TextField("选填", text: $note)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("时间段")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if canRestoreOriginalCourse, let sourceKey = selection?.course.sourceKey {
                            Button { restoreOriginal(sourceKey: sourceKey) } label: {
                                Label("使用教务安排", systemImage: "arrow.uturn.backward")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(Color.cpuBrand)
                            .disabled(saving)
                        }
                    }
                    .padding(.horizontal, 4)

                    editorCard {
                        editorFieldRow("周数") {
                            Picker("周次范围", selection: $weekMode) {
                                Text("本周").tag("current")
                                Text("全部周").tag("all")
                                Text("指定周次").tag("custom")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        if weekMode == "custom" {
                            weekChipPicker
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        } else {
                            Text(weekMode == "all" ? "这门课会显示在全部周次" : "第 \(defaultWeek) 周")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 10)
                        }
                        Toggle("自由时间（无固定星期和节次）", isOn: $isFreeTime)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 48)
                            .onChange(of: isFreeTime) { _, free in
                                if free {
                                    day = 0
                                    startSlot = 0
                                    endSlot = 0
                                } else {
                                    day = min(max(defaultDay, 1), 7)
                                    startSlot = max(1, defaultStartSlot)
                                    endSlot = max(startSlot, defaultStartSlot)
                                }
                            }
                        if !isFreeTime {
                            editorFieldRow("星期") {
                                Picker("星期", selection: $day) {
                                    ForEach(1...7, id: \.self) { Text(dayLabel($0)).tag($0) }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            }
                            // NapTable's bell schedule is per course table (13 slots
                            // by default, up to 15 for some schools), so the editor
                            // must offer every slot the grid actually renders.
                            editorStepperRow("开始第 \(startSlot) 节", value: $startSlot, range: 1...maxSlot)
                            editorStepperRow("结束第 \(endSlot) 节", value: $endSlot, range: startSlot...maxSlot)
                        } else {
                            Text("课程会显示在课表顶部，不会进入星期/节次网格。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 10)
                        }
                    }

                    if !hiddenCourses.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("已编辑课程")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            editorCard {
                                ForEach(hiddenCourses, id: \.0) { item in
                                    Button("恢复：\(item.1)") { restoreHiddenCourse(item.0) }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .disabled(saving)
                                }
                            }
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(selection == nil ? "添加课程" : "编辑课程")
            .appInlineNavigationTitle()
            .task { await loadHiddenCourses() }
            .onChange(of: weekMode) { _, mode in
                if mode == "all" {
                    selectedWeeks = Set(weekNumberOptions)
                } else if mode == "current" {
                    selectedWeeks = [defaultWeek]
                }
            }
            // 删除从表单中段挪到导航栏：一直可见，红色图标也比灰蓝的文字按钮显眼。
            // 删除和保存同组，删除在左、保存仍留在最右角；误触由确认弹窗兜底。
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label("取消", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if selection != nil {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("删除课程", systemImage: "trash")
                                .labelStyle(.iconOnly)
                        }
                        .tint(.red)
                        .foregroundStyle(.red)
                        .disabled(saving)
                        // 挂在垃圾桶按钮上，确认框从导航栏的按钮旁边弹出，而不是飘在表单中间。
                        .confirmationDialog("删除这门课程？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                            Button("删除", role: .destructive) { deleteCourse() }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text(selection?.course.customId != nil
                                 ? "这门自定义课程会被移除。"
                                 : "这门教务课程会从课表中隐藏，之后可以在“已编辑课程”里恢复。")
                        }
                    }
                    Button { saveCourse() } label: {
                        if saving {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("保存", systemImage: "checkmark")
                                .labelStyle(.iconOnly)
                                .font(.body.weight(.semibold))
                        }
                    }
                    .disabled(saving)
                }
            }
        }
    }

    private var canRestoreOriginalCourse: Bool {
        guard let course = selection?.course else { return false }
        return course.customId != nil && course.sourceKey != nil
    }

    @ViewBuilder
    private func editorCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(Color.appSecondaryGroupedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func editorFieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            content()
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: 190, alignment: .trailing)
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 14)
        .overlay(alignment: .bottom) {
            Divider().padding(.horizontal, 14)
        }
    }

    private func editorStepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Stepper("", value: value, in: range)
                .labelsHidden()
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 14)
        .overlay(alignment: .bottom) {
            Divider().padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private func courseStatusCard(_ course: NativeScheduleCourse) -> some View {
        // 这张卡片和下面的字段卡片共用 14pt 的左右内边距，图标徽章沿用设置页
        // 的品牌色圆角底，需要核对的课程换成橙色以示区分。
        let needsCheck = course.orphaned
        let tint = needsCheck ? Color.orange : Color.cpuBrand
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusIcon(for: course))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(needsCheck ? "这门课的安排需要核对" : statusTitle(for: course))
                        .font(.subheadline.weight(.semibold))
                    Text(statusMessage(for: course))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if needsCheck {
                Divider()
                Text("继续用自己的安排，可保留为自定义课程；以教务为准，可选择“使用教务安排”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("保留为自定义课程") { saveCourse(keepAsCustom: true) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(tint)
                    .disabled(saving)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func statusIcon(for course: NativeScheduleCourse) -> String {
        if course.orphaned { return "exclamationmark.triangle.fill" }
        if course.custom { return "square.and.pencil" }
        if course.sourceKey != nil { return "pencil" }
        return "building.columns"
    }

    private func statusTitle(for course: NativeScheduleCourse) -> String {
        if course.custom { return "自定义课程" }
        if course.sourceKey != nil { return "已编辑课程" }
        return "教务课程"
    }

    private func statusMessage(for course: NativeScheduleCourse) -> String {
        if course.orphaned {
            return "当前教务课表与保存编辑时的信息未能对应，可能是时间、周次、老师或地点变化，不表示课程已取消。这里仍保留着你的编辑。"
        }
        if course.sourceKey != nil {
            return "这是你编辑过的课程，可通过“使用教务安排”移除个人修改。"
        }
        if course.custom {
            return "这是你添加或保留的自定义课程，不属于教务课表。"
        }
        return "这是来自教务系统的课程安排。"
    }

    private func saveCourse(keepAsCustom: Bool = false) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { errorMessage = "请填写课程名称"; return }
        let maxSlot = max(1, ScheduleSlot.all.count)
        let freeTime = isFreeTime
        let start = freeTime ? 0 : min(max(startSlot, 1), maxSlot)
        let end = freeTime ? 0 : min(max(endSlot, start), maxSlot)
        let weekList: [Int]
        if weekMode == "all" {
            weekList = []
        } else if weekMode == "current" {
            weekList = [defaultWeek]
        } else {
            weekList = selectedWeeks.sorted()
            guard !weekList.isEmpty else {
                errorMessage = "请选择至少一个周次"
                return
            }
        }
        let weeks = weekList.isEmpty ? "全部周" : "第 \(weekList.map(String.init).joined(separator: ",")) 周"
        let source = selection?.course
        let editingSourceKey: String? = source.flatMap {
            // A pure custom course has no official source to hide or restore.
            if $0.customId != nil, $0.sourceKey == nil { return nil }
            return nativeCourseEditKey(
                day: selection?.day ?? day,
                bigSlot: selection?.bigSlot ?? (freeTime ? 0 : Int(ceil(Double(start) / 2))),
                course: $0
            )
        }
        let savedSourceKey = keepAsCustom ? nil : editingSourceKey
        let customID = source?.customId ?? "custom-\(UUID().uuidString.lowercased())"
        let item = NativeScheduleCustomItem(
            id: customID,
            sourceKey: savedSourceKey,
            day: freeTime ? 0 : day,
            bigSlot: freeTime ? 0 : Int(ceil(Double(start) / 2)),
            course: NativeScheduleCourse(
                name: trimmedName,
                teacher: teacher,
                weeks: weeks,
                weekList: weekList,
                location: location,
                slotNote: note.isEmpty ? (freeTime ? "自由时间" : "第 \(start)-\(end) 节") : note,
                startSlot: freeTime ? nil : start,
                endSlot: freeTime ? nil : end,
                sourceKey: savedSourceKey,
                customId: customID,
                custom: true
            )
        )
        saving = true
        Task { @MainActor in
            do {
                var edits = try await store.loadScheduleEdits()
                if let source {
                    if let customId = source.customId {
                        edits.custom.removeAll { $0.id == customId }
                    } else {
                        if !keepAsCustom, let key = editingSourceKey, !key.isEmpty && !edits.hidden.contains(key) {
                            edits.hidden.append(key)
                        }
                        if let editingSourceKey {
                            edits.custom.removeAll { $0.sourceKey == editingSourceKey }
                        }
                    }
                }
                edits.custom.removeAll { $0.id == item.id }
                edits.custom.append(item)
                try await store.saveScheduleEdits(edits)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            saving = false
        }
    }

    private func loadHiddenCourses() async {
        guard selection == nil || selection?.course.customId == nil else { return }
        guard let result = store.result else { return }
        do {
            let edits = try await store.loadScheduleEdits()
            var values: [(String, String)] = []
            for cell in result.cells {
            for course in cell.courses {
                    let key = nativeCourseEditKey(day: cell.day, bigSlot: cell.bigSlot, course: course)
                    if edits.hidden.contains(key) {
                        values.append((key, course.name))
                    }
                }
            }
            hiddenCourses = values
        } catch {
            hiddenCourses = []
        }
    }

    private func deleteCourse() {
        guard let source = selection?.course else { return }
        saving = true
        Task { @MainActor in
            do {
                var edits = try await store.loadScheduleEdits()
                if let customId = source.customId {
                    edits.custom.removeAll { $0.id == customId }
                } else {
                    let key = nativeCourseEditKey(day: selection?.day ?? 1, bigSlot: selection?.bigSlot ?? 1, course: source)
                    if !key.isEmpty && !edits.hidden.contains(key) { edits.hidden.append(key) }
                    edits.custom.removeAll { $0.sourceKey == key }
                }
                try await store.saveScheduleEdits(edits)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            saving = false
        }
    }

    private func restoreHiddenCourse(_ key: String) {
        saving = true
        Task { @MainActor in
            do {
                var edits = try await store.loadScheduleEdits()
                edits.hidden.removeAll { $0 == key }
                try await store.saveScheduleEdits(edits)
                hiddenCourses.removeAll { $0.0 == key }
            } catch {
                errorMessage = error.localizedDescription
            }
            saving = false
        }
    }

    private func restoreOriginal(sourceKey: String) {
        saving = true
        Task { @MainActor in
            do {
                var edits = try await store.loadScheduleEdits()
                edits.hidden.removeAll { $0 == sourceKey }
                edits.custom.removeAll { $0.sourceKey == sourceKey }
                try await store.saveScheduleEdits(edits)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            saving = false
        }
    }

    private func dayLabel(_ value: Int) -> String {
        ["周一", "周二", "周三", "周四", "周五", "周六", "周日"].indices.contains(value - 1)
            ? ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][value - 1] : "周\(value)"
    }

    private var weekNumberOptions: [Int] {
        let values = (store.result?.weeks ?? []).compactMap { Int($0.value) }.filter { $0 > 0 }
        if !values.isEmpty { return Array(Set(values)).sorted() }
        let maxWeek = max(defaultWeek, 20)
        return Array(1...maxWeek)
    }

    private var weekChipPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("指定周")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 30), spacing: 6), count: 6), spacing: 6) {
                    ForEach(weekNumberOptions, id: \.self) { week in
                        Button {
                            if selectedWeeks.contains(week) {
                                selectedWeeks.remove(week)
                            } else {
                                selectedWeeks.insert(week)
                            }
                        } label: {
                            Text("\(week)")
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .foregroundStyle(selectedWeeks.contains(week) ? Color.cpuBrand : .secondary)
                                .background {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(selectedWeeks.contains(week) ? Color.cpuBrand.opacity(0.14) : Color.appSecondaryGroupedBackground)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(selectedWeeks.contains(week) ? Color.cpuBrand : Color.appSeparator.opacity(0.45), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(saving)
                        .accessibilityLabel("第 \(week) 周")
                        .accessibilityAddTraits(selectedWeeks.contains(week) ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 132)
        }
    }
}
