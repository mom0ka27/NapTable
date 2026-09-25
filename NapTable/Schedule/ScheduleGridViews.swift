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

    private var laneCount: Int {
        max(1, (blocks.map(\.lane).max() ?? 0) + 1)
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
                    Text(dayLabel)
                        .font(.caption.weight(.semibold))
                    HStack(spacing: 1) {
                        Text(dateText ?? "--")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                .frame(width: columnWidth, height: Self.dateHeaderHeight)
                .background {
                    if isToday {
                        ScheduleGlassBackground(
                            cornerRadius: 12,
                            colors: [
                                Color(hue: 0.43, saturation: 0.22, brightness: 0.92).opacity(0.12),
                                Color(hue: 0.59, saturation: 0.20, brightness: 0.96).opacity(0.10),
                                Color(hue: 0.89, saturation: 0.18, brightness: 0.96).opacity(0.12),
                            ],
                            border: Color.cpuBrand.opacity(0.22)
                        )
                            .padding(.horizontal, 2)
                            .padding(.vertical, 3)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(headerAccessibilityLabel)
            }

            ZStack(alignment: .topLeading) {
                VStack(spacing: Self.slotGap) {
                    ForEach(ScheduleSlot.all.prefix(slotCount), id: \.number) { slot in
                        let occupied = blocks.contains { ($0.startSlot...$0.endSlot).contains(slot.number) }
                        HStack(spacing: 0) {
                            ForEach(0..<laneCount, id: \.self) { lane in
                                let laneOccupied = blocks.contains {
                                    $0.lane == lane && ($0.startSlot...$0.endSlot).contains(slot.number)
                                }
                                Group {
                                    if laneOccupied {
                                        Color.clear
                                    } else {
                                        ScheduleGlassBackground(cornerRadius: 8)
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
}



struct NativeScheduleCourseCard: View {
    @Environment(\.colorScheme) private var colorScheme
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
                    .font(.system(size: compact || shortCard ? 11 : 14, weight: .semibold))
                    .lineLimit(shortCard ? 1 : (compact ? 3 : 2))
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)

                if let location {
                    Text(location)
                        .font(.system(size: compact || shortCard ? 9 : 12, weight: .medium))
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
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            ZStack {
                // Match Web's color-glass tone: a colored surface with a
                // slightly darker lower stop, instead of a gray material
                // layer that washes the course color out.
                shape.fill(
                    LinearGradient(
                        colors: [
                            courseBackground.opacity(colorScheme == .dark ? 0.94 : 0.88),
                            courseBackgroundHighlight.opacity(colorScheme == .dark ? 0.94 : 0.88),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                // Web's inset highlight is subtle but gives every card a
                // glass edge when several cards sit next to one another.
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(colorScheme == .dark ? 0.18 : 0.40), location: 0),
                            .init(color: .white.opacity(0.05), location: 0.34),
                            .init(color: .clear, location: 0.72),
                            .init(color: .black.opacity(colorScheme == .dark ? 0.10 : 0.025), location: 1),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.strokeBorder(courseBorder, lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(
            color: colorScheme == .dark ? Color.black.opacity(0.24) : Color(red: 44 / 255, green: 62 / 255, blue: 94 / 255).opacity(0.08),
            radius: colorScheme == .dark ? 8 : 5,
            y: colorScheme == .dark ? 3 : 2
        )
        .accessibilityElement(children: .combine)
    }

    private var swatch: ScheduleCourseTint.Swatch {
        ScheduleCourseTint.swatch(for: course.name, solid: themeSettings.solidCourseColor)
    }

    private var accent: Color {
        swatch.accent(scheme: colorScheme)
    }

    private var courseBorder: Color {
        if colorScheme == .dark {
            return hslColor(hue: hue, saturation: min(0.86, saturation + 0.08), lightness: 0.72).opacity(0.72)
        }
        return hslColor(
            hue: hue,
            saturation: min(0.82, saturation + 0.08),
            lightness: swatch.borderLightness
        ).opacity(0.48)
    }

    private var hue: Double { swatch.hue }

    private var saturation: Double { swatch.saturation }

    private var backgroundLightness: Double { swatch.backgroundLightness }

    private var courseBackground: Color {
        if colorScheme == .dark {
            return hslColor(hue: hue, saturation: min(0.82, saturation + 0.04), lightness: 0.34)
        }
        return hslColor(hue: hue, saturation: saturation, lightness: backgroundLightness)
    }

    private var courseBackgroundHighlight: Color {
        if colorScheme == .dark {
            return hslColor(hue: hue, saturation: min(0.82, saturation + 0.04), lightness: 0.24)
        }
        return hslColor(hue: hue, saturation: saturation, lightness: max(0.84, backgroundLightness - 0.04))
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
