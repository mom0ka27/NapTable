import SwiftUI

/// The main app is not mounted until consent and a first schedule are ready.
struct AppEntryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var consent = PrivacyConsent.shared
    @ObservedObject private var cloudSync = ICloudSyncService.shared

    private var needsOnboarding: Bool {
        !consent.basicAccepted || !consent.onboardingCompleted
    }
    private var scheduleTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 16))
    }

    private var reportKey: String {
        "\(consent.basicAccepted)-\(store.selectedTable?.schoolID ?? "")-\(ScheduleSharingService.shared.validatedBaseURL?.absoluteString ?? "")"
    }
    var body: some View {
        ZStack {
            if needsOnboarding {
                OnboardingView()
                    .transition(.opacity)
                    .zIndex(1)
            } else {
                ContentView()
                    .transition(scheduleTransition)
                    .zIndex(0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? .easeInOut(duration: 0.18) : .smooth(duration: 0.4), value: needsOnboarding)
        .preferredColorScheme(store.settings.appearance.colorScheme)
        .onAppear {
            ICloudSyncService.shared.connect(store)
            ICloudSyncService.shared.setForeground(scenePhase == .active && consent.basicAccepted)
        }
        .onChange(of: consent.basicAccepted) { _, accepted in
            ICloudSyncService.shared.setForeground(scenePhase == .active && accepted)
        }
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
            ICloudSyncService.shared.setForeground(phase == .active && consent.basicAccepted)
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
                await PurchaseManager.shared.load()
                await reportUsage()
                await ScheduleSharingService.shared.refreshCurrentTerms(in: store)
            }
        }
        .sheet(isPresented: Binding(
            get: { !needsOnboarding && !cloudSync.usesSettingsReviewHost && cloudSync.isReviewPresented },
            set: { if !$0 { cloudSync.deferReview() } }
        )) {
            NavigationStack { ICloudSyncReviewView() }.environmentObject(store)
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
    @ObservedObject private var purchases = PurchaseManager.shared
    @StateObject private var scheduleStore = NativeScheduleStore()
    @State private var basicChecked: Bool
    @State private var liveChecked: Bool
    @State private var showImport = false
    @State private var showCloudSync = false
    @State private var initialSchool: String?
    @State private var liveActivationTask: Task<Void, Never>?
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
            GeometryReader { geometry in
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
                        page(bottomSafeArea: geometry.safeAreaInsets.bottom)
                            // A fresh scroll view per page, so every page starts at its top.
                            .id(step)
                            .transition(pageTransition)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
                // The import page has no footer, so its scroll viewport reaches the screen edge.
                .ignoresSafeArea(.container, edges: isImportStep ? .bottom : [])
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !isImportStep { bottomAction }
                }
            }
            .background(colors.background.ignoresSafeArea())
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .tint(colors.accent)
        .alert("实时活动提示", isPresented: Binding(
            get: { step == .live && purchases.errorMessage != nil },
            set: { if !$0 { purchases.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { purchases.errorMessage = nil }
        } message: {
            Text(purchases.errorMessage ?? "")
        }
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
        .task(id: step) {
            if step == .live { await purchases.load() }
        }
        .onDisappear { liveActivationTask?.cancel() }
        .sheet(isPresented: $showCloudSync, onDismiss: {
            let hasCourses = !store.courses.isEmpty || ScheduleSharingService.shared.sharedSchedules.contains { !$0.courses.isEmpty }
            consent.completeOnboarding(hasImportedCourses: hasCourses)
        }) {
            NavigationStack {
                ICloudSyncSettingsView(presentsReviewDuringOnboarding: true)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showCloudSync = false }
                        }
                    }
            }
            .environmentObject(store)
        }
    }

    private func page(bottomSafeArea: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch step {
                case .privacy: welcome; privacyStep
                case .live: LiveActivityIntroContent(accessMode: purchases.accessMode)
                case .importing: welcome; importStep
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24 + (isImportStep ? bottomSafeArea : 0))
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
            VStack(alignment: .leading, spacing: 1) {
                Text(AppBrand.name).font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(colors.ink)
                Text(AppBrand.subtitle).font(.caption2.weight(.medium))
                    .foregroundStyle(colors.secondary)
            }
            Spacer()
            if step == .live {
                Button("跳过") { finishLiveStep() }
                    .font(.subheadline.weight(.medium)).foregroundStyle(colors.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("继续导入课表，之后可在设置中开启实时活动")
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
        if step == .live { liveActivationTask?.cancel() }
        if steps[stepIndex - 1] == .privacy { basicChecked = consent.basicAccepted }
        go(to: steps[stepIndex - 1])
    }

    /// Accepting the basic agreement moves on to the next page.
    private func acceptPrivacy() {
        // The optional Live Activity consent is given on its own page.
        consent.acceptBasic(liveActivities: consent.liveAccepted)
        if Self.offersLiveActivities { go(to: .live) } else { enterImport() }
    }

    /// Past the Live Activity page, whether by turning it on or skipping.
    private func finishLiveStep() {
        liveActivationTask?.cancel()
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
        guard liveChecked, purchases.isBeta || (!purchases.busy && purchases.accessMode == .paid) else { return }
        #if os(iOS)
        liveActivationTask?.cancel()
        liveActivationTask = Task {
            if !purchases.allowsLiveActivities {
                if purchases.trialConsumed { await purchases.buyLifetime() }
                else { await purchases.beginTrial() }
                guard purchases.state.isEntitled else { return }
            }
            // Continuing or going back cancels this activation attempt.
            guard !Task.isCancelled, step == .live, liveChecked, purchases.allowsLiveActivities else { return }
            consent.setLiveConsent(true)
            NativeLiveActivityController.shared.setEnabled(true)
            finishLiveStep()
        }
        #else
        finishLiveStep()
        #endif
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
            Text(isImportStep ? "导入你的课程，或先用示例课表体验。" : "先了解数据如何使用，再开启你的校园日常。")
                .font(.subheadline).foregroundStyle(colors.secondary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyStep: some View {
        VStack(spacing: 12) {
            OnboardingPermissionCard(
                title: "基础隐私协议",
                summary: "上传学校标识、系统版本、设备型号、App 版本与随机安装标识，用于使用统计与兼容性改进。",
                symbol: "chart.bar.xaxis", optional: false
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
                        Text("从学校列表中选择，或手动 / 图片导入").font(.caption).foregroundStyle(colors.secondary)
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
            .accessibilityLabel("其他学校，从列表选择或手动、图片导入课表")

            Button { showCloudSync = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(colors.accent)
                        .frame(width: 52, height: 52)
                        .background(colors.soft, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("从 iCloud 同步已有课表").font(.headline).foregroundStyle(colors.ink)
                        Text("同一 Apple 账号，继续使用其他设备上的课表")
                            .font(.caption).foregroundStyle(colors.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.subheadline).foregroundStyle(colors.accent)
                }
                .padding(18)
                .background(colors.surface, in: RoundedRectangle(cornerRadius: 21))
                .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(colors.line, lineWidth: 1))
            }
            .buttonStyle(.plain)

            demoCard

            NavigationLink {
                ScheduleUsageGuideScreen(usesOnboardingStyle: true)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                    Text("使用指南")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(colors.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield").font(.caption)
                Text("账号密码仅在学校页面输入。也可以先用示例课表体验，之后再导入自己的课程。")
                    .font(.caption2).lineSpacing(3)
            }
            .foregroundStyle(colors.secondary)
        }
    }

    private var demoCard: some View {
        Button {
            store.installDemoSchedule()
            store.saveNow()
            consent.completeOnboarding(hasImportedCourses: !store.currentCourses.isEmpty)
        } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 14) {
                    Image(systemName: "desktopcomputer")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(colors.accent)
                        .frame(width: 52, height: 52)
                        .background(colors.soft, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("导入示例课表").font(.headline).foregroundStyle(colors.ink)
                        Text("体验课表功能")
                            .font(.caption).foregroundStyle(colors.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.down.doc")
                        .font(.subheadline).foregroundStyle(colors.accent)
                }
                Text("切换周次体验单双周和指定周次，点击「自由时间课程」查看实践课。示例课程可编辑或删除。")
                    .font(.caption).foregroundStyle(colors.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(colors.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 21))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("导入示例课表")
        .accessibilityHint("无需登录，包含单双周、指定周次和自由时间课程，导入后开始使用")
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
            OnboardingConsentNote(agreed: $liveChecked, liveActivities: true)
            Button {
                if purchases.accessMode == .unavailable { Task { await purchases.load() } }
                else { enableLive() }
            } label: {
                HStack {
                    Spacer()
                    if purchases.isBeta {
                        Text("免费开启并继续")
                    } else if purchases.accessMode == .loading {
                        ProgressView().controlSize(.small)
                        Text("正在连接服务器…")
                    } else if purchases.accessMode == .unavailable {
                        Text("重新连接")
                    } else if purchases.busy || purchases.state == .loading {
                        ProgressView().controlSize(.small)
                        Text(purchases.busy ? "正在确认…" : "正在读取购买信息…")
                    } else {
                        Text(purchases.state.isEntitled ? "开启并继续" : (purchases.trialConsumed ? "一次买断并开启" : "开始 30 天试用并开启"))
                    }
                    Spacer()
                    Image(systemName: "arrow.right").font(.subheadline.weight(.semibold))
                }
                    .padding(.horizontal, 20)
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(!liveChecked || purchases.accessMode == .loading || (!purchases.isBeta && purchases.accessMode == .paid && (purchases.busy || purchases.state == .loading || purchases.state == .unavailable)))
            if purchases.isBeta {
                Text("Beta 版本免费使用，无需试用或购买。")
                    .font(.caption2).foregroundStyle(colors.secondary)
                    .multilineTextAlignment(.center)
            } else if purchases.accessMode == .unavailable {
                Text("连接失败，请重试或点右上角「跳过」。")
                    .font(.caption2).foregroundStyle(colors.secondary)
                    .multilineTextAlignment(.center)
            } else if purchases.state == .unavailable {
                Text("试用与购买暂不可用，可点右上角「跳过」，之后在设置中开启。")
                    .font(.caption2).foregroundStyle(colors.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24).padding(.top, 15).padding(.bottom, 10)
        .frame(maxWidth: 570)
        .frame(maxWidth: .infinity)
        .background(colors.background)
        .overlay(alignment: .top) { colors.line.frame(height: 0.5) }
    }

    private var primaryAction: some View {
        VStack(spacing: 10) {
            OnboardingConsentNote(agreed: $basicChecked)
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
