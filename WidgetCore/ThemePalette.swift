import SwiftUI
import os

/// 主题色令牌：App 里所有用到主题色的地方都从这里取，小组件也能用。
///
/// 同一个主题色按用途分几档，浅色、深色各一套：
/// - `text`：文字、图标、细线、「现在」线。在课表画布、周视图面板和今天列的淡底上都
///   不低于 4.5:1，开不开「主题色应用到背景」都一样。
/// - `fill`：实心底，上面压 `onFill`（白字），白字不低于 4.5:1。白字只和底色有关，两种外观同一个值。
/// - `tint(_:)`：原色按给定浓度铺的淡底，今天列、选中、胶囊底；装饰用的半透明主题色也走它。
///
/// 调色只动 OKLCH 的亮度，色相和色度不变；色度超出 sRGB 时按比例收。二分找刚好达标的
/// 亮度，原色已经达标就用原色。自选色走同一套算法，#FFCC00 这种亮黄也能得到读得清的字色。
/// 算出来的值取到 8 位，屏幕上画的就是检查过的那个颜色。
nonisolated struct ThemePalette: Equatable, Sendable {
    /// sRGB 分量，0...1，伽马编码，和 `ScheduleLiveActivityRGB` 同一个空间。
    struct RGB: Hashable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        static let white = RGB(red: 1, green: 1, blue: 1)
        static let black = RGB(red: 0, green: 0, blue: 0)

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(_ value: ScheduleLiveActivityRGB) {
            let value = value.clamped
            self.init(red: value.red, green: value.green, blue: value.blue)
        }

        /// `0xRRGGBB`。
        init(hex: UInt32) {
            self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                      blue: Double(hex & 0xFF) / 255)
        }

        var color: Color { Color(red: red, green: green, blue: blue) }

        /// 「#RRGGBB」，检查脚本打表用。
        var hex: String {
            let value = [red, green, blue].reduce(0) { $0 << 8 | Int(($1 * 255).rounded()) }
            return "#" + String(format: "%06X", value)
        }

        /// `top` 按 `amount` 的不透明度盖在这一层上。和屏幕合成一样，在伽马编码的分量上插值。
        func overlaid(by top: RGB, amount: Double) -> RGB {
            RGB(red: red + (top.red - red) * amount,
                green: green + (top.green - green) * amount,
                blue: blue + (top.blue - blue) * amount)
        }

        /// WCAG 相对亮度。
        var luminance: Double {
            0.2126 * ThemePalette.linear(red) + 0.7152 * ThemePalette.linear(green)
                + 0.0722 * ThemePalette.linear(blue)
        }
    }

    /// 一种外观下的几档。
    struct Tier: Equatable, Sendable {
        /// 文字、图标、细线、「现在」线。
        let text: RGB
        /// 实心底，上面压 `onFill`。
        let fill: RGB
        /// 压在 `fill` 上的字色，现在一律白字。
        let onFill: RGB
    }

    /// 主题原色。淡底按它和浓度生成。
    let base: RGB
    let light: Tier
    let dark: Tier

    /// 文字、以及实心底上白字的最低对比度（WCAG AA 正文）。
    static let minimumContrast = 4.5

    init(_ brand: ScheduleLiveActivityRGB) {
        self.init(base: RGB(brand))
    }

    init(base: RGB) {
        self.base = base
        let fill = Self.adjusted(base, lighten: false) { Self.contrast($0, .white) >= Self.minimumContrast }
        light = Tier(text: Self.text(for: base, dark: false), fill: fill, onFill: .white)
        dark = Tier(text: Self.text(for: base, dark: true), fill: fill, onFill: .white)
    }

    func tier(dark: Bool) -> Tier { dark ? self.dark : light }

    func text(dark: Bool) -> Color { tier(dark: dark).text.color }

    func fill(dark: Bool) -> Color { tier(dark: dark).fill.color }

    func onFill(dark: Bool) -> Color { tier(dark: dark).onFill.color }

    /// 原色按浓度铺的淡底。两种外观同一个算法，浓度由调用处按外观给。
    func tint(_ strength: Double) -> Color { base.color.opacity(strength) }

    // MARK: 缓存

    /// 形状样式每次重画都来取，同一个主题色只算一次。拖取色器时主题色会连着换，存满就清空。
    private static let cache = OSAllocatedUnfairLock(initialState: [RGB: ThemePalette]())

    static func of(_ brand: ScheduleLiveActivityRGB) -> ThemePalette {
        let base = RGB(brand)
        if let cached = cache.withLock({ $0[base] }) { return cached }
        let palette = ThemePalette(base: base)
        cache.withLock { entries in
            if entries.count >= 16 { entries.removeAll() }
            entries[base] = palette
        }
        return palette
    }

    // MARK: 文字档要压得住的底

    /// 课表页的几层底。数值和真实画法共用：`AppBackgroundStyle`、`schedulePanelSurface`
    /// 和周视图的今天列都从这里取，改这里两边一起变。
    enum Surface {
        /// 开「主题色应用到背景」时画布混进的主题色：深色是黑底 90% 加主题色 10%，浅色是白底 95% 加 5%。
        static func canvasBrandAmount(dark: Bool) -> Double { dark ? 0.10 : 0.05 }
        /// 周视图面板（没有背景图时）：一层白色按这个不透明度盖在画布上。
        static func panelWhiteOpacity(dark: Bool) -> Double { dark ? 0.09 : 0.96 }
        /// 今天整列的淡底浓度（没有背景图时）。
        static func todayStrength(dark: Bool) -> Double { dark ? 0.15 : 0.08 }

        /// 开主题底色时的画布。
        static func canvas(brand: RGB, dark: Bool) -> RGB {
            (dark ? RGB.black : RGB.white).overlaid(by: brand, amount: canvasBrandAmount(dark: dark))
        }

        /// 关主题底色时的系统底色：浅色是分组底 #F2F2F7 和纯白，深色两种都是纯黑。
        static func systemCanvases(dark: Bool) -> [RGB] {
            dark ? [.black] : [RGB(hex: 0xF2F2F7), .white]
        }
    }

    /// 文字档要逐一达标的底：开、关主题底色的画布，各自上面的面板，面板上的今天列。
    static func textSurfaces(brand: RGB, dark: Bool) -> [RGB] {
        ([Surface.canvas(brand: brand, dark: dark)] + Surface.systemCanvases(dark: dark)).flatMap { canvas in
            let panel = canvas.overlaid(by: .white, amount: Surface.panelWhiteOpacity(dark: dark))
            return [canvas, panel, panel.overlaid(by: brand, amount: Surface.todayStrength(dark: dark))]
        }
    }

    static func contrast(_ first: RGB, _ second: RGB) -> Double {
        contrast(first.luminance, second.luminance)
    }

    private static func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// 浅色往暗里调，深色往亮里调，直到每一层底都达标。
    private static func text(for base: RGB, dark: Bool) -> RGB {
        let surfaces = textSurfaces(brand: base, dark: dark).map(\.luminance)
        return adjusted(base, lighten: dark) { candidate in
            let luminance = candidate.luminance
            return surfaces.allSatisfy { contrast(luminance, $0) >= minimumContrast }
        }
    }

    /// 只调 OKLCH 的亮度，往 `lighten` 那头走，二分找离原色最近、刚好满足 `passes` 的一档。
    private static func adjusted(_ base: RGB, lighten: Bool, passes: (RGB) -> Bool) -> RGB {
        if passes(base) { return base }
        let color = OKLCH(base)
        // 纯白、纯黑一定压得住这几层底，从那头往原色逼近。
        var good = lighten ? 1.0 : 0.0
        var bad = color.lightness
        for _ in 0..<32 {
            let middle = (good + bad) / 2
            if passes(color.rgb(lightness: middle)) { good = middle } else { bad = middle }
        }
        return color.rgb(lightness: good)
    }

    // MARK: 色彩空间

    static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ value: Double) -> Double {
        let value = min(max(value, 0), 1)
        return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    /// OKLCH（Björn Ottosson 的 OKLab 换成极坐标）：亮度、色度、色相（弧度）。
    struct OKLCH: Sendable {
        var lightness: Double
        var chroma: Double
        var hue: Double

        init(_ rgb: RGB) {
            let red = ThemePalette.linear(rgb.red)
            let green = ThemePalette.linear(rgb.green)
            let blue = ThemePalette.linear(rgb.blue)
            let l = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
            let m = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
            let s = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
            lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
            let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
            let b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
            chroma = (a * a + b * b).squareRoot()
            hue = atan2(b, a)
        }

        /// 同色相、同色度换到 `lightness`。色度出了 sRGB 就按比例收到边界上，结果取到 8 位。
        func rgb(lightness: Double) -> RGB {
            let a = chroma * cos(hue), b = chroma * sin(hue)
            var channels = Self.linearRGB(lightness, a, b)
            if !Self.inGamut(channels) {
                var inside = 0.0, outside = 1.0
                for _ in 0..<32 {
                    let middle = (inside + outside) / 2
                    if Self.inGamut(Self.linearRGB(lightness, a * middle, b * middle)) {
                        inside = middle
                    } else {
                        outside = middle
                    }
                }
                channels = Self.linearRGB(lightness, a * inside, b * inside)
            }
            func byte(_ value: Double) -> Double { (ThemePalette.encoded(value) * 255).rounded() / 255 }
            return RGB(red: byte(channels.red), green: byte(channels.green), blue: byte(channels.blue))
        }

        private static func linearRGB(_ lightness: Double, _ a: Double, _ b: Double)
            -> (red: Double, green: Double, blue: Double) {
            func cube(_ value: Double) -> Double { value * value * value }
            let l = cube(lightness + 0.3963377774 * a + 0.2158037573 * b)
            let m = cube(lightness - 0.1055613458 * a - 0.0638541728 * b)
            let s = cube(lightness - 0.0894841775 * a - 1.2914855480 * b)
            return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        }

        private static func inGamut(_ channels: (red: Double, green: Double, blue: Double)) -> Bool {
            let tolerance = 1e-7
            return [channels.red, channels.green, channels.blue].allSatisfy { $0 >= -tolerance && $0 <= 1 + tolerance }
        }
    }
}
