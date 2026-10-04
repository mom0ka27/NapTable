import SwiftUI

/// 无课日共用的休息状态；月历预览使用横排，日视图和详情页保留更舒展的留白。
struct ScheduleEmptyDayView: View {
    var note: String? = nil
    var holidayGreeting: String? = nil
    var outsideTerm = false
    var compact = false

    private var subtitle: String {
        if outsideTerm { return "不在当前学期的教学周内" }
        if holidayGreeting != nil { return "这天没课，放松一下" }
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return note
        }
        return "留点时间，做喜欢的事"
    }

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 16) {
                    labels(alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    illustration
                        .frame(width: 72, height: 56)
                }
                .padding(.horizontal, 8)
            } else {
                VStack(spacing: 18) {
                    illustration
                        .frame(width: 116, height: 88)
                    labels(alignment: .center)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func labels(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: compact ? 6 : 8) {
            Text(holidayGreeting ?? (outsideTerm ? "暂无课程" : "这天没课"))
                .font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(compact ? .leading : .center)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var illustration: some View {
        Group {
            if let holidayGreeting {
                ScheduleHolidayCelebrationButton(greeting: holidayGreeting, compact: compact)
            } else if outsideTerm {
                Image(systemName: "calendar")
                    .font(.system(size: compact ? 30 : 44, weight: .ultraLight))
                    .foregroundStyle(Color.cpuBrand.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            } else {
                ScheduleRestIllustration()
                    .accessibilityHidden(true)
            }
        }
    }
}

/// 一朵打盹的云。用矢量绘制，随主题色和深浅外观适配。
private struct ScheduleRestIllustration: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 116, y: size.height / 88)
            let dark = colorScheme == .dark
            let accent = Color.cpuBrand

            context.fill(Path(ellipseIn: CGRect(x: 15, y: 4, width: 78, height: 78)),
                         with: .color(accent.opacity(dark ? 0.10 : 0.05)))
            context.fill(Path(ellipseIn: CGRect(x: 24, y: 75, width: 65, height: 5)),
                         with: .color(accent.opacity(dark ? 0.10 : 0.07)))
            context.fill(Path(ellipseIn: CGRect(x: 65, y: 11, width: 29, height: 29)),
                         with: .color(accent.opacity(dark ? 0.48 : 0.24)))

            var cloud = Path()
            cloud.move(to: CGPoint(x: 32, y: 67))
            cloud.addCurve(to: CGPoint(x: 30, y: 37), control1: CGPoint(x: 11, y: 67), control2: CGPoint(x: 10, y: 39))
            cloud.addCurve(to: CGPoint(x: 66, y: 30), control1: CGPoint(x: 29, y: 15), control2: CGPoint(x: 60, y: 11))
            cloud.addCurve(to: CGPoint(x: 85, y: 42), control1: CGPoint(x: 76, y: 26), control2: CGPoint(x: 87, y: 32))
            cloud.addCurve(to: CGPoint(x: 84, y: 67), control1: CGPoint(x: 105, y: 43), control2: CGPoint(x: 103, y: 67))
            cloud.closeSubpath()
            context.fill(cloud, with: .color(dark ? Color(white: 0.20) : .white))
            context.fill(cloud, with: .color(accent.opacity(dark ? 0.09 : 0.025)))
            context.stroke(cloud, with: .color(accent.opacity(dark ? 0.35 : 0.20)), lineWidth: 1.2)

            var eyes = Path()
            for x: CGFloat in [41, 63] {
                eyes.move(to: CGPoint(x: x, y: 48))
                eyes.addQuadCurve(to: CGPoint(x: x + 10, y: 48), control: CGPoint(x: x + 5, y: 54))
            }
            context.stroke(eyes, with: .color(accent.opacity(dark ? 0.85 : 0.70)),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
    }
}
