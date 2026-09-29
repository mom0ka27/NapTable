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
    @State private var basicChecked: Bool
    @State private var liveChecked: Bool
    @State private var showImport = false
    @State private var initialSchool: String?
    /// Where the user is. Navigation is explicit: skipping a page only moves
    /// past it, so going back (or forward again) still passes through it.
    @State private var step: Step
    /// Direction of the last page change, for the slide.
    @State private var forward = true
    /// The Live Activity page was dealt with once: turned on, or skipped.
    /// Only used to resume onboarding at the right page after a relaunch.
    @AppStorage(Self.liveStepDoneKey) private var liveStepDone = false
    private static let liveStepDoneKey = "naptable.onboarding.liveStepDone"
    private enum Step: Int { case privacy, live, importing }
    private var isImportStep: Bool { step == .importing }
    private var steps: [Step] { Self.offersLiveActivities ? [.privacy, .live, .importing] : [.privacy, .importing] }
    private var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }

    init() {
        let consent = PrivacyConsent.shared
        let liveDone = UserDefaults.standard.bool(forKey: Self.liveStepDoneKey)
        let initial: Step = !consent.basicAccepted ? .privacy
            : Self.offersLiveActivities && !liveDone ? .live : .importing
        _step = State(initialValue: initial)
        _basicChecked = State(initialValue: consent.basicAccepted)
        _liveChecked = State(initialValue: consent.liveAccepted)
    }
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
            VStack(spacing: 0) {
                // Header and progress stay put; only the page below slides.
                VStack(alignment: .leading, spacing: 14) {
                    brandHeader
                    progress
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .frame(maxWidth: 570)
                .frame(maxWidth: .infinity)
                ZStack {
                    page
                        // A fresh scroll view per page, so every page starts at its top.
                        .id(step)
                        .transition(pageTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
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

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch step {
                case .privacy: welcome; privacyStep
                case .live: LiveActivityIntroContent()
                case .importing: welcome; importStep
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: 570)
            .frame(maxWidth: .infinity)
        }
    }

    /// Pages push in from the side they come from, like a navigation stack.
    private var pageTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            // The slot is always there, so the logo never shifts when it appears.
            Button { goBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(colors.accent)
                    .frame(width: 28, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(stepIndex > 0 ? 1 : 0)
            .disabled(stepIndex == 0)
            .accessibilityHidden(stepIndex == 0)
            .accessibilityLabel("返回上一步")
            .padding(.trailing, -4)
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
                    .accessibilityHint("不开启实时活动，之后可在设置中开启")
            }
        }
    }

    private func go(to next: Step) {
        let isForward = next.rawValue > step.rawValue
        guard isForward != forward else { return withAnimation(.smooth(duration: 0.35)) { step = next } }
        // The leaving page keeps the transition of its last render: let it
        // pick up the new direction first, then change page.
        forward = isForward
        DispatchQueue.main.async { withAnimation(.smooth(duration: 0.35)) { step = next } }
    }

    private func goBack() {
        guard stepIndex > 0 else { return }
        if steps[stepIndex - 1] == .privacy { basicChecked = consent.basicAccepted }
        go(to: steps[stepIndex - 1])
    }

    /// Accepting the basic agreement moves on to the next page.
    private func acceptPrivacy() {
        // The Live Activity consent is given on its own page, by signing in.
        consent.acceptBasic(liveActivities: consent.liveAccepted)
        if Self.offersLiveActivities { go(to: .live) } else { enterImport() }
    }

    /// Past the Live Activity page, whether by turning it on or skipping.
    private func finishLiveStep() {
        liveStepDone = true
        enterImport()
    }

    /// Someone who already has courses (an upgrade) is done with onboarding
    /// here; everyone else goes on to import.
    private func enterImport() {
        if !store.courses.isEmpty {
            store.saveNow()
            consent.completeOnboarding(hasImportedCourses: true)
        } else {
            go(to: .importing)
        }
    }

    private func enableLive() {
        consent.setLiveConsent(true)
        #if os(iOS)
        NativeLiveActivityController.shared.setEnabled(true)
        #endif
        finishLiveStep()
    }

    private var progress: some View {
        let titles = steps.map { step -> String in
            switch step { case .privacy: "隐私许可"; case .live: "实时活动"; case .importing: "导入课表" }
        }
        let current = stepIndex
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

            Button {
                initialSchool = nil
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
                        Text("其他学校").font(.headline).foregroundStyle(colors.ink)
                        Text("从学校列表中选择，或手动创建课表").font(.caption).foregroundStyle(colors.secondary)
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
            .accessibilityLabel("其他学校，从列表选择或手动创建课表")

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
        switch step {
        case .privacy: primaryAction
        case .live: liveAction
        // 导入页直接点学校卡片进入，不再有底部按钮。
        case .importing: EmptyView()
        }
    }

    private var liveAction: some View {
        VStack(spacing: 10) {
            LiveActivityConsentNote(agreed: $liveChecked)
            Button { enableLive() } label: {
                HStack { Spacer(); Text(consent.liveAccepted ? "已开启，继续" : "开启实时活动"); Spacer(); Image(systemName: "arrow.right").font(.subheadline.weight(.semibold)) }
                    .padding(.horizontal, 20)
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(!liveChecked)
        }
        .padding(.horizontal, 24).padding(.top, 15).padding(.bottom, 10)
        .frame(maxWidth: 570)
        .frame(maxWidth: .infinity)
        .background(colors.background)
        .overlay(alignment: .top) { colors.line.frame(height: 0.5) }
    }

    private var primaryAction: some View {
        VStack(spacing: 10) {
            Button { acceptPrivacy() } label: {
                HStack {
                    Spacer()
                    Text("同意并继续")
                    Spacer()
                    Image(systemName: "arrow.right").font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 20)
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(!basicChecked)
            Text("基础协议为必选；实时通知在下一步决定")
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
