import SwiftUI

/// 课程卡片的配色。
///
/// 原来这套哈希取色只藏在 `NativeScheduleCourseCard` 里，月视图的课程圆点要用同一
/// 组颜色，所以抽出来共用：同一门课在周视图、日视图和月历上都是同一个色相。
nonisolated enum ScheduleCourseTint {
    private static func hash(_ name: String) -> UInt64 {
        name.unicodeScalars.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1.value) }
    }

    static func hue(for name: String) -> Double {
        Double(hash(name) % 360) / 360
    }

    static func saturation(for name: String) -> Double {
        0.58 + Double((hash(name) >> 8) % 18) / 100
    }

    static func backgroundLightness(for name: String) -> Double {
        0.89 + Double((hash(name) >> 16) % 5) / 100
    }

    static func textLightness(for name: String) -> Double {
        0.25 + Double((hash(name) >> 24) % 8) / 100
    }

    static func borderLightness(for name: String) -> Double {
        0.48 + Double((hash(name) >> 20) % 10) / 100
    }

    /// 文字与圆点用的高饱和色。
    static func accent(for name: String, scheme: ColorScheme) -> Color {
        let saturation = saturation(for: name)
        if scheme == .dark {
            return color(hue: hue(for: name), saturation: min(0.82, saturation + 0.08), lightness: 0.72)
        }
        return color(hue: hue(for: name), saturation: min(0.76, saturation + 0.04), lightness: textLightness(for: name))
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
