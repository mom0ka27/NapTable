import SwiftUI

/// The main app is not mounted until consent and a real first import are complete.
struct AppEntryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var consent = PrivacyConsent.shared

    private var reportKey: String {
        "\(consent.basicAccepted)-\(store.selectedTable?.schoolID ?? "")-\(ScheduleSharingService.shared.validatedBaseURL?.absoluteString ?? "")"
    }
    var body: some View {
        Group {
            if !consent.basicAccepted || !consent.onboardingCompleted {
                OnboardingView()
            } else {
                ContentView()
            }
        }
        .preferredColorScheme(store.settings.appearance.colorScheme)
        .task(id: reportKey) {
            guard consent.basicAccepted else { return }
            await reportUsage()
        }
        .task(id: consent.basicAccepted) {
            guard consent.basicAccepted else { return }
            await ScheduleSharingService.shared.refreshCurrentTerms(in: store)
            store.refreshForToday()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            #if os(iOS)
            // Revocation retries remain possible even when the optional permission is off.
            if #available(iOS 17.2, *) {
                Task { await LiveActivityPushService.shared.refreshStatus() }
            }
            #endif
            guard consent.basicAccepted else { return }
            store.refreshForToday()
            Task {
                await reportUsage()
                await ScheduleSharingService.shared.refreshCurrentTerms(in: store)
            }
        }
    }
    private func reportUsage() async {
        await UsageReportingService.shared.report(schoolID: store.selectedTable?.schoolID,
                                                  baseURL: ScheduleSharingService.shared.validatedBaseURL)
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var consent = PrivacyConsent.shared
    @StateObject private var scheduleStore = NativeScheduleStore()
    @ObservedObject private var account = AccountService.shared
    @State private var basicChecked = false
    @State private var showImport = false
    @State private var initialSchool: String?
    @State private var reviewingPrivacy = false
    /// The Live Activity page was dealt with: signed in, or skipped.
    @AppStorage("naptable.onboarding.liveStepDone") private var liveStepDone = false
    private enum Step { case privacy, live, importing }
    private var step: Step {
        if !consent.basicAccepted || reviewingPrivacy { return .privacy }
        return Self.offersLiveActivities && !liveStepDone ? .live : .importing
    }
    private var isImportStep: Bool { step == .importing }
    /// Reminders need iOS 18; before that there is only the preview, and nothing to sign in for.
    private static var offersLiveActivities: Bool {
        #if os(iOS)
        if #available(iOS 18.0, *) { return true }
        #endif
        return false
    }
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    brandHeader
                    progress
                    switch step {
                    case .privacy: welcome; privacyStep
                    case .live: LiveActivitySignInContent()
                    case .importing: welcome; importStep
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: 570)
                .frame(maxWidth: .infinity)
            }
            .background(colors.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomAction }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .tint(colors.accent)
        .sheet(isPresented: $showImport) {
            ImportView(requiresImport: true, initialSchool: initialSchool) {
                store.saveNow()
                consent.completeOnboarding(hasImportedCourses: !store.courses.isEmpty)
            }
            .environmentObject(store)
            .environmentObject(scheduleStore)
            .interactiveDismissDisabled()
        }
        .onAppear { scheduleStore.connect(store) }
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            Text("你以为课表").font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(colors.ink)
            Spacer()
            if step == .live {
                Button("跳过") { finishLiveStep() }
                    .font(.subheadline.weight(.medium)).foregroundStyle(colors.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("不开启实时活动，之后可在设置中登录")
            }
        }
    }

    /// Past the Live Activity page. Someone who already has courses (an
    /// upgrade) is done with onboarding here; everyone else goes on to import.
    private func finishLiveStep() {
        liveStepDone = true
        if !store.courses.isEmpty { store.saveNow(); consent.completeOnboarding(hasImportedCourses: true) }
    }

    private func signedIn() {
        consent.setLiveConsent(true)
        #if os(iOS)
        NativeLiveActivityController.shared.setEnabled(true)
        #endif
        finishLiveStep()
    }

    private var progress: some View {
        let titles = Self.offersLiveActivities ? ["隐私许可", "实时活动", "导入课表"] : ["隐私许可", "导入课表"]
        let current = step == .privacy ? 0 : step == .live ? 1 : titles.count - 1
        return HStack(spacing: 12) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                progressItem(String(format: "%02d", index + 1), title: title, complete: index < current, active: index == current)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(current + 1) 步，共 \(titles.count) 步，\(titles[current])")
    }

    private func progressItem(_ number: String, title: String, complete: Bool, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Capsule().fill(active || complete ? colors.accent : colors.line).frame(height: 3)
            HStack(spacing: 6) {
                if complete { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                else { Text(number).font(.system(.caption2, design: .monospaced)) }
                Text(title).font(.caption.weight(active ? .semibold : .regular))
            }
            .foregroundStyle(active || complete ? colors.accent : colors.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            OnboardingArtwork(importing: isImportStep)
                .padding(.top, -9)
                .padding(.bottom, 2)
            Text(isImportStep ? "把新学期，装进口袋。" : "新学期，从容开始。")
                .font(.system(.title, design: .rounded).weight(.bold))
                .tracking(-0.7)
                .foregroundStyle(colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(isImportStep ? "连接学校教务系统，把课程带进你的日常。" : "先了解数据如何使用，再开启你的校园日常。")
                .font(.subheadline).foregroundStyle(colors.secondary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyStep: some View {
        VStack(spacing: 12) {
            OnboardingPermissionCard(
                title: "基础隐私协议",
                summary: "上传学校标识、系统版本、设备型号、App 版本与随机安装标识，用于使用统计与兼容性改进。",
                symbol: "chart.bar.xaxis", optional: false, accepted: $basicChecked
            )
            Label("基础统计不包含课程内容或学校账号密码", systemImage: "lock.shield")
                .font(.caption2).foregroundStyle(colors.secondary)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var importStep: some View {
        VStack(alignment: .leading, spacing: 17) {
            schoolCard("南京大学", glyph: "南", detail: "本科生 · 研究生教务入口")
            schoolCard("中山大学", glyph: "中", detail: "本科生教务入口")

            Button {
                initialSchool = ImportView.manualRoute
                showImport = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "square.and.pencil")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(colors.accent)
                        .frame(width: 52, height: 52)
                        .background(colors.soft, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("学校不在列表里").font(.headline).foregroundStyle(colors.ink)
                        Text("自己设学期、节次，逐门添加课程").font(.caption).foregroundStyle(colors.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.subheadline).foregroundStyle(colors.accent)
                }
                .padding(18)
                .background(colors.surface, in: RoundedRectangle(cornerRadius: 21))
                .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(colors.line, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 21))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("学校不在列表里，手动创建课表")

            VStack(alignment: .leading, spacing: 0) {
                importInstruction("1", title: "选择教务入口", detail: "找到适合你的本科生或研究生系统。", last: false)
                importInstruction("2", title: "登录并确认课程", detail: "在学校页面登录，核对课程与学期。", last: false)
                importInstruction("3", title: "开始使用课表", detail: "完成导入后，课表和小组件就准备好了。", last: true)
            }
            .padding(19)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(colors.line, lineWidth: 1))
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield").font(.caption)
                Text("账号密码仅在学校页面输入。首次使用需导入或手动添加至少一门课程，取消或空课表不会完成引导。")
                    .font(.caption2).lineSpacing(3)
            }
            .foregroundStyle(colors.secondary)
            Button {
                basicChecked = consent.basicAccepted
                reviewingPrivacy = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("返回上一步")
                }
                .font(.caption).foregroundStyle(colors.accent).frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private func schoolCard(_ name: String, glyph: String, detail: String) -> some View {
        Button {
            initialSchool = name
            showImport = true
        } label: {
            HStack(spacing: 14) {
                Text(glyph)
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(colors.accent)
                    .frame(width: 52, height: 52)
                    .background(colors.soft, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(name).font(.headline).foregroundStyle(colors.ink)
                    Text(detail).font(.caption).foregroundStyle(colors.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right").font(.subheadline).foregroundStyle(colors.accent)
            }
            .padding(18)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(colors.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 21))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择\(name)教务入口并导入课表")
    }

    private func importInstruction(_ number: String, title: String, detail: String, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 5) {
                Text(number).font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(colors.accent).frame(width: 25, height: 25)
                    .background(colors.soft, in: Circle())
                if !last { Rectangle().fill(colors.line).frame(width: 1, height: 26) }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(colors.ink)
                Text(detail).font(.caption).foregroundStyle(colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, last ? 0 : 21)
        }
    }

    @ViewBuilder private var bottomAction: some View {
        if step == .live { liveAction } else { primaryAction }
    }

    private var liveAction: some View {
        VStack(spacing: 10) {
            if account.isSignedIn {
                Button { signedIn() } label: {
                    HStack { Spacer(); Text("开启实时活动"); Spacer(); Image(systemName: "arrow.right").font(.subheadline.weight(.semibold)) }
                        .padding(.horizontal, 20)
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
            } else {
                AccountSignInButton { signedIn() }
            }
            AccountConsentNote()
        }
        .padding(.horizontal, 24).padding(.top, 15).padding(.bottom, 10)
        .frame(maxWidth: 570)
        .frame(maxWidth: .infinity)
        .background(colors.background)
        .overlay(alignment: .top) { colors.line.frame(height: 0.5) }
    }

    private var primaryAction: some View {
        VStack(spacing: 10) {
            Button {
                if isImportStep {
                    if store.courses.isEmpty {
                        initialSchool = nil
                        showImport = true
                    }
                    else {
                        store.saveNow()
                        consent.completeOnboarding(hasImportedCourses: true)
                    }
                } else {
                    // The Live Activity consent is given on its own page, by signing in.
                    consent.acceptBasic(liveActivities: consent.liveAccepted)
                    reviewingPrivacy = false
                    // Existing users retain their imported courses during the upgrade.
                    if !store.courses.isEmpty, step == .importing { consent.completeOnboarding(hasImportedCourses: true) }
                }
            } label: {
                HStack {
                    Spacer()
                    Text(isImportStep ? (store.courses.isEmpty ? "选择入口，导入课表" : "查看已导入的课表") : "同意并继续")
                    Spacer()
                    Image(systemName: "arrow.right").font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 20)
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(!isImportStep && !basicChecked)
            Text(isImportStep ? "导入或添加课程后，即可进入主界面" : "基础协议为必选；实时通知在下一步决定")
                .font(.caption2).foregroundStyle(colors.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24).padding(.top, 15).padding(.bottom, 10)
        .frame(maxWidth: 570)
        .frame(maxWidth: .infinity)
        .background(colors.background)
        .overlay(alignment: .top) { colors.line.frame(height: 0.5) }
    }
}
