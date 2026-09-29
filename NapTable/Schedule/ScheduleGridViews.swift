import SwiftUI

struct NativeScheduleDayColumn: View {
    // Fixed heights match CpuTime: compact uses 40/37, comfortable 44/41.
    // NapTable adds relaxed at 49/46 for people who want more air between rows.
    static let slotHeight: CGFloat = 44
    // The day layout has an extra seven-day picker above the grid, so its rows
    // stay 3pt shorter to keep the eleventh slot clear of the native tab bar.
    static let daySlotHeight: CGFloat = 41
    // The Web grid uses a 3px row gap on mobile. Keep the native cells on the
    // same rhythm so empty rows do not look stretched apart.
    static let slotGap: CGFloat = 3
    static let dateHeaderHeight: CGFloat = 46

    let day: Int
    let dateText: String?
    let isToday: Bool
    /// 这一天的调休。有值时日期旁边多一个「休」/「班」角标。
    let adjustment: ResolvedCalendarAdjustment?
    let columnWidth: CGFloat
    let rowHeight: CGFloat
    /// 画到第几节。晚上没课的行可以收起来，见 `NativeSchedulePreferences.hideSlotsAfter`。
    var slotCount: Int = ScheduleSlot.all.count
    let compactCards: Bool
    let showsDateHeader: Bool
    let blocks: [NativeScheduleCourseBlock]
    let onCourseSelected: (NativeScheduleCourseBlock) -> Void
    let onEmptySlot: (Int) -> Void

    /// 每张卡片所在「重叠簇」的列数：互相重叠（含连环重叠）的课一起分列，
    /// 其他时段的课和空格子保持整宽，不再因为当天某处有冲突就整天变窄。
    private var clusterLaneCounts: [String: Int] {
        var counts: [String: Int] = [:]
        var cluster: [NativeScheduleCourseBlock] = []
        var clusterEnd = Int.min
        func flush() {
            let lanes = max(1, (cluster.map(\.lane).max() ?? 0) + 1)
            for block in cluster { counts[block.id] = lanes }
            cluster.removeAll()
        }
        for block in blocks.sorted(by: { ($0.startSlot, $0.endSlot) < ($1.startSlot, $1.endSlot) }) {
            if !cluster.isEmpty && block.startSlot > clusterEnd { flush() }
            cluster.append(block)
            clusterEnd = cluster.count == 1 ? block.endSlot : max(clusterEnd, block.endSlot)
        }
        flush()
        return counts
    }

    private func laneCount(forSlot slot: Int, in counts: [String: Int]) -> Int {
        blocks.filter { ($0.startSlot...$0.endSlot).contains(slot) }
            .map { counts[$0.id] ?? 1 }
            .max() ?? 1
    }

    private var headerAccessibilityLabel: String {
        let base = [dayLabel, dateText].compactMap { $0 }.joined(separator: " ")
        guard let adjustment else { return base }
        return "\(base)，\(adjustment.detail)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsDateHeader {
                VStack(spacing: 2) {
                    Text(dayShortLabel)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isToday ? Color.cpuBrand : Color.primary)
                    HStack(spacing: 1) {
                        Text(dateText ?? "--")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(isToday ? Color.cpuBrand.opacity(0.85) : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if let adjustment {
                            Text(adjustment.badge)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white)
                                .fixedSize()
                                .frame(width: 11, height: 11, alignment: .center)
                                // 小字号汉字做光学居中，仅移动文字，不移动底色。
                                .offset(x: 0.2)
                                .background(
                                    (adjustment.kind == .off ? Color.pink : Color.orange).opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                                )
                        }
                    }
                    // The badge is fixed-size, so cap the row to the header's
                    // inner box and let the date shrink instead of spilling out.
                    .frame(maxWidth: max(0, columnWidth - 8))
                }
                // 星期表头不加框，直接把字放在底色上；今天只靠主题色文字标出来。
                .frame(width: columnWidth, height: Self.dateHeaderHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(headerAccessibilityLabel)
            }

            let laneCounts = clusterLaneCounts
            ZStack(alignment: .topLeading) {
                VStack(spacing: Self.slotGap) {
                    ForEach(ScheduleSlot.all.prefix(slotCount), id: \.number) { slot in
                        let occupied = blocks.contains { ($0.startSlot...$0.endSlot).contains(slot.number) }
                        let laneCount = laneCount(forSlot: slot.number, in: laneCounts)
                        HStack(spacing: 0) {
                            ForEach(0..<laneCount, id: \.self) { lane in
                                let laneOccupied = blocks.contains {
                                    $0.lane == lane && ($0.startSlot...$0.endSlot).contains(slot.number)
                                }
                                Group {
                                    if laneOccupied {
                                        Color.clear
                                    } else {
                                        ScheduleSurface(cornerRadius: 8)
                                    }
                                }
                                    .frame(width: max(12, columnWidth / CGFloat(laneCount) - 2), height: rowHeight - 2)
                                    .frame(width: columnWidth / CGFloat(laneCount), height: rowHeight)
                            }
                        }
                        .contentShape(Rectangle())
                        .onLongPressGesture {
                            guard !occupied else { return }
                            onEmptySlot(slot.number)
                        }
                        .allowsHitTesting(!occupied)
                        .accessibilityLabel(Text(verbatim: "第 \(slot.number) 节，长按添加课程"))
                        .accessibilityAddTraits(.isButton)
                    }
                }
                ForEach(blocks) { block in
                    let laneCount = laneCounts[block.id] ?? 1
                    NativeScheduleCourseCard(course: block.course, compact: compactCards || columnWidth < 70)
                        .frame(
                            width: max(12, columnWidth / CGFloat(laneCount) - 2),
                            height: max(
                                34,
                                CGFloat(block.endSlot - block.startSlot + 1) * rowHeight
                                    + CGFloat(block.endSlot - block.startSlot) * Self.slotGap
                                    - 2
                            )
                        )
                        .contentShape(Rectangle())
                        .onLongPressGesture {
                            onCourseSelected(block)
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(Text("长按修改课程"))
                    .offset(
                        x: 1 + CGFloat(block.lane) * (columnWidth / CGFloat(laneCount)),
                        y: CGFloat(block.startSlot - 1) * (rowHeight + Self.slotGap) + 1
                    )
                }
            }
            .frame(
                width: columnWidth,
                height: CGFloat(slotCount) * rowHeight
                    + CGFloat(max(0, slotCount - 1)) * Self.slotGap
            )
        }
        .frame(width: columnWidth)
    }

    private var dayLabel: String {
        ["周一", "周二", "周三", "周四", "周五", "周六", "周日"].indices.contains(day - 1)
            ? ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][day - 1]
            : "周\(day)"
    }

    /// 表头上只写一个字：一、二……日。完整的「周一」留给读屏。
    private var dayShortLabel: String {
        let labels = ["一", "二", "三", "四", "五", "六", "日"]
        return labels.indices.contains(day - 1) ? labels[day - 1] : "\(day)"
    }
}



struct NativeScheduleCourseCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleHasBackgroundImage) private var hasBackground
    @ObservedObject private var themeSettings = NativeThemeSettings.shared
    let course: NativeScheduleCourse
    var compact = false

    var body: some View {
        GeometryReader { geometry in
            let shortCard = geometry.size.height < 64
            // 卡片上除了课名只放教室；老师、周次和备注在课程详情里看。
            let location = clean(course.location)
                .map { "@\($0.trimmingCharacters(in: CharacterSet(charactersIn: "@＠")))" }

            VStack(spacing: compact ? 3 : (shortCard ? 2 : 5)) {
                Text(course.name)
                    .font(.system(size: compact || shortCard ? 11 : 14, weight: .bold))
                    .lineLimit(shortCard ? 1 : (compact ? 3 : 2))
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)

                if let location {
                    // 教室退半步：同一个颜色、小一号、淡一点，课名才是第一眼看到的。
                    Text(location)
                        .font(.system(size: compact || shortCard ? 9 : 12, weight: .semibold))
                        .opacity(0.8)
                        .lineLimit(shortCard ? 1 : 2)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .layoutPriority(2)
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(accent)
            .padding(.horizontal, compact ? 3 : 10)
            .padding(.vertical, shortCard ? 4 : 7)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
        .background {
            // 平涂一层淡彩，外面一圈同色细边，和网页版课表一样。原来叠的高光
            // 渐变和投影让整张表显得油，去掉了。
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            shape.fill(courseFill)
                .overlay { shape.strokeBorder(courseBorder, lineWidth: 1) }
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var swatch: ScheduleCourseTint.Swatch {
        ScheduleCourseTint.swatch(for: course.name, solid: themeSettings.solidCourseColor)
    }

    private var accent: Color {
        swatch.accent(scheme: colorScheme)
    }

    private var hue: Double { swatch.hue }

    private var saturation: Double { swatch.saturation }

    /// 浅色是一块不透明的淡彩；深色用半透明的课程色压在黑底上，文字再用亮一档
    /// 的同色，和系统日历的深色事件一个思路。
    private var courseFill: Color {
        if colorScheme == .dark {
            return hslColor(hue: hue, saturation: min(0.7, saturation), lightness: 0.5).opacity(0.26)
        }
        return hslColor(hue: hue, saturation: saturation, lightness: swatch.backgroundLightness)
            .opacity(hasBackground ? 0.92 : 1)
    }

    private var courseBorder: Color {
        if colorScheme == .dark {
            return hslColor(hue: hue, saturation: min(0.8, saturation), lightness: 0.62).opacity(0.34)
        }
        return hslColor(hue: hue, saturation: min(0.8, saturation + 0.04), lightness: swatch.borderLightness + 0.12)
            .opacity(0.55)
    }

    private func hslColor(hue: Double, saturation: Double, lightness: Double) -> Color {
        ScheduleCourseTint.color(hue: hue, saturation: saturation, lightness: lightness)
    }

    private func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
