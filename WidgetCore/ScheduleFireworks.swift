import SwiftUI

/// 烟花的节奏，按下那一条时间线里一口气放完：碎片从各簇中心往外炸（先快后慢），同时往下坠
///（先慢后快，两者叠出一道下垂的弧线），一下亮起、再慢慢暗到看不见。星芒一闪就没，光束先散，
/// 亮点次之，外圈的闪光飘得最久、坠得最远。画廊逐帧出动画时按这里算。
///
/// 小组件在真机上是把前后两条时间线的画面各存一份，由系统在两份之间插值，所以：
/// - 只有两份里都有的视图才会动（彩炮能扬起就是这样）。新插进来的视图直接按后一份画，
///   过渡、父视图的动画都不管用。所以碎片平时就在，按下只改状态。
/// - 存下来的是合并后的画面：叠在一起的几个缩放合成一个变换，几个透明度乘成一个值。
///   所以不能靠「先放大再缩小」两个效果相乘做出中间亮一下，前后乘积一样就什么都不动。
/// - 一个视图上的几样变化只会共用一条动画（实测整段都按最快的那条一下放完），各挂各的 `.animation` 不管用。
///   要不同快慢就得放在不同的视图上，中间隔一层 `compositingGroup`，免得又被合并。
/// - 只用系统自带的曲线，自定义贝塞尔不一定认。
/// - 完全透明的视图很可能存档时就被丢掉了，两份里都没有也就不会动。所以碎片的透明度从不降到 0：
///   平时和散完都只是暗到 `hiddenLevel`，看不见但还在。
/// - 验证真机效果用 Xcode 里这份文件末尾的 `#Preview`：它和桌面一样按两条时间线插值。
/// - 每段动画最长只放 2 秒左右，超过的部分直接跳到终点。
/// - 不认 `.delay`。
/// - 下一条时间线什么时候换上不由我们定，不指望它接着放第二段。
enum FireworksTiming {
    /// 按下后一组碎片一下亮起用的时间。
    static let flashDuration = 0.15
    /// 散完时碎片暗到多暗：看不见，但不是 0，免得存档时被丢掉。
    static let hiddenLevel = 0.02
    /// 碎片刚炸开时多大，飞出去的路上长到原大。平时靠整组暗到 `hiddenLevel` 藏住（见 `FireworksOverlay`）。
    static let collapsedScale = 0.4

    /// 每一层飞多久、散完要多久（两个一样长），一路坠下多少（占小组件短边的比例）。
    static func layer(_ kind: FireworksLayer) -> (life: Double, drop: CGFloat) {
        switch kind {
        case .core: return (0.8, 0.04)
        case .streak: return (1.1, 0.09)
        case .dot: return (1.5, 0.14)
        case .glitter: return (1.8, 0.2)
        }
    }

    /// 按下到最后一点闪光散完（最长那一层的寿命）。
    static let total = 1.8

    static func outward(_ progress: Double) -> Double { UnitCurve.easeOut.value(at: progress) }

    /// 下坠和变暗：先慢后快，一出来不至于就显得灰，也像被重力拽下去。只用系统自带的曲线，自定义贝塞尔在小组件里不一定认。
    static func fade(_ progress: Double) -> Double { UnitCurve.easeIn.value(at: progress) }

    /// 彩炮扬起多少：带一点回弹地扬起，烟花散完、下一条时间线来了再放回去。
    static func tilt(at time: Double) -> Double {
        guard time > 0 else { return 0 }
        let rise = min(time / 0.5, 1)
        let spring = 1 - pow(1 - rise, 3) + sin(rise * .pi) * 0.25
        let settle = min(max((time - (total + 0.3)) / 0.9, 0), 1)
        return spring * (1 - UnitCurve.easeInOut.value(at: settle))
    }
}

/// 烟花碎片的几种：星芒、光束、亮点、闪光，散得快慢、坠得远近不同。
enum FireworksLayer: CaseIterable {
    case core, streak, dot, glitter
}

private struct FireworksPreviewTimeKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    /// 只有预览画廊会设：画烟花动画第几秒的样子。
    var scheduleWidgetFireworksPreviewTime: Double? {
        get { self[FireworksPreviewTimeKey.self] }
        set { self[FireworksPreviewTimeKey.self] = newValue }
    }
}

/// 铺满整个小组件的烟花。一簇一个色系，从中心往外辐射成菊花形：每根射线外头一道拖着尾巴的光，
/// 中间一颗亮点，隔一根在最外面再缀一点闪光，中心一颗星芒。一簇大的在彩炮正上方（像是它打上去的），
/// 另外几簇大小不一，散在小组件各处。
///
/// 小组件里没法跑逐帧动画，碎片平时就缩成一个点停在各簇中心，按下时几样状态各带各的曲线同时起跑
///（见 `FireworksTiming`）。位置按小组件大小的比例算好，不用随机数。
struct FireworksOverlay: View {
    let active: Bool
    /// 彩炮口，在这一层的坐标里。
    let origin: CGPoint
    /// App 按实际经过时间逐帧播放；小组件继续使用系统时间线插值。
    var elapsedTime: TimeInterval? = nil
    @Environment(\.scheduleWidgetFireworksPreviewTime) private var previewTime

    private struct Burst {
        let center: CGPoint
        let radius: CGFloat
        let rays: Int
        let colors: (Color, Color)
    }

    private struct Particle: Identifiable {
        let id: Int
        /// 哪一簇的哪一种碎片：同一组一起变暗。
        let group: Int
        let kind: FireworksLayer
        let burstCenter: CGPoint
        /// 炸开到哪（相对这一簇的中心）。
        let travel: CGSize
        let angle: Double
        let size: CGFloat
        let color: Color
    }

    /// 一簇一个色系，按放下的先后分：第一簇（彩炮上方）是金色。
    private static let palettes: [(Color, Color)] = [
        (.yellow, .orange),
        (.pink, Color(red: 1, green: 0.45, blue: 0.62)),
        (.cyan, .blue),
        (.purple, .pink),
        (.mint, .green),
    ]

    /// 其余几簇的候选位置（占宽高的比例）和半径（占短边的比例），按顺序挑，和已经放下的叠得太多就跳过。
    /// 彩炮在不同小组件里位置不一样（两日课表在左列，今日课表在正中），这样哪种都不会挤成一团。
    private static let candidates: [(x: CGFloat, y: CGFloat, radius: CGFloat)] = [
        (0.80, 0.22, 0.18),
        (0.20, 0.24, 0.16),
        (0.86, 0.54, 0.14),
        (0.14, 0.54, 0.13),
        (0.80, 0.85, 0.14),
        (0.20, 0.85, 0.12),
        (0.50, 0.90, 0.12),
    ]

    private static func bursts(in size: CGSize, origin: CGPoint) -> [Burst] {
        let side = min(size.width, size.height)
        // 第一簇在彩炮正上方，像是它打上去的。
        var placed: [(center: CGPoint, radius: CGFloat)] = [
            (CGPoint(x: origin.x, y: origin.y - side * 0.25), side * 0.19),
        ]
        // 彩炮和它下面的祝福也要让开，只占位不放烟花。
        let keepOut = [(center: CGPoint(x: origin.x, y: origin.y + side * 0.1), radius: side * 0.2)]
        for candidate in candidates where placed.count < palettes.count {
            let center = CGPoint(x: candidate.x * size.width, y: candidate.y * size.height)
            let radius = candidate.radius * side
            let clear = (placed + keepOut).allSatisfy { other in
                hypot(center.x - other.center.x, center.y - other.center.y) > (radius + other.radius) * 0.8
            }
            if clear { placed.append((center, radius)) }
        }
        return placed.enumerated().map { index, burst in
            Burst(
                center: burst.center,
                radius: burst.radius,
                rays: max(10, Int(burst.radius / 4.2)),
                colors: palettes[index]
            )
        }
    }

    private static func particles(in size: CGSize, origin: CGPoint) -> [Particle] {
        var result: [Particle] = []
        func add(_ kind: FireworksLayer, _ burst: Burst, burstIndex: Int, angle: Double, distance: CGFloat, size: CGFloat, color: Color) {
            let kindIndex = FireworksLayer.allCases.firstIndex(of: kind) ?? 0
            result.append(Particle(
                id: result.count, group: burstIndex * FireworksLayer.allCases.count + kindIndex,
                kind: kind, burstCenter: burst.center,
                travel: CGSize(width: CGFloat(cos(angle)) * distance, height: CGFloat(sin(angle)) * distance),
                angle: angle, size: size, color: color
            ))
        }
        for (index, burst) in bursts(in: size, origin: origin).enumerated() {
            let big = burst.radius > 40
            for ray in 0..<burst.rays {
                let angle = Double(ray) / Double(burst.rays) * 2 * .pi + Double(index) * 0.37
                let tint = ray.isMultiple(of: 2) ? burst.colors.0 : burst.colors.1
                let length = burst.radius * 0.34
                // 光束的中心往里收半个身长，尖端正好冲到半径上。
                add(.streak, burst, burstIndex: index, angle: angle, distance: burst.radius - length / 2, size: length, color: tint)
                add(.dot, burst, burstIndex: index, angle: angle + 0.12, distance: burst.radius * 0.62, size: big ? 3.4 : 2.8,
                    color: burst.colors.1)
                if ray.isMultiple(of: 2) {
                    add(.glitter, burst, burstIndex: index, angle: angle + 0.18, distance: burst.radius * 1.18, size: big ? 2.6 : 2.2,
                        color: burst.colors.0)
                }
            }
            add(.core, burst, burstIndex: index, angle: 0, distance: 0, size: big ? 13 : 10, color: burst.colors.0)
        }
        return result
    }

    var body: some View {
        let previewTime = elapsedTime ?? self.previewTime
        GeometryReader { proxy in
            let particles = Self.particles(in: proxy.size, origin: origin)
            let side = min(proxy.size.width, proxy.size.height)
            let hidden = FireworksTiming.hiddenLevel
            let collapsed = FireworksTiming.collapsedScale
            let groups = Dictionary(grouping: particles) { $0.group }.sorted { $0.key < $1.key }
            ZStack {
                ForEach(groups, id: \.key) { _, members in
                    let layer = FireworksTiming.layer(members[0].kind)
                    let drop = layer.drop * side
                    // 同一个视图上的几样变化在小组件里只会共用一条动画，要各走各的就得是不同的视图，分三层：
                    // 碎片自己长到原大、往外飞，越飞越慢，一直飞到散没；同一簇同一种碎片合成一组，先一下亮起，
                    // 隔一层 `compositingGroup` 再整组越落越快、边落边暗（同一条先慢后快的曲线，像被重力拽下去）。
                    let fall = previewTime.map { $0 > 0 ? FireworksTiming.fade(min($0 / layer.life, 1)) : 0 }
                        ?? (active ? 1 : 0)
                    ZStack {
                        ForEach(members) { particle in
                            let landing = CGPoint(
                                x: particle.burstCenter.x + particle.travel.width,
                                y: particle.burstCenter.y + particle.travel.height
                            )
                            if let previewTime {
                                // 画廊逐帧出动画用：按和下面一样的曲线，自己算出第 previewTime 秒的样子。
                                let burst = previewTime > 0
                                    ? FireworksTiming.outward(min(previewTime / layer.life, 1)) : 0
                                shape(particle)
                                    .scaleEffect(collapsed + (1 - collapsed) * burst)
                                    .position(
                                        x: particle.burstCenter.x + (landing.x - particle.burstCenter.x) * burst,
                                        y: particle.burstCenter.y + (landing.y - particle.burstCenter.y) * burst
                                    )
                            } else {
                                // 平时缩小停在簇中心；按下时一边往外飞一边长到原大，飞到散没为止，不会半路停住。
                                shape(particle)
                                    .scaleEffect(active ? 1 : collapsed)
                                    .position(active ? landing : particle.burstCenter)
                                    .animation(active ? .easeOut(duration: layer.life) : nil, value: active)
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    // 平时整组暗到 hiddenLevel 藏住。先合成再调暗，叠在簇中心的一堆碎片才不会一层层透出来。
                    .compositingGroup()
                    .opacity(hidden + (1 - hidden) * (previewTime.map { $0 > 0 ? FireworksTiming.outward(min($0 / FireworksTiming.flashDuration, 1)) : 0 }
                        ?? (active ? 1 : 0)))
                    .animation(active && previewTime == nil ? .easeOut(duration: FireworksTiming.flashDuration) : nil, value: active)
                    .compositingGroup()
                    // 散完只暗到 hiddenLevel，不到 0。收起不靠这里：下一条换了 `.id`，整层按平时的样子重新放进来。
                    .offset(y: drop * fall)
                    .opacity(1 - (1 - hidden) * fall)
                    .animation(active && previewTime == nil ? .easeIn(duration: layer.life) : nil, value: active)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func shape(_ particle: Particle) -> some View {
        let color = particle.color
        switch particle.kind {
        case .streak:
            // 朝外的一道光，靠中心那头渐隐，像拖着尾巴飞出去。
            Capsule()
                .fill(LinearGradient(
                    colors: [particle.color.opacity(0), color],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: particle.size, height: 2.4)
                .rotationEffect(.radians(particle.angle))
        case .dot, .glitter:
            Circle()
                .fill(color)
                .frame(width: particle.size, height: particle.size)
        case .core:
            Image(systemName: "sparkle")
                .font(.system(size: particle.size, weight: .bold))
                .foregroundStyle(color)
        }
    }
}
