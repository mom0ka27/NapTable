import SwiftUI

struct PrivacyDocumentView: View {
    let liveActivities: Bool
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }
    /// 标题和正文由协议成对提供，这里只负责排版。
    private var clauses: [PrivacyPolicy.Clause] {
        liveActivities ? PrivacyPolicy.liveClauses : PrivacyPolicy.basicClauses
    }
    private var title: String { liveActivities ? PrivacyPolicy.liveTitle : PrivacyPolicy.basicTitle }
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
                    Text(title)
                        .font(.title2.weight(.bold)).foregroundStyle(colors.ink)
                    HStack(spacing: 8) {
                        Text(liveActivities ? "可选许可" : "开始使用前需同意")
                            .foregroundStyle(colors.accent)
                        Text("·  版本 \(PrivacyPolicy.version)  ·  \(PrivacyPolicy.updatedAt)").foregroundStyle(colors.secondary)
                    }
                    .font(.caption2)
                }
                VStack(alignment: .leading, spacing: 23) {
                    ForEach(Array(clauses.enumerated()), id: \.offset) { index, clause in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(clause.title).font(.subheadline.weight(.semibold)).foregroundStyle(colors.ink)
                            Text(clause.body).font(.subheadline).foregroundStyle(colors.secondary)
                                .lineSpacing(6).textSelection(.enabled)
                        }
                        if index < clauses.count - 1 { colors.line.frame(height: 0.5) }
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
        .navigationTitle(liveActivities ? "实时活动许可" : "隐私协议")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
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
                        Button("同意并开启实时活动") {
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
                Text("使用 App 需同意基础统计。统计包含学校、系统版本、设备型号、App 版本及风格、背景图、小组件和实时活动的启用状态，不包含课程内容或背景图片。")
            }
            Section {
                NavigationLink(PrivacyPolicy.liveTitle) { PrivacyDocumentView(liveActivities: true) }
                Toggle("允许上传实时活动信息", isOn: Binding(
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
                Text("撤回后，实时活动将关闭；服务端数据将随之清除，网络不可用时将在恢复连接后完成。")
            }
        }
        .appListBackground()
        .navigationTitle("隐私与数据")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
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
