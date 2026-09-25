import SwiftUI

/// 课程卡片的配色。
///
/// 原来这套哈希取色只藏在 `NativeScheduleCourseCard` 里，月视图的课程圆点要用同一
/// 组颜色，所以抽出来共用：同一门课在周视图、日视图和月历上都是同一个色相。小组件
/// 也读这一份，课表和桌面上的同一门课颜色一致。
///
/// 「纯色模式」下传入主题色：所有课程都取主题色的色相和饱和度，明暗仍按同一套
/// 规则，卡片的层次不变，只是不再按课名分色。
nonisolated enum ScheduleCourseTint {
    struct Swatch: Equatable {
        let hue: Double
        let saturation: Double
        let backgroundLightness: Double
        let textLightness: Double
        let borderLightness: Double

        /// 文字与圆点用的高饱和色。
        func accent(scheme: ColorScheme) -> Color {
            if scheme == .dark {
                return color(saturation: min(0.82, saturation + 0.08), lightness: 0.72)
            }
            return color(saturation: min(0.76, saturation + 0.04), lightness: textLightness)
        }

        /// 浅色模式下卡片的底色。
        var lightBackground: Color {
            color(saturation: saturation, lightness: backgroundLightness)
        }

        func color(saturation: Double? = nil, lightness: Double) -> Color {
            ScheduleCourseTint.color(hue: hue, saturation: saturation ?? self.saturation, lightness: lightness)
        }
    }

    /// `solid` 为主题色时进入纯色模式；为 `nil` 时按课名分色。
    static func swatch(for name: String, solid: ScheduleLiveActivityRGB? = nil) -> Swatch {
        if let solid {
            let (hue, saturation) = hueSaturation(of: solid)
            return Swatch(
                hue: hue,
                // 石板灰这类低饱和主题保持灰调，只压住过艳的自选色。
                saturation: min(0.76, saturation),
                backgroundLightness: 0.91,
                textLightness: 0.28,
                borderLightness: 0.52
            )
        }
        let hash = hash(name)
        return Swatch(
            hue: Double(hash % 360) / 360,
            saturation: 0.58 + Double((hash >> 8) % 18) / 100,
            backgroundLightness: 0.89 + Double((hash >> 16) % 5) / 100,
            textLightness: 0.25 + Double((hash >> 24) % 8) / 100,
            borderLightness: 0.48 + Double((hash >> 20) % 10) / 100
        )
    }

    static func accent(for name: String, scheme: ColorScheme, solid: ScheduleLiveActivityRGB? = nil) -> Color {
        swatch(for: name, solid: solid).accent(scheme: scheme)
    }

    private static func hash(_ name: String) -> UInt64 {
        name.unicodeScalars.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1.value) }
    }

    private static func hueSaturation(of rgb: ScheduleLiveActivityRGB) -> (Double, Double) {
        let value = rgb.clamped
        let maxValue = max(value.red, value.green, value.blue)
        let minValue = min(value.red, value.green, value.blue)
        let delta = maxValue - minValue
        guard delta > 0 else { return (0, 0) }
        let lightness = (maxValue + minValue) / 2
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch maxValue {
        case value.red: hue = ((value.green - value.blue) / delta).truncatingRemainder(dividingBy: 6)
        case value.green: hue = (value.blue - value.red) / delta + 2
        default: hue = (value.red - value.green) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, min(1, saturation))
    }

    static func color(hue: Double, saturation: Double, lightness: Double) -> Color {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let scaled = hue * 6
        let x = chroma * (1 - abs(scaled.truncatingRemainder(dividingBy: 2) - 1))
        let base: (Double, Double, Double)
        switch scaled {
        case 0..<1: base = (chroma, x, 0)
        case 1..<2: base = (x, chroma, 0)
        case 2..<3: base = (0, chroma, x)
        case 3..<4: base = (0, x, chroma)
        case 4..<5: base = (x, 0, chroma)
        default: base = (chroma, 0, x)
        }
        let match = lightness - chroma / 2
        return Color(red: base.0 + match, green: base.1 + match, blue: base.2 + match)
    }
}
