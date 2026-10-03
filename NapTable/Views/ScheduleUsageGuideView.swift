import SwiftUI

/// A standalone guide, reachable from onboarding and Settings.
struct ScheduleUsageGuideScreen: View {
    var usesOnboardingStyle = false
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("课表放到桌面，抬眼就能看。")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(colors.ink)
                Text("导入课表后，在 iPhone 或 iPad 上添加小组件，再按自己的习惯调整显示。")
                    .font(.subheadline)
                    .foregroundStyle(colors.secondary)
                    .lineSpacing(3)

                guideCard("添加桌面小组件", symbol: "plus.square") {
                    instruction("1", title: "打开小组件库", detail: "回到主屏幕，长按空白处，等图标开始晃动。点左上角「编辑」→「添加小组件」；如果显示的是「+」，直接点「+」。")
                    instruction("2", title: "找到\(AppBrand.name)", detail: "搜索「\(AppBrand.name)」，选择「今日课程」或「两日课表」，左右滑动选择尺寸。")
                    instruction("3", title: "放到桌面", detail: "点「添加小组件」，拖到喜欢的位置，再点「完成」。")
                }

                guideCard("编辑桌面小组件", symbol: "slider.horizontal.3") {
                    instruction("1", title: "长按已添加的小组件", detail: "在主屏幕上长按\(AppBrand.name)小组件，选择「编辑小组件」。")
                    instruction("2", title: "调整显示选项", detail: "按下方说明选择，完成后轻点小组件外的空白处，设置会自动保存。")
                    Divider().overlay(colors.line)
                    option("今日课程结束后", detail: "「今日课程」可选「接着显示下一次课」或「只看今天」。")
                    option("显示课程数", detail: "小号「今日课程」可选「仅当前一节」或「当前与下一节」。")
                    option("显示方式", detail: "大号「今日课程」和「两日课表」可选「时间线」或「列表」。")
                    Text("每个小组件单独保存这些选项，可以添加多个并分别设置。课程名称、教室、老师等显示内容，可在 App「设置」→「桌面小组件」中统一调整。")
                        .font(.caption)
                        .foregroundStyle(colors.secondary)
                        .lineSpacing(3)
                }

                guideCard("修改课程", symbol: "square.and.pencil") {
                    Text("在自己的课表中长按课程卡片，或进入「设置」→「编辑课表」。可选择上课周次和节次；不同周的安排不同，可添加多组上课安排。同一时段有多门课程时，可在顶部切换编辑，并选择优先显示哪门课。切换会保留修改，最后点右上角「保存」一起生效。")
                        .font(.subheadline)
                        .foregroundStyle(colors.secondary)
                        .lineSpacing(4)
                }

                Link("查看 Apple 小组件操作说明", destination: URL(string: "https://support.apple.com/zh-cn/118610")!)
                    .font(.caption)
                    .foregroundStyle(colors.accent)
                    .frame(minHeight: 44)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(usesOnboardingStyle ? 24 : 16)
            .frame(maxWidth: 570)
            .frame(maxWidth: .infinity)
        }
        .background {
            if usesOnboardingStyle {
                colors.background
            } else {
                Rectangle().fill(.appBackground)
            }
        }
        .navigationTitle("使用指南")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        #endif
    }

    private func guideCard<Content: View>(_ title: String, symbol: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(colors.accent)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surface, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(colors.line, lineWidth: 1))
    }

    private func instruction(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(colors.accent)
                .frame(width: 28, height: 28)
                .background(colors.soft, in: Circle())
                .accessibilityHidden(true)
            option(title, detail: detail)
        }
        .accessibilityElement(children: .combine)
    }

    private func option(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(colors.ink)
            Text(detail).font(.subheadline).foregroundStyle(colors.secondary).lineSpacing(3)
        }
    }
}
