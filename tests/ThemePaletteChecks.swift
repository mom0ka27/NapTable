import Foundation

/// Standalone WCAG checks for the shared app/widget theme palette.
///
/// These checks deliberately exercise the palette at the RGB values that can
/// come from a colour picker, rather than relying only on the named presets.
@main
struct ThemePaletteChecks {
    private static let requiredContrast = ThemePalette.minimumContrast

    static func main() {
        var brands = ScheduleLiveActivityTheme.allCases.map(\.brandColor)
        // Picker boundary values and bright colours are the cases most likely
        // to need a large OKLCH adjustment.
        brands += [
            .init(red: 0, green: 0, blue: 0),
            .init(red: 1, green: 1, blue: 1),
            .init(red: 1, green: 0.8, blue: 0), // #FFCC00
            .init(red: 1, green: 1, blue: 0),
            .init(red: 0, green: 1, blue: 1),
            .init(red: 1, green: 0, blue: 1),
            .init(red: 0.003, green: 0.5, blue: 0.997)
        ]

        // A small deterministic sample catches interactions between hue,
        // gamut clipping and the final 8-bit rounding without making this
        // check dependent on a random seed.
        var state: UInt64 = 0xA5A5_1F2E_7C39_8041
        for _ in 0..<512 {
            brands.append(.init(red: next(&state), green: next(&state), blue: next(&state)))
        }

        var checked = 0
        for brand in brands {
            let palette = ThemePalette.of(brand)
            precondition(palette.base.red.isFinite && (0...1).contains(palette.base.red))
            precondition(palette.base.green.isFinite && (0...1).contains(palette.base.green))
            precondition(palette.base.blue.isFinite && (0...1).contains(palette.base.blue))

            let fillContrast = ThemePalette.contrast(palette.light.fill, palette.light.onFill)
            precondition(fillContrast >= requiredContrast,
                         "white on fill is only \(fillContrast): \(palette.base.hex)")
            precondition(palette.light.onFill == .white && palette.dark.onFill == .white)

            for dark in [false, true] {
                let tier = palette.tier(dark: dark)
                let surfaces = ThemePalette.textSurfaces(brand: palette.base, dark: dark)
                precondition(!surfaces.isEmpty)
                for surface in surfaces {
                    let contrast = ThemePalette.contrast(tier.text, surface)
                    precondition(contrast >= requiredContrast,
                                 "text contrast is only \(contrast): \(palette.base.hex), dark=\(dark), surface=\(surface.hex), text=\(tier.text.hex)")
                }
            }
            checked += 1
        }

        // Keep the public calculation contract pinned to the WCAG definition.
        precondition(ThemePalette.contrast(.black, .white) == 21)
        precondition(ThemePalette.contrast(.white, .black) == 21)
        print("PASS: ThemePalette \(checked) colours, both appearances, surfaces and fill text meet WCAG AA")
    }

    private static func next(_ state: inout UInt64) -> Double {
        state = state &* 2_862_933_557_777_941_757 &+ 3_037_000_493
        return Double(state >> 11) / Double(1 << 53)
    }
}
