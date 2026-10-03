import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct AboutView: View {
    let tableCount: Int
    let courseCount: Int
    let dailyPeriodCount: Int

    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                appIdentity
                    .padding(.vertical, 12)

                AboutCommunityCard(colors: colors)

                scheduleSummary

                NavigationLink {
                    OpenSourceCreditsView()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "heart.text.clipboard")
                            .font(.title3)
                            .foregroundStyle(colors.accent)
                            .frame(width: 42, height: 42)
                            .background(colors.soft, in: RoundedRectangle(cornerRadius: 13))

                        VStack(alignment: .leading, spacing: 5) {
                            Text("开源鸣谢")
                                .font(.headline)
                                .foregroundStyle(colors.ink)
                            Text("感谢 \(OpenSourceProject.all.count) 个项目的分享与支持")
                                .font(.caption)
                                .foregroundStyle(colors.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(colors.secondary)
                    }
                    .aboutCard(colors: colors)
                    .contentShape(RoundedRectangle(cornerRadius: 24))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .padding(.bottom, 12)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(colors.background)
        .navigationTitle("关于")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
        .tint(colors.accent)
    }

    private var appIdentity: some View {
        VStack(spacing: 12) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(colors.line, lineWidth: 1))
                .shadow(color: colors.accent.opacity(0.12), radius: 14, y: 6)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(AppBrand.name)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(colors.ink)
                Text(AppBrand.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(colors.secondary)
            }

            Text("版本 \(appVersion)")
                .font(.caption.weight(.medium))
                .foregroundStyle(colors.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(colors.surface.opacity(0.7), in: Capsule())
        }
        .frame(maxWidth: .infinity)
    }

    private var scheduleSummary: some View {
        HStack(spacing: 12) {
            statistic(tableCount, label: "课表")
            Divider().overlay(colors.line).frame(height: 32)
            statistic(courseCount, label: "课程")
            Divider().overlay(colors.line).frame(height: 32)
            statistic(dailyPeriodCount, label: "每天节次")
        }
        .aboutCard(colors: colors)
        .accessibilityLabel("本机课表信息")
    }

    private func statistic(_ value: Int, label: String) -> some View {
        VStack(spacing: 6) {
            Text(value, format: .number)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(colors.ink)
            Text(label)
                .font(.caption)
                .foregroundStyle(colors.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)，\(value)")
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

private struct AboutCommunityCard: View {
    let colors: OnboardingColors
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var copied = false
    @State private var showOpenFailure = false

    private let groupNumber = "659786479"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                heading
                Text("聊聊使用心得，也欢迎反馈问题与建议。")
                    .font(.subheadline)
                    .foregroundStyle(colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(groupNumber)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(colors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .textSelection(.enabled)
                .accessibilityLabel("QQ群号 \(groupNumber)")

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    joinButton
                    copyButton
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        joinButton
                        copyButton
                    }
                    VStack(spacing: 10) {
                        joinButton
                        copyButton
                    }
                }
            }

            Text("无法跳转时，可在 QQ 中搜索群号加入。")
                .font(.caption)
                .foregroundStyle(colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .aboutCard(colors: colors)
        .alert("无法打开 QQ", isPresented: $showOpenFailure) {
            Button("复制群号", action: copyGroupNumber)
            Button("取消", role: .cancel) {}
        } message: {
            Text("请确认已安装 QQ，或复制群号 \(groupNumber) 后在 QQ 中搜索加入。")
        }
    }

    private var heading: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Text("用户交流群")
                .font(.headline)
                .foregroundStyle(colors.ink)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
            Label("QQ", systemImage: "bubble.left.and.bubble.right.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(colors.accent)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(colors.soft, in: Capsule())
        }
    }

    private var joinButton: some View {
        Button(action: openGroup) {
            HStack(spacing: 8) {
                Text("打开 QQ 加群")
                Image(systemName: "arrow.up.right")
            }
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 12)
            .foregroundStyle(colors.buttonText)
            .background(colors.accent, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var copyButton: some View {
        Button(action: copyGroupNumber) {
            Label(copied ? "已复制" : "复制群号", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, 12)
                .foregroundStyle(colors.accent)
                .background(colors.soft, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "群号已复制" : "复制群号")
    }

    private func openGroup() {
        guard let url = URL(string: "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=\(groupNumber)&card_type=group&source=qrcode") else {
            showOpenFailure = true
            return
        }
        openURL(url) { accepted in
            if !accepted { showOpenFailure = true }
        }
    }

    private func copyGroupNumber() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(groupNumber, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = groupNumber
        #endif
        copied = true
    }
}

private struct OpenSourceCreditsView: View {
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("感谢每一份开源的心意")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(colors.ink)
                    Text("课表设计、学校导入与数据解析，离不开以下项目的分享。点击项目可查看源码。")
                        .font(.subheadline)
                        .foregroundStyle(colors.secondary)
                        .lineSpacing(3)
                }

                VStack(spacing: 0) {
                    ForEach(OpenSourceProject.all) { project in
                        if let url = URL(string: project.urlString) {
                            Link(destination: url) {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(project.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(colors.ink)
                                        Text(project.detail)
                                            .font(.caption)
                                            .foregroundStyle(colors.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(colors.accent)
                                }
                                .padding(18)
                                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if project.id != OpenSourceProject.all.last?.id {
                            Divider().overlay(colors.line).padding(.horizontal, 18)
                        }
                    }
                }
                .background(colors.surface, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(colors.line, lineWidth: 1))
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(colors.background)
        .navigationTitle("开源鸣谢")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
        .tint(colors.accent)
    }
}

private struct OpenSourceProject: Identifiable {
    let name: String
    let detail: String
    let urlString: String
    var id: String { urlString }

    static let all: [Self] = [
        .init(name: "南哪课表", detail: "课程解析、学校配置与校历数据", urlString: "https://github.com/WheretoSleepinNJU/NJU-Class-Shedule-Flutter"),
        .init(name: "CpuTime", detail: "课表界面与玻璃拟态设计", urlString: "https://github.com/sx120609/CPU-web"),
        .init(name: "sysukcb", detail: "中山大学教务导入流程与周次解析", urlString: "https://github.com/pipidu/sysukcb"),
        .init(name: "NJFU-schedule", detail: "南京林业大学教务导入流程与课表解析", urlString: "https://github.com/keggin-CHN/NJFU-schedule"),
        .init(name: "NauCourse", detail: "南京审计大学教务导入流程与课表格式", urlString: "https://github.com/XFY9326/NauCourse"),
        .init(name: "njtech_timetable", detail: "南京工业大学教务导入流程与课表接口", urlString: "https://github.com/GiuseppeLR/njtech_timetable"),
        .init(name: "fudan-course-table-export", detail: "复旦大学新版教务课表 JSON 字段与解析参考", urlString: "https://github.com/lan-kehan/fudan-course-table-export"),
        .init(name: "DanXi", detail: "复旦本科生 print-data 课表接口与字段解析参考", urlString: "https://github.com/DanXi-Dev/DanXi"),
        .init(name: "Celechron", detail: "浙江大学教务课表接口与字段解析参考", urlString: "https://github.com/Celechron/Celechron")
    ]
}

private extension View {
    func aboutCard(colors: OnboardingColors) -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(colors.line, lineWidth: 1))
    }
}
