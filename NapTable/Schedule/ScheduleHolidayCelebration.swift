import SwiftUI

private struct ScheduleCelebrationOrigin {
    let anchor: Anchor<CGPoint>
    let startedAt: Date
}

private struct ScheduleCelebrationOriginKey: PreferenceKey {
    static let defaultValue: ScheduleCelebrationOrigin? = nil

    static func reduce(value: inout ScheduleCelebrationOrigin?, nextValue: () -> ScheduleCelebrationOrigin?) {
        value = nextValue() ?? value
    }
}

/// 以按钮为起点，在所在内容区域播放和小组件相同的烟花。
struct ScheduleHolidayFireworks: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(ScheduleCelebrationOriginKey.self) { celebration in
            if let celebration, !reduceMotion {
                GeometryReader { proxy in
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        FireworksOverlay(
                            active: true,
                            origin: proxy[celebration.anchor],
                            elapsedTime: max(0, context.date.timeIntervalSince(celebration.startedAt))
                        )
                    }
                    .id(celebration.startedAt)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

struct ScheduleHolidayCelebrationButton: View {
    let greeting: String
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?
    @State private var feedback = 0

    private var isSolemn: Bool { greeting.hasPrefix("清明") }

    var body: some View {
        Group {
            if isSolemn {
                icon
                    .accessibilityHidden(true)
            } else {
                Button {
                    startedAt = .now
                    feedback += 1
                } label: {
                    icon
                        .rotationEffect(.degrees(startedAt != nil && !reduceMotion ? -14 : 0))
                        .scaleEffect(startedAt != nil && !reduceMotion ? 1.18 : 1)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.6), value: startedAt != nil)
                .accessibilityLabel("\(greeting)，放烟花")
                .anchorPreference(key: ScheduleCelebrationOriginKey.self, value: .center) { anchor in
                    startedAt.map { ScheduleCelebrationOrigin(anchor: anchor, startedAt: $0) }
                }
                #if os(iOS)
                .sensoryFeedback(.impact(weight: .light), trigger: feedback)
                #endif
            }
        }
        // 再次点击会取消上一轮收尾；离开页面后不保留动画或逐帧计时器。
        .task(id: startedAt) {
            guard startedAt != nil else { return }
            do {
                try await Task.sleep(for: .seconds(FireworksTiming.total))
                startedAt = nil
            } catch { }
        }
        .onChange(of: greeting) { _, _ in startedAt = nil }
        .onDisappear { startedAt = nil }
    }

    private var icon: some View {
        Image(systemName: isSolemn ? "leaf.fill" : "party.popper.fill")
            .font(.system(size: compact ? 30 : 40, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.pink)
    }
}
