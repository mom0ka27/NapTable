import SwiftUI

/// A round monogram: the first letter of the publisher's name on a tinted disc, or a
/// person glyph while there is none.
struct ShareOwnerMonogram: View {
    var name: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.16))
            if let initial = name.trimmedNonEmpty?.first {
                Text(String(initial)).font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.44)).foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// What Live Activities do, for the onboarding page.
struct LiveActivityIntroContent: View {
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LiveActivityPreviewArtwork()
            Text("上课前，锁屏自动提醒。")
                .font(.system(.title, design: .rounded).weight(.bold)).tracking(-0.7)
                .foregroundStyle(colors.ink).fixedSize(horizontal: false, vertical: true)
            Text("实时活动在锁屏和灵动岛上显示下一节课和倒计时，不打开 App 也会按时出现。")
                .font(.subheadline).foregroundStyle(colors.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                point("gift", "测试期间免费", "Beta 阶段不用订阅；正式收费前会在 App 内提前告知。")
                point("iphone", "不用注册账号", "开启后这台设备就能收到提醒，不需要登录。")
                point("creditcard", "之后按月订阅", "首月免费，可随时在系统设置中取消；课表、小组件始终免费。")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(colors.line, lineWidth: 1))
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(colors.accent)
                .frame(width: 32, height: 32).background(colors.soft, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(colors.ink)
                Text(detail).font(.caption).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The checkbox Live Activities need: the document one tap away, and turning
/// reminders on stays disabled until it is checked.
struct LiveActivityConsentNote: View {
    @Binding var agreed: Bool
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Button { agreed.toggle() } label: {
                Image(systemName: agreed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 19))
                    .foregroundStyle(agreed ? colors.accent : colors.secondary)
                    .frame(minWidth: 30, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("我已阅读并同意实时通知许可")
            .accessibilityValue(agreed ? "已同意" : "未同意")
            .accessibilityAddTraits(agreed ? [.isSelected] : [])
            HStack(spacing: 2) {
                Text("我已阅读并同意").foregroundStyle(colors.ink)
                    .onTapGesture { agreed.toggle() }
                    .accessibilityHidden(true)
                NavigationLink("《实时通知许可》") { PrivacyDocumentView(liveActivities: true) }
            }
            .tint(colors.accent)
            .foregroundStyle(colors.accent)
        }
        .font(.caption)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

/// A lock-screen Live Activity, drawn: the onboarding page's picture.
private struct LiveActivityPreviewArtwork: View {
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        VStack(spacing: 10) {
            Text("9:41").font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(colors.ink.opacity(0.85))
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9).fill(colors.accent).frame(width: 34, height: 34)
                    .overlay(Image(systemName: "book.closed.fill").font(.system(size: 15)).foregroundStyle(colors.buttonText))
                VStack(alignment: .leading, spacing: 3) {
                    Text("高等数学 · 仙Ⅱ-205").font(.system(size: 12, weight: .semibold)).foregroundStyle(colors.ink)
                    Text("第 1–2 节 · 08:00 上课").font(.system(size: 10)).foregroundStyle(colors.secondary)
                }
                Spacer(minLength: 0)
                Text("12:08").font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(colors.accent)
            }
            .padding(12)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(colors.line, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.1 : 0.05), radius: 12, x: 0, y: 7)
        }
        .padding(.horizontal, 26).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(colors.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 24))
        .accessibilityHidden(true)
    }
}
