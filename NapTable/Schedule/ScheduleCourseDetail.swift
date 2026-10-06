import SwiftUI

/// 课表页的课程 sheet。轻点日、周、月视图卡片，按内容高度展示课程速览；
/// 自己的课表点「编辑」后在同一个 sheet 里换成编辑页并展开到全高。长按照旧直接进编辑。
struct ScheduleCourseSheet: View {
    let selection: SelectedCourse
    @ObservedObject var store: NativeScheduleStore
    let defaultWeek: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing: Bool
    @State private var detent: PresentationDetent
    @State private var previewHeight: CGFloat = 280

    init(selection: SelectedCourse, store: NativeScheduleStore, defaultWeek: Int) {
        self.selection = selection
        _store = ObservedObject(wrappedValue: store)
        self.defaultWeek = defaultWeek
        let editing = !selection.quickLook && !store.isReadOnly
        _editing = State(initialValue: editing)
        _detent = State(initialValue: editing ? .large : .height(280))
    }

    var body: some View {
        Group {
            if editing {
                NativeCourseEditorSheet(selection: selection, store: store, defaultWeek: defaultWeek)
            } else {
                ScheduleCourseQuickLook(
                    course: selection.course,
                    schedule: selection.schedule,
                    onEdit: store.isReadOnly ? nil : {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
                            detent = .large
                            editing = true
                        }
                    },
                    onHeightChange: { height in
                        let height = min(560, max(180, ceil(height)))
                        guard abs(height - previewHeight) > 1 else { return }
                        previewHeight = height
                        if !editing && detent != .large { detent = .height(height) }
                    }
                )
            }
        }
        .modifier(ScheduleCourseSheetDetents(editing: editing, previewHeight: previewHeight, detent: $detent))
        .appDragIndicatorVisible()
    }
}

/// 短内容收紧高度，长内容可滚动或拉到全高；编辑页只给全高。
private struct ScheduleCourseSheetDetents: ViewModifier {
    let editing: Bool
    let previewHeight: CGFloat
    @Binding var detent: PresentationDetent

    func body(content: Content) -> some View {
        #if os(iOS)
        content.presentationDetents(editing ? [.large] : [.height(previewHeight), .large], selection: $detent)
        #else
        content
        #endif
    }
}

/// 课程速览：课名，「星期 · 第 N–M 节 · 起止时间」，然后是教室、老师、周次、备注。
/// 共享课表的课程详情也是它，只是没有「编辑」。内容直接排在 sheet 底上，不套卡片和 Form 分组。
struct ScheduleCourseQuickLook: View {
    let course: NativeScheduleCourse
    /// 「周一 · 第 1–2 节 · 08:00–09:40」。自由时间课程没有固定时间，为 nil。
    var schedule: String? = nil
    /// 自己的课表右上角显示「编辑」；共享课表传 nil，只读。
    var onEdit: (() -> Void)? = nil
    var onHeightChange: (CGFloat) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeSettings = NativeThemeSettings.shared

    private struct Detail: Identifiable {
        let title: String
        let symbol: String
        let value: String
        var id: String { title }
    }

    /// 没填的项不占行。
    private var details: [Detail] {
        [("教室", "mappin.and.ellipse", NativeScheduleCourseCard.displayLocation(course.location)),
         ("老师", "person", course.teacher?.trimmedNonEmpty),
         ("周次", "calendar", course.weeks.trimmedNonEmpty),
         ("备注", "text.alignleft", course.slotNote?.trimmedNonEmpty)]
            .compactMap { title, symbol, value in value.map { Detail(title: title, symbol: symbol, value: $0) } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                // 四个标题都是两个字，同字号下一样宽，值自然对齐成一列。
                let rows = details
                if !rows.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(rows) { detail in
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Label {
                                    Text(detail.title)
                                } icon: {
                                    Image(systemName: detail.symbol)
                                        .foregroundStyle(accent)
                                        .frame(width: 18)
                                }
                                .font(.subheadline)
                                .foregroundStyle(.scheduleMeta)
                                .fixedSize()
                                Text(detail.value)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if onEdit == nil {
                    Label("共享课表只读", systemImage: "lock")
                        .font(.footnote)
                        .foregroundStyle(.scheduleMeta)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .appSoftTopScrollEdge()
    }

    private var accent: Color {
        ScheduleCourseTint.accent(for: course.name, scheme: colorScheme, solid: themeSettings.solidCourseColor)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            // 课程色条，和课表上那张卡片对得上。
            Capsule()
                .fill(accent)
                .frame(width: 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(course.name)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let schedule {
                    Label(schedule, systemImage: "clock")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.scheduleMeta)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 和当天安排 sheet 的「日视图」按钮同一个样子。
            if let onEdit {
                Button(action: onEdit) {
                    Text("编辑")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.themeTint(colorScheme == .dark ? 0.2 : 0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.themeText)
                .accessibilityLabel("编辑课程")
            }

            #if os(macOS)
            // Mac 上的 sheet 不能下拉关闭，留一个按钮。
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
            #endif
        }
        // 色条跟着课名和时间那几行一样高。
        .fixedSize(horizontal: false, vertical: true)
    }
}
