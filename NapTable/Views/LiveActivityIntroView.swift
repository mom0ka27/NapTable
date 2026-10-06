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
    var accessMode: PurchaseManager.AccessMode
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LiveActivityPreviewArtwork()
            Text("上课前，灵动岛自动提醒。")
                .font(.system(.title, design: .rounded).weight(.bold)).tracking(-0.7)
                .foregroundStyle(colors.ink).fixedSize(horizontal: false, vertical: true)
            Text("实时活动在锁屏和灵动岛上显示下一节课和倒计时，不打开 App 也会按时出现。")
                .font(.subheadline).foregroundStyle(colors.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                if accessMode == .beta {
                    point("gift", "Beta 版本免费使用", "测试期间可免费使用实时活动，无需开始试用或购买。")
                } else if accessMode == .paid {
                    point("gift", "先免费试用 30 天", "首次确认试用时开始计时，到期不会自动扣款。")
                }
                point("creditcard", "专业版一次买断", "试用结束后可一次买断；课表和基础小组件始终免费。")
                point("calendar", "课表和基础小组件始终免费", "导入和查看课表、使用基础桌面小组件不受专业版权益影响。")
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
