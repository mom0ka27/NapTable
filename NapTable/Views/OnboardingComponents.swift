import SwiftUI

/// Shared palette for first-run onboarding and privacy sheets, in both appearances.
struct OnboardingColors {
    var scheme: ColorScheme
    private var dark: Bool { scheme == .dark }
    // Warm pinks taken from the app logo (see the 兔兔粉 theme).
    var background: Color { dark ? Color(red: 0.110, green: 0.071, blue: 0.071) : Color(red: 0.984, green: 0.953, blue: 0.941) }
    var surface: Color { dark ? Color(red: 0.165, green: 0.110, blue: 0.105) : .white }
    var ink: Color { dark ? Color(red: 0.97, green: 0.93, blue: 0.91) : Color(red: 0.23, green: 0.15, blue: 0.14) }
    var secondary: Color { dark ? Color(red: 0.75, green: 0.65, blue: 0.63) : Color(red: 0.48, green: 0.37, blue: 0.36) }
    var accent: Color { dark ? Color(red: 0.95, green: 0.60, blue: 0.56) : Color(red: 0.84, green: 0.37, blue: 0.33) }
    var soft: Color { dark ? Color(red: 0.23, green: 0.145, blue: 0.14) : Color(red: 0.988, green: 0.894, blue: 0.871) }
    var line: Color { dark ? Color.white.opacity(0.09) : Color(red: 0.94, green: 0.87, blue: 0.85) }
    var buttonText: Color { dark ? Color(red: 0.23, green: 0.12, blue: 0.11) : .white }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let colors = OnboardingColors(scheme: scheme)
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(isEnabled ? colors.buttonText : colors.secondary)
            .background(isEnabled ? colors.accent : colors.line, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct OnboardingArtwork: View {
    @Environment(\.colorScheme) private var scheme
    var importing = false
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        ZStack {
            Circle().fill(colors.soft).frame(width: 152, height: 152).offset(x: 23, y: 5)
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(colors.line, lineWidth: 1)
                .frame(width: 167, height: 116)
                .rotationEffect(.degrees(8)).offset(x: 10, y: 1)
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "calendar")
                    Text("一周，心中有数").font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Circle().fill(colors.accent.opacity(0.35)).frame(width: 5, height: 5)
                }
                .foregroundStyle(colors.accent)
                HStack(alignment: .top, spacing: 7) {
                    ForEach(0..<5) { day in
                        VStack(spacing: 6) {
                            Text(["一", "二", "三", "四", "五"][day])
                                .font(.system(size: 8, weight: .medium)).foregroundStyle(colors.secondary)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(day == 1 || day == 4 ? colors.soft : colors.accent.opacity(0.62))
                                .frame(height: day == 2 ? 33 : 22)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(day == 3 ? colors.accent.opacity(0.30) : colors.soft)
                                .frame(height: day == 2 ? 12 : 23)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(15)
            .frame(width: 187)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(colors.line, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.1 : 0.05), radius: 12, x: 0, y: 7)
            .rotationEffect(.degrees(-6))
            .offset(x: -9, y: -2)

            Image(systemName: importing ? "arrow.down" : "checkmark.shield.fill")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(colors.buttonText)
                .frame(width: 50, height: 50)
                .background(colors.accent, in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(colors.background, lineWidth: 4))
                .rotationEffect(.degrees(8))
                .offset(x: 83, y: 41)
        }
        .scaleEffect(0.84)
        .frame(maxWidth: .infinity)
        .frame(height: 128)
        .accessibilityHidden(true)
    }
}

struct OnboardingPermissionCard: View {
    let title: String
    let summary: String
    let symbol: String
    let optional: Bool
    @Binding var accepted: Bool
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(colors.accent)
                    .frame(width: 36, height: 36)
                    .background(colors.soft, in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(colors.ink)
                Spacer(minLength: 2)
                Text(optional ? "可选" : "必选")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(colors.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(colors.background, in: Capsule())
            }
            Text(summary)
                .font(.caption).foregroundStyle(colors.secondary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                NavigationLink { PrivacyDocumentView(liveActivities: optional) } label: {
                    HStack(spacing: 4) {
                        Text("阅读完整协议")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(colors.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Button {
                    accepted.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: accepted ? "checkmark.square.fill" : "square")
                            .font(.system(size: 21, weight: .regular))
                            .foregroundStyle(accepted ? colors.accent : colors.secondary)
                        Text("我已阅读并同意")
                            .font(.caption.weight(.medium)).foregroundStyle(colors.ink)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("我已阅读并同意\(title)")
                .accessibilityValue(accepted ? "已同意" : "未同意")
                .accessibilityAddTraits(accepted ? [.isSelected] : [])
            }
            .padding(.bottom, -6)
        }
        .padding(16)
        .background(colors.surface, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(accepted ? colors.accent.opacity(0.45) : colors.line, lineWidth: 1))
    }
}

/// The two actions people usually look for after their first import. Keep the
/// wording in one place so the first-run page and Settings stay in sync.
struct ScheduleUsageGuideView: View {
    var showsTitle = true
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsTitle {
                Text("导入后这样用")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colors.ink)
            }

            usageRow(
                number: "1",
                symbol: "square.and.pencil",
                title: "修改课程详细信息",
                detail: "在自己的课表中点按课程卡片，打开“编辑课程”。可以修改课程名、老师、地点、备注、周数和上课节次，完成后点右上角“保存”。"
            )

            usageRow(
                number: "2",
                symbol: "plus.square",
                title: "把课表放到桌面",
                detail: widgetInstruction
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surface, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(colors.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var widgetInstruction: String {
        #if os(iOS)
        return "回到 iPhone 或 iPad 主屏幕，长按空白处，点左上角“+”，搜索 NapTable，选择“今日课程”或“两日课表”，再点“添加小组件”。"
        #else
        return "小组件可在 iPhone 或 iPad 主屏幕添加：长按空白处，点“+”，搜索 NapTable，选择“今日课程”或“两日课表”，再点“添加小组件”。"
        #endif
    }

    private func usageRow(number: String, symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(colors.soft)
                Text(number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(colors.accent)
            }
            .frame(width: 28, height: 28)

            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(colors.accent)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colors.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(colors.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ScheduleUsageGuideScreen: View {
    var body: some View {
        ScrollView {
            ScheduleUsageGuideView(showsTitle: false)
                .padding(16)
        }
        .background(.appBackground)
        .navigationTitle("使用指南")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
    }
}
