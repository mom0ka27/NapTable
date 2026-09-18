import SwiftUI

/// `ColorUtil.HexColor` and `Course.getColor`.
///
/// The Flutter app kept a shuffled pool of palette indices in
/// `SharedPreferences` so every table got a stable-but-varied assignment. Here
/// the table's name stands in for that pool entry: the same course always gets
/// the same colour, different courses usually get different ones, and nothing
/// has to be persisted just to remember a colour.
nonisolated enum CourseColor {
    /// `Course.getColor(colorPool)`: an explicit hex wins, otherwise the course
    /// id indexes into the palette.
    static func hex(for course: Course, seed: Int) -> String {
        if let explicit = normalized(course.color) { return explicit }
        let pool = SchoolDefaults.colorList
        guard !pool.isEmpty else { return "#8AD297" }
        let index = abs(seed) % pool.count
        return pool[index]
    }

    static func hex(for course: Course) -> String {
        hex(for: course, seed: course.courseKey ?? course.name.hashValue)
    }

    static func color(for course: Course, seed: Int) -> Color {
        color(hex: hex(for: course, seed: seed))
    }

    static func color(for course: Course) -> Color {
        color(hex: hex(for: course))
    }

    static func hiddenColor() -> Color {
        color(hex: SchoolDefaults.hiddenCourseColor)
    }

    static func normalized(_ hex: String?) -> String? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8,
              value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + value
    }

    /// `HexColor._getColorFromHex`
    static func color(hex: String) -> Color {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 6 { value = "FF" + value }
        guard value.count == 8, let raw = UInt64(value, radix: 16) else {
            return Color(red: 0.54, green: 0.82, blue: 0.59)
        }
        let alpha = Double((raw >> 24) & 0xFF) / 255
        let red = Double((raw >> 16) & 0xFF) / 255
        let green = Double((raw >> 8) & 0xFF) / 255
        let blue = Double(raw & 0xFF) / 255
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// The text tone that stays readable on the palette colour. The Flutter app
    /// always used white; the palette is light enough that a deep tone of the
    /// same hue reads better on a phone screen.
    static func textColor(on background: Color, scheme: ColorScheme) -> Color {
        if scheme == .dark { return .white }
        return Color(white: 0.13)
    }
}

extension Color {
    init?(hexString: String?) {
        guard let normalized = CourseColor.normalized(hexString) else { return nil }
        self = CourseColor.color(hex: normalized)
    }
}
