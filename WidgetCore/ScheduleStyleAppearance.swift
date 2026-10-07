import SwiftUI

extension EnvironmentValues {
    @Entry var scheduleStyle: ScheduleStyle = .minimal
}

extension ScheduleStyle {
    var fontDesign: Font.Design {
        switch layout.font {
        case .standard: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }

    /// 课名、教室、「第 3–4 节」这类成句文字的字体。站牌的等宽体只留给时刻和日期：整句用等宽体时，
    /// 汉字和数字之间的空格有一个数字那么宽，一行字就散了。
    var textDesign: Font.Design { layout.font == .monospaced ? .default : fontDesign }

    /// 只有需要独立纸墨/站牌底色的风格覆盖画布，其余沿用主题背景设置。
    func canvasColor(dark: Bool) -> Color? {
        switch self {
        case .paper: Self.color(dark ? 0x201E1B : 0xF1ECE2)
        case .board: Self.color(dark ? 0x171A1C : 0xF4F5F4)
        default: nil
        }
    }

    func inkColor(dark: Bool) -> Color {
        switch self {
        case .paper: Self.color(dark ? 0xEDE6D8 : 0x2A251F)
        case .board: Self.color(dark ? 0xFFE4A3 : 0x171A1C)
        default: .primary
        }
    }

    func styleAccent(dark: Bool, fallback: Color) -> Color {
        switch self {
        case .paper: Self.color(dark ? 0xF39B85 : 0xA63F29)
        case .board: Self.color(dark ? 0xFFD477 : 0x242C32)
        default: fallback
        }
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }
}
