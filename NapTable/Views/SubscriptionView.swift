import SwiftUI
import StoreKit

struct SubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var purchases = PurchaseManager.shared
    @State private var selectedTier: EntitlementTier = .pro
    var reminder: TrialReminder? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let reminder {
                    trialHeader(reminder)
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                        .padding(.bottom, 28)
                    // Keep the same benefits and StoreKit controls as the
                    // entitlement deck, fully readable on the reminder page.
                    EntitlementCard(tier: .pro)
                        .padding(.horizontal, 24)
                    Text("课表管理、分享、基础小组件和 iCloud 同步继续免费使用，你的课表数据会保留。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 24)
                    Button(reminder.expiresAt <= Date() ? "继续使用免费版" : "稍后再说") { dismiss() }
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 48)
                        .padding(.bottom, 24)
                } else {
                    tierPicker
                        .padding(.top, 8)
                    EntitlementCardDeck(selectedTier: $selectedTier)
                        .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(.appGroupedBackground)
        .navigationTitle(reminder == nil ? "版本与权益" : "专业版试用")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
        .task { await purchases.load() }
        .alert("购买提示", isPresented: Binding(
            get: { purchases.errorMessage != nil },
            set: { if !$0 { purchases.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { purchases.errorMessage = nil }
        } message: {
            Text(purchases.errorMessage ?? "")
        }
    }

    private func trialHeader(_ reminder: TrialReminder) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let expired = reminder.expiresAt <= context.date
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: expired ? "sparkles" : "hourglass")
                    Text(expired ? "感谢这 30 天的体验" : "试用即将结束")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(EntitlementTier.bunnyText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(EntitlementTier.bunnyTint(white: 0.83), in: Capsule())

                Text(expired ? "30 天试用已结束" : "30 天试用即将结束")
                    .font(.largeTitle.bold())
                    .tracking(-0.7)
                    .fixedSize(horizontal: false, vertical: true)
                Text(expired
                     ? "继续使用以下专业版功能，需要一次买断。谢谢你让 NapTable 陪伴每一堂课。"
                     : "试用将于 \(reminder.expiresAt.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN"))))结束。一次买断，即可继续使用以下专业版功能。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("试用到期不会自动扣款", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tierPicker: some View {
        HStack(spacing: 4) {
            ForEach(EntitlementTier.allCases) { tier in
                Button {
                    selectedTier = tier
                } label: {
                    Text(tier.title)
                        .font(.caption.weight(selectedTier == tier ? .semibold : .regular))
                        .foregroundStyle(selectedTier == tier ? Color.primary : Color.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background {
                            if selectedTier == tier {
                                Capsule().fill(Color.primary.opacity(0.05))
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTier == tier ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("切换版本")
    }
}

/// Shared vocabulary keeps the settings entry and the purchase page aligned.
private enum ProBenefit: CaseIterable, Identifiable {
    case liveActivity, themes, widgetBackground
    var id: Self { self }
    var icon: String {
        switch self {
        case .liveActivity: "rectangle.topthird.inset.filled"
        case .themes: "photo.on.rectangle.angled"
        case .widgetBackground: "square.grid.2x2"
        }
    }
    var title: String {
        switch self {
        case .liveActivity: "实时活动"
        case .themes: "高级主题设置"
        case .widgetBackground: "小组件背景图片"
        }
    }
    var shortTitle: String {
        switch self {
        case .liveActivity: "实时活动"
        case .themes: "高级主题"
        case .widgetBackground: "小组件背景"
        }
    }
    var detail: String {
        switch self {
        case .liveActivity: "锁屏与灵动岛上的课程和倒计时"
        case .themes: "每张课表可为浅色与深色模式分别设置背景图"
        case .widgetBackground: "为浅色与深色小组件选择图片，调整裁剪与不透明度"
        }
    }
}

/// The first item in Settings makes both the paid features and current access
/// visible without requiring someone to discover the help section.
struct SubscriptionSettingsCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var purchases = PurchaseManager.shared
    private var accent: Color {
        colorScheme == .dark ? EntitlementTier.bunnyHighlight : EntitlementTier.bunnyText
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundStyle(accent)
                        .frame(width: 46, height: 46)
                        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 15))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("NapTable 专业版")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Text(status(at: context.date))
                            .font(.caption)
                            .foregroundStyle(accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
                layout {
                    ForEach(ProBenefit.allCases) { benefit in
                        HStack(spacing: 5) {
                            Image(systemName: benefit.icon)
                                .imageScale(.small)
                                .accessibilityHidden(true)
                            Text(benefit.shortTitle)
                        }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack {
                    Text("查看专业版权益")
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
                .padding(.top, 14)
                .overlay(alignment: .top) { Rectangle().fill(accent.opacity(0.13)).frame(height: 0.5) }
            }
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 24)
                    .fill(LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color(red: 0.25, green: 0.16, blue: 0.18), Color(red: 0.16, green: 0.12, blue: 0.15)]
                            : [EntitlementTier.bunnyTint(white: 0.78), EntitlementTier.bunnyTint(white: 0.93)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            }
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(accent.opacity(0.12), lineWidth: 0.5) }
        }
    }

    private func status(at now: Date) -> String {
        if purchases.isBeta { return "Beta 期间免费体验全部专属功能" }
        guard purchases.accessMode == .paid else { return purchases.versionDetail }
        if case .trial(let expiresAt) = purchases.state {
            let remaining = expiresAt.timeIntervalSince(now)
            if remaining <= 0 { return "30 天试用已结束 · 查看解锁方式" }
            if remaining < 24 * 60 * 60 { return "试用剩余不足 1 天 · 到期不自动扣款" }
            return "30 天免费试用中 · 剩余 \(Int(ceil(remaining / 86400))) 天"
        }
        if purchases.state == .lifetime { return "已永久解锁 · 感谢你的支持" }
        if let expiresAt = purchases.trialExpiresAt, expiresAt <= now {
            return "30 天试用已结束 · 查看解锁方式"
        }
        if purchases.state == .locked && !purchases.trialConsumed { return "免费试用 30 天 · 专属功能等你体验" }
        return purchases.versionDetail
    }
}

/// Purchase controls live inside the professional card and follow its palette.
private struct EntitlementPurchaseActions: View {
    @ObservedObject private var purchases = PurchaseManager.shared
    let accent: Color
    let muted: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if purchases.isBeta {
                status("Beta 期间免费使用全部专业版功能", icon: "gift")
            } else if purchases.accessMode == .loading {
                loading("正在读取权益…")
            } else if purchases.accessMode == .unavailable {
                status("连接失败，请联网后重试", icon: "wifi.exclamationmark")
                Button("重试") { Task { await purchases.load() } }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(minHeight: 44)
            } else {
                paidActions
            }
        }
    }

    @ViewBuilder
    private var paidActions: some View {
        switch purchases.state {
        case .loading:
            loading("正在读取购买状态…")
        case .lifetime:
            status("已永久解锁", icon: "checkmark.seal.fill")
        case .trial(let expiresAt):
            status(expiresAt <= Date() ? "30 天试用已结束" : "试用至 \(formattedDate(expiresAt))", icon: "gift")
        case .locked:
            if !purchases.trialConsumed {
                purchaseButton(
                    "免费试用 30 天", detail: "到期不自动扣款", prominent: false,
                    productID: PurchaseManager.trialProductID
                ) { await purchases.beginTrial() }
            } else if let expiresAt = purchases.trialExpiresAt, expiresAt <= Date() {
                status("30 天试用已结束", icon: "clock")
            }
        case .unavailable:
            status("购买暂不可用，请稍后重试", icon: "info.circle")
            Button("重新获取价格") { Task { await purchases.load() } }
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .frame(minHeight: 44)
        }

        if purchases.state != .lifetime && purchases.state != .loading {
            purchaseButton(
                "一次买断专业版",
                detail: purchases.products.first { $0.id == PurchaseManager.lifetimeProductID }?.displayPrice ?? "价格待获取",
                prominent: true,
                productID: PurchaseManager.lifetimeProductID
            ) { await purchases.buyLifetime() }
            Text("一次付费，永久解锁 · 无自动续费")
                .font(.caption2)
                .foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func purchaseButton(
        _ title: String, detail: String, prominent: Bool,
        productID: String, action: @escaping () async -> Void
    ) -> some View {
        let available = purchases.products.contains { $0.id == productID }
        return Button {
            Task { await action() }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if !prominent {
                        Text(detail).font(.caption2).foregroundStyle(muted)
                    }
                }
                Spacer(minLength: 0)
                if purchases.busy {
                    ProgressView().tint(prominent ? .white : accent)
                } else if prominent {
                    Text(detail).font(.subheadline.weight(.semibold))
                } else {
                    Image(systemName: "arrow.right").font(.caption)
                }
            }
            .foregroundStyle(prominent ? .white : accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(prominent ? EntitlementTier.bunnyText : accent.opacity(0.06))
            }
            .opacity(available ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(purchases.busy || !available)
    }

    private func status(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(accent)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func loading(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(accent)
            Text(text).font(.caption).foregroundStyle(muted)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN")))
    }
}

private enum EntitlementTier: Int, CaseIterable, Identifiable {
    case free, pro
    var id: Int { rawValue }
    var other: Self { self == .free ? .pro : .free }
    var title: String { self == .free ? "免费版" : "专业版" }
    var accent: Color { self == .free ? Color(red: 0.27, green: 0.45, blue: 0.66) : Self.bunnyPink }
    var shadowColor: Color { self == .free ? Color(red: 0.32, green: 0.42, blue: 0.54) : Self.bunnyPink }
    static let ink = Color(red: 0.12, green: 0.17, blue: 0.25)
    private static let bunnyRGB = ScheduleLiveActivityTheme.bunny.brandColor
    static let bunnyPink = bunnyTint(white: 0)
    static let bunnyHighlight = bunnyTint(white: 0.38)
    static let bunnyText = Color(red: bunnyRGB.red * 0.72, green: bunnyRGB.green * 0.72, blue: bunnyRGB.blue * 0.72)

    static func bunnyTint(white: Double) -> Color {
        Color(
            red: bunnyRGB.red * (1 - white) + white,
            green: bunnyRGB.green * (1 - white) + white,
            blue: bunnyRGB.blue * (1 - white) + white
        )
    }
}

// Signed turns let both cards follow the drag in either direction.
private struct EntitlementCardDeck: View {
    @Binding var selectedTier: EntitlementTier
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turn: CGFloat
    @State private var presentation: EntitlementCardPresentation
    @State private var dragOrigin: CGFloat?
    @State private var measuredCardHeight: CGFloat = 438
    @GestureState private var gestureActive = false

    private static var settleAnimation: Animation {
        .interactiveSpring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.08)
    }

    init(selectedTier: Binding<EntitlementTier>) {
        _selectedTier = selectedTier
        let initialTurn = CGFloat(selectedTier.wrappedValue.rawValue)
        _turn = State(initialValue: initialTurn)
        _presentation = State(initialValue: EntitlementCardPresentation(turn: initialTurn))
    }

    var body: some View {
        GeometryReader { geometry in
            let cardWidth = max(1, geometry.size.width - 80)
            let tiltScale = min(1, 500 / max(measuredCardHeight, 1))
            ZStack {
                ForEach(EntitlementTier.allCases) { tier in
                    let isFront = tier == selectedTier
                    EntitlementCard(tier: tier)
                        .frame(width: cardWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { cardGeometry in
                                Color.clear.preference(key: EntitlementCardHeightKey.self, value: cardGeometry.size.height)
                            }
                        }
                        .shadow(
                            color: tier.shadowColor.opacity(colorScheme == .dark ? 0.25 : (isFront ? 0.16 : 0.08)),
                            radius: isFront ? 18 : 9,
                            x: 0,
                            y: isFront ? 12 : 6
                        )
                        .modifier(EntitlementCardFlip(
                            tier: tier, turn: turn,
                            cardWidth: cardWidth, tiltScale: tiltScale,
                            reduceMotion: reduceMotion, presentation: presentation
                        ))
                        .allowsHitTesting(isFront)
                        .accessibilityHidden(!isFront)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(pagingGesture(travel: cardWidth))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(selectedTier.title)权益，\(selectedTier.rawValue + 1) / 2")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: selectedTier = .pro
                case .decrement: selectedTier = .free
                @unknown default: break
                }
            }
        }
        .frame(height: measuredCardHeight + 64)
        .onPreferenceChange(EntitlementCardHeightKey.self) { height in
            if height > 0, abs(height - measuredCardHeight) > 0.5 {
                measuredCardHeight = height
            }
        }
        .onChange(of: selectedTier) { oldTier, tier in
            // A completed drag already updated the turn and selection together.
            guard tierAtRest(turn) != tier else { return }
            dragOrigin = nil
            settle(to: turn.rounded() + (tier.rawValue > oldTier.rawValue ? 1 : -1))
        }
        .onChange(of: gestureActive) { _, active in
            // A system-cancelled drag also returns to a resting card.
            guard !active, let origin = dragOrigin else { return }
            dragOrigin = nil
            settle(to: origin.rounded())
        }
    }

    private func pagingGesture(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                if dragOrigin == nil {
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
                    // Grab the visible pose even if the previous spring is moving.
                    dragOrigin = presentation.turn
                }
                guard let origin = dragOrigin else { return }
                let progress = max(-1, min(1, -value.translation.width / travel))
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    turn = origin + progress
                    presentation.turn = turn
                }
            }
            .onEnded { value in
                guard let origin = dragOrigin else { return }
                dragOrigin = nil
                let destination = EntitlementCardPaging.destination(
                    origin: origin, translation: value.translation.width,
                    predictedTranslation: value.predictedEndTranslation.width, travel: travel
                )
                settle(to: destination)
            }
    }

    private func tierAtRest(_ value: CGFloat) -> EntitlementTier {
        Int(value.rounded()).isMultiple(of: 2) ? .free : .pro
    }

    private func settle(to destination: CGFloat) {
        withAnimation(reduceMotion ? nil : Self.settleAnimation) {
            turn = destination
            selectedTier = tierAtRest(destination)
        }
        if reduceMotion { presentation.turn = destination }
    }
}

private enum EntitlementCardPaging {
    static func destination(
        origin: CGFloat, translation: CGFloat, predictedTranslation: CGFloat, travel: CGFloat
    ) -> CGFloat {
        let restingTurn = origin.rounded()
        // Prediction lets a quick flick commit while a short, slow drag returns.
        if abs(translation) > 12, abs(predictedTranslation) > travel * 0.4 {
            let projectedTurn = origin - predictedTranslation / travel
            let target = predictedTranslation < 0 ? ceil(projectedTurn) : floor(projectedTurn)
            return max(restingTurn - 1, min(restingTurn + 1, target))
        }
        if abs(translation) > travel * 0.25 {
            let draggedTurn = origin - translation / travel
            let target = translation < 0 ? ceil(draggedTurn) : floor(draggedTurn)
            return max(restingTurn - 1, min(restingTurn + 1, target))
        }
        return restingTurn
    }
}

/// Tracks the rendered spring without publishing a new view update each frame.
private final class EntitlementCardPresentation {
    var turn: CGFloat
    init(turn: CGFloat) { self.turn = turn }
}

// The drawing order and all poses follow the same interpolated progress.
// Changing direction mid-animation keeps the current pose instead of running
// delayed completion callbacks from an earlier swipe.
private struct EntitlementCardFlip: AnimatableModifier {
    let tier: EntitlementTier
    var turn: CGFloat
    let cardWidth: CGFloat
    let tiltScale: CGFloat
    let reduceMotion: Bool
    let presentation: EntitlementCardPresentation

    var animatableData: CGFloat {
        get { turn }
        set {
            turn = newValue
            presentation.turn = newValue
        }
    }

    func body(content: Content) -> some View {
        let cycle = floor(turn)
        let progress = min(1, max(0, turn - cycle))
        let outgoing = Int(cycle).isMultiple(of: 2) ? EntitlementTier.free : .pro
        let incoming = outgoing.other
        let frontness = tier == outgoing ? 1 - progress : progress
        let lift = sin(progress * .pi)
        // Negative turns reverse these roles, mirroring the entire transition.
        let side: CGFloat = tier == outgoing ? -1 : 1
        return content
            .scaleEffect(0.94 + 0.06 * frontness - 0.04 * lift)
            .rotation3DEffect(
                .degrees(reduceMotion ? 0 : Double(-7 * (1 - frontness) + side * 58 * lift)),
                axis: (x: 0, y: 1, z: 0), perspective: 0.45
            )
            .rotationEffect(.degrees(reduceMotion ? 0 : Double((7 - 10 * frontness) * tiltScale + side * 8 * lift)))
            .offset(
                x: 18 - 23 * frontness + side * cardWidth * 0.38 * lift,
                y: -9 + 23 * frontness - (reduceMotion ? 0 : 20 * lift)
            )
            // At the middle of a turn both faces have equal depth; keep the
            // arriving card just above the departing one.
            .zIndex(Double(frontness) + (tier == incoming ? 0.01 : 0))
    }
}

private struct EntitlementCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct EntitlementCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 438
    let tier: EntitlementTier

    private var isPro: Bool { tier == .pro }
    private var foreground: Color {
        if isPro {
            return colorScheme == .dark ? Color(red: 0.98, green: 0.94, blue: 0.92) : Color(red: 0.23, green: 0.15, blue: 0.14)
        }
        return colorScheme == .dark ? Color.white.opacity(0.9) : EntitlementTier.ink
    }
    private var muted: Color {
        if isPro {
            return colorScheme == .dark ? Color(red: 0.75, green: 0.65, blue: 0.63) : Color(red: 0.48, green: 0.37, blue: 0.36)
        }
        return foreground.opacity(0.56)
    }
    private var accent: Color {
        if isPro { return colorScheme == .dark ? EntitlementTier.bunnyHighlight : EntitlementTier.bunnyText }
        return colorScheme == .dark ? Color(red: 0.60, green: 0.77, blue: 0.94) : tier.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            Rectangle()
                .fill(foreground.opacity(0.1))
                .frame(height: 0.5)
                .padding(.vertical, 17)
            if isPro { proBenefits } else { freeBenefits }
            Spacer(minLength: 20)
            cardFooter
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
        .foregroundStyle(foreground)
        .background { cardSurface }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(colorScheme == .dark ? 0.22 : 0.8), foreground.opacity(0.06), Color.white.opacity(colorScheme == .dark ? 0.08 : 0.4)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 1
                )
        }
    }

    private var cardHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(accent)
                Text("NapTable")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .tracking(0.2)
                Spacer(minLength: 8)
                Text(isPro ? "02 / PRO" : "01 / FREE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(tier.title)
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .tracking(-0.6)
                    if isPro {
                        Image(systemName: "sparkle")
                            .font(.system(size: 21, weight: .light))
                            .foregroundStyle(accent)
                    }
                }
                if isPro {
                    Text("包含免费版全部功能")
                        .font(.caption)
                        .foregroundStyle(muted)
                }
            }
        }
    }

    private var freeBenefits: some View {
        VStack(alignment: .leading, spacing: 12) {
            benefit("calendar", title: "课表管理", detail: "导入、编辑与管理多张课表")
            benefit("square.and.arrow.up", title: "分享课表", detail: "通过图片或分享码分享给好友")
            benefit("square.grid.2x2", title: "桌面小组件", detail: "主屏幕、锁屏与待机显示")
            benefit("icloud", title: "iCloud 同步", detail: "在你的设备间自动同步")
            benefit("paintpalette", title: "主题与外观", detail: "主题色、外观模式与共用背景图")
        }
    }

    private var proBenefits: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 12) {
                benefit(ProBenefit.liveActivity.icon, title: ProBenefit.liveActivity.title, detail: ProBenefit.liveActivity.detail)
                HStack(spacing: 9) {
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(EntitlementTier.bunnyHighlight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("高等数学")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("下一节课 · 教学楼 A201")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer(minLength: 4)
                    Text("12 分钟")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(EntitlementTier.bunnyHighlight)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(Color.black.opacity(0.82), in: Capsule())
                .accessibilityLabel("实时活动示例：高等数学，12 分钟后上课")
            }
            .padding(12)
            .background(Color.white.opacity(colorScheme == .dark ? 0.055 : 0.28), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(accent.opacity(0.14), lineWidth: 0.5)
            }

            ForEach([ProBenefit.themes, .widgetBackground]) { item in
                benefit(item.icon, title: item.title, detail: item.detail)
            }
        }
    }

    private func benefit(_ icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(accent)
                .frame(width: 23, height: 23)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cardFooter: some View {
        Group {
            if isPro {
                EntitlementPurchaseActions(accent: accent, muted: muted)
            } else {
                Label("永久免费", systemImage: "checkmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 15)
        .overlay(alignment: .top) {
            Rectangle().fill(foreground.opacity(0.1)).frame(height: 0.5)
        }
    }

    private var cardSurface: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: surfaceColors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .strokeBorder(accent.opacity(isPro ? 0.1 : 0.08), lineWidth: 32)
                .frame(width: 220, height: 220)
                .offset(x: 98, y: -110)
            Circle()
                .strokeBorder(accent.opacity(0.07), lineWidth: 0.5)
                .frame(width: 270, height: 270)
                .offset(x: 120, y: -138)
            Rectangle()
                .fill(LinearGradient(colors: [.clear, Color.white.opacity(colorScheme == .dark ? 0.04 : (isPro ? 0.18 : 0.32)), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: 110)
                .rotationEffect(.degrees(28))
                .offset(x: -18)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var surfaceColors: [Color] {
        if isPro {
            if colorScheme == .dark {
                return [Color(red: 0.27, green: 0.17, blue: 0.17), Color(red: 0.20, green: 0.12, blue: 0.12), Color(red: 0.16, green: 0.09, blue: 0.09)]
            }
            return [EntitlementTier.bunnyTint(white: 0.62), EntitlementTier.bunnyTint(white: 0.70), EntitlementTier.bunnyTint(white: 0.82)]
        }
        if colorScheme == .dark {
            return [Color(red: 0.23, green: 0.29, blue: 0.36), Color(red: 0.17, green: 0.21, blue: 0.27)]
        }
        return [Color(red: 0.99, green: 0.99, blue: 0.97), Color(red: 0.93, green: 0.96, blue: 0.98)]
    }
}

// The settings row shares these descriptions with the entitlement screen.
extension PurchaseManager {
    var versionTitle: String {
        if isBeta { return "专业版 · Beta" }
        switch state {
        case .lifetime, .trial: return "专业版"
        default: return "免费版"
        }
    }

    var versionDetail: String {
        if isBeta { return "Beta 版本免费使用" }
        if accessMode == .loading { return "正在连接服务器…" }
        if accessMode == .unavailable { return "基础功能免费 · 连接失败" }
        switch state {
        case .loading: return "正在读取权益…"
        case .lifetime: return "已永久解锁全部功能"
        case .trial(let expiresAt):
            return "试用至 \(expiresAt.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))))"
        case .locked: return "基础功能免费使用"
        case .unavailable: return "基础功能免费 · 购买暂不可用"
        }
    }

    var versionSystemImage: String {
        if isBeta { return "gift.fill" }
        switch state {
        case .lifetime, .trial: return "checkmark.seal.fill"
        default: return "person.crop.circle"
        }
    }
}

#Preview("专业版权益") {
    NavigationStack { SubscriptionView() }
}

#Preview("试用到期提醒") {
    NavigationStack { SubscriptionView(reminder: TrialReminder(stage: .expired, expiresAt: .now)) }
}

#Preview("试用即将到期") {
    NavigationStack {
        SubscriptionView(reminder: TrialReminder(stage: .endingSoon, expiresAt: .now.addingTimeInterval(2 * 86400)))
    }
}
