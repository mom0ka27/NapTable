import SwiftUI

struct PrivacyDocumentView: View {
    let liveActivities: Bool
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }
    private var paragraphs: [String] {
        (liveActivities ? PrivacyPolicy.liveText : PrivacyPolicy.basicText).components(separatedBy: "\n\n")
    }
    private var headings: [String] {
        liveActivities ? ["由你决定是否开启", "需要哪些信息", "不同系统如何处理", "如何撤回许可"] : ["我们收集哪些信息", "这些数据用于什么", "何时上报与保存多久", "你的选择与账号安全"]
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 13) {
                    Image(systemName: liveActivities ? "bell.badge" : "hand.raised")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(colors.accent)
                        .frame(width: 55, height: 55)
                        .background(colors.soft, in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityHidden(true)
                    Text(liveActivities ? PrivacyPolicy.liveTitle : PrivacyPolicy.basicTitle)
                        .font(.title2.weight(.bold)).foregroundStyle(colors.ink)
                    HStack(spacing: 8) {
                        Text(liveActivities ? "可选许可" : "开始使用前需同意")
                            .foregroundStyle(colors.accent)
                        Text("·  版本 1  ·  2026.09.23").foregroundStyle(colors.secondary)
                    }
                    .font(.caption2)
                }
                VStack(alignment: .leading, spacing: 23) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        VStack(alignment: .leading, spacing: 10) {
                            if index < headings.count {
                                Text(headings[index]).font(.subheadline.weight(.semibold)).foregroundStyle(colors.ink)
                            }
                            Text(paragraph).font(.subheadline).foregroundStyle(colors.secondary)
                                .lineSpacing(6).textSelection(.enabled)
                        }
                        if index < paragraphs.count - 1 { colors.line.frame(height: 0.5) }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.surface, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(colors.line, lineWidth: 1))
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(colors.background.ignoresSafeArea())
        .navigationTitle(liveActivities ? "实时通知许可" : "隐私协议")
        .appInlineNavigationTitle()
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        #endif
    }
}

struct LiveActivityConsentView: View {
    var onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }
    var body: some View {
        NavigationStack {
            PrivacyDocumentView(liveActivities: true)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 4) {
                        Button("同意并开启实时通知") {
                            PrivacyConsent.shared.setLiveConsent(true)
                            onAccept()
                            dismiss()
                        }
                        .buttonStyle(OnboardingPrimaryButtonStyle())
                        Button("暂不允许", role: .cancel) { dismiss() }
                            .font(.subheadline).foregroundStyle(colors.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24).padding(.top, 15)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                    .background(colors.background)
                    .overlay(alignment: .top) { colors.line.frame(height: 0.5) }
                }
        }
        .tint(colors.accent)
    }
}

struct PrivacySettingsView: View {
    @ObservedObject private var consent = PrivacyConsent.shared
    @State private var showLiveConsent = false
    var body: some View {
        Form {
            Section {
                NavigationLink(PrivacyPolicy.basicTitle) { PrivacyDocumentView(liveActivities: false) }
                LabeledContent("基础统计许可", value: consent.basicAccepted ? "已同意" : "未同意")
            } footer: {
                Text("使用 App 需同意基础统计。统计仅包含学校、系统版本、设备型号等信息，不包含课程内容。")
            }
            Section {
                NavigationLink(PrivacyPolicy.liveTitle) { PrivacyDocumentView(liveActivities: true) }
                Toggle("允许上传实时通知信息", isOn: Binding(
                    get: { consent.liveAccepted },
                    set: { value in
                        if value { showLiveConsent = true }
                        else {
                            consent.setLiveConsent(false)
                            #if os(iOS)
                            NativeLiveActivityController.shared.setEnabled(false)
                            #endif
                        }
                    }
                ))
            } footer: {
                Text("撤回后，实时通知将关闭；服务端数据将随之清除，网络不可用时将在恢复连接后完成。")
            }
        }
        .navigationTitle("隐私与数据")
        .appInlineNavigationTitle()
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .sheet(isPresented: $showLiveConsent) {
            LiveActivityConsentView {
                #if os(iOS)
                NativeLiveActivityController.shared.setEnabled(true)
                #endif
            }
        }
    }
}
