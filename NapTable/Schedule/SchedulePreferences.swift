import Combine
import Foundation

#if canImport(UIKit)
import UIKit
typealias ScheduleBackgroundImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias ScheduleBackgroundImage = NSImage
#endif

/// Display-only timetable preferences shared by the native schedule and its
/// settings page.
///
/// Ported from `../CPU-Web/ios_next` (CpuTime) `NativeSchedulePreferences.swift`.
/// CpuTime's Web timetable stays the source of course data, so these values only
/// control how the native cards are presented. NapTable is fully local, which
/// makes the split even cleaner: nothing here ever reaches a course record.
final class NativeSchedulePreferences: ObservableObject {
    static let shared = NativeSchedulePreferences()

    /// Whether the week grid and the day picker include 周六/周日.
    @Published var showWeekend: Bool { didSet { persist() } }
    @Published var showDateHeader: Bool { didSet { persist() } }
    @Published var showFreeTimeCourses: Bool { didSet { persist() } }
    @Published var defaultView: String { didSet { persist() } }
    @Published var density: String { didSet { persist() } }
    /// 第几节之后的空行不画；0 表示全部显示。那一周有更晚的课就一直画到那节课。
    @Published var hideSlotsAfter: Int { didSet { persist() } }
    @Published var backgroundPath: String { didSet { loadBackgroundImage(); persist() } }
    /// 浅色模式下背景图的不透明度。
    @Published var backgroundOpacity: Double { didSet { persist() } }
    /// 深色模式下背景图的不透明度。深色底上图片显得更暗，默认比浅色高一点。
    @Published var backgroundOpacityDark: Double { didSet { persist() } }
    /// 浅色模式的背景图。只设了一张时两种外观都用它。
    @Published private(set) var backgroundImage: ScheduleBackgroundImage?
    /// 深色模式单独设的背景图，和浅色的是两个独立的位置。
    @Published var backgroundPathDark: String { didSet { loadBackgroundImage(); persist() } }
    @Published private(set) var backgroundImageDark: ScheduleBackgroundImage?

    private let defaults: UserDefaults
    private var ready = false


    private enum Key {
        static let showWeekend = "nativeSchedule.showWeekend"
        static let showDateHeader = "nativeSchedule.showDateHeader"
        static let showFreeTimeCourses = "nativeSchedule.showFreeTimeCourses"
        static let defaultView = "nativeSchedule.defaultView"
        static let density = "nativeSchedule.density"
        static let hideSlotsAfter = "nativeSchedule.hideSlotsAfter"
        static let backgroundPath = "nativeSchedule.backgroundPath"
        static let backgroundOpacity = "nativeSchedule.backgroundOpacity"
        static let backgroundOpacityDark = "nativeSchedule.backgroundOpacityDark"
        static let backgroundPlacement = "nativeSchedule.backgroundPlacement"
        static let backgroundPathDark = "nativeSchedule.backgroundPathDark"
        static let backgroundPlacementDark = "nativeSchedule.backgroundPlacementDark"
    }

    /// 背景图在编辑页里的摆放。原图和它一起留着，下次打开编辑页能接着上次调。
    /// 偏移以画框宽度为单位，和 `BackgroundCropEditor` 一致。
    struct BackgroundPlacement: Codable, Equatable {
        var scale: Double = 1
        var offsetX: Double = 0
        var offsetY: Double = 0
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showWeekend = defaults.object(forKey: Key.showWeekend) as? Bool ?? true
        showDateHeader = defaults.object(forKey: Key.showDateHeader) as? Bool ?? true
        showFreeTimeCourses = defaults.object(forKey: Key.showFreeTimeCourses) as? Bool ?? true
        let savedView = defaults.string(forKey: Key.defaultView) ?? "week"
        defaultView = Self.viewOptions.contains(savedView) ? savedView : "week"
        let savedDensity = defaults.string(forKey: Key.density) ?? "comfortable"
        density = savedDensity == "compact" ? "compact" : "comfortable"
        hideSlotsAfter = Self.clampedHideSlotsAfter(defaults.object(forKey: Key.hideSlotsAfter) as? Int ?? Self.defaultHideSlotsAfter)
        backgroundPath = defaults.string(forKey: Key.backgroundPath) ?? ""
        backgroundPathDark = defaults.string(forKey: Key.backgroundPathDark) ?? ""
        let opacity = Self.clampedOpacity(defaults.object(forKey: Key.backgroundOpacity) as? Double ?? Self.defaultBackgroundOpacity)
        backgroundOpacity = opacity
        // 升级上来还没有单独设过深色的，按浅色的值推一个默认值。
        backgroundOpacityDark = Self.clampedOpacity(
            defaults.object(forKey: Key.backgroundOpacityDark) as? Double ?? Self.defaultDarkOpacity(light: opacity)
        )
        backgroundImage = nil
        backgroundImageDark = nil
        loadBackgroundImage()
        ready = true
    }

    static let viewOptions = ["week", "day", "month"]
    static let densityOptions = ["comfortable", "compact"]

    /// 背景图的不透明度范围。在「调整背景」页里调，可以一直开到 100%。
    static let backgroundOpacityRange: ClosedRange<Double> = 0.1...1

    static func clampedOpacity(_ value: Double) -> Double {
        min(backgroundOpacityRange.upperBound, max(backgroundOpacityRange.lowerBound, value))
    }

    static let defaultBackgroundOpacity = 0.18

    /// 深色默认比浅色高 10 个百分点。
    static func defaultDarkOpacity(light: Double) -> Double {
        clampedOpacity(light + 0.1)
    }

    /// 当前外观下应该用的不透明度。
    func backgroundOpacity(dark: Bool) -> Double {
        dark ? backgroundOpacityDark : backgroundOpacity
    }

    /// 当前外观下显示的背景图：这个外观没单独设图，就沿用另一个外观的。
    func backgroundImage(dark: Bool) -> ScheduleBackgroundImage? {
        dark ? (backgroundImageDark ?? backgroundImage) : (backgroundImage ?? backgroundImageDark)
    }

    /// 这个外观有没有自己的一张图（而不是沿用另一个外观的）。
    func hasOwnBackground(dark: Bool) -> Bool {
        !path(dark: dark).isEmpty
    }

    static let defaultHideSlotsAfter = 9

    static func clampedHideSlotsAfter(_ value: Int) -> Int {
        max(0, min(30, value))
    }

    /// 网格画几行：默认画到第 `hideSlotsAfter` 节；这一周最晚的课比它晚，就画到那节课。
    /// `lastOccupiedSlot` 按整周算，所以同一周里每一天、周视图和日视图的行数都一样。
    func visibleSlotCount(total: Int, lastOccupiedSlot: Int) -> Int {
        guard hideSlotsAfter > 0 else { return total }
        return min(total, max(hideSlotsAfter, lastOccupiedSlot))
    }

    /// The weekday columns the grid draws, Monday-first.
    var visibleDays: [Int] { showWeekend ? Array(1...7) : Array(1...5) }

    /// 隐藏普通周末时，仍保留当前周有调休安排或有课的日期。
    func visibleDays(pinnedDays: Set<Int>) -> [Int] {
        (1...7).filter { showWeekend || $0 <= 5 || pinnedDays.contains($0) }
    }

    // MARK: Backup

    /// These values live in `UserDefaults` rather than the app's JSON state
    /// file, so they need their own representation to ride along in an exported
    /// backup. The background image travels as its file bytes (base64 in the
    /// JSON), which is the only part of a backup that can get large.
    struct DisplaySnapshot: Codable, Equatable {
        // 卡片只显示教室之后这三个开关没有了。照旧写 true，旧版本 App 读新备份不会失败。
        var showLocation: Bool = true
        var showTeacher: Bool = true
        var showWeeks: Bool = true
        var showWeekend: Bool
        var showDateHeader: Bool
        /// Optional so backups made before this preference existed still decode.
        var showFreeTimeCourses: Bool? = nil
        var defaultView: String
        var density: String
        /// Optional so backups made before this preference existed still decode.
        var hideSlotsAfter: Int? = nil
        // Retained for decoding older backups; fixed grid heights ignore it.
        var rowHeight: Double
        var backgroundOpacity: Double
        /// Optional so backups made before this preference existed still decode.
        var backgroundOpacityDark: Double? = nil
        var backgroundImageData: Data?
        /// Optional so backups made before this preference existed still decode.
        var backgroundImageDataDark: Data? = nil
    }

    func makeSnapshot() -> DisplaySnapshot {
        DisplaySnapshot(
            showWeekend: showWeekend,
            showDateHeader: showDateHeader,
            showFreeTimeCourses: showFreeTimeCourses,
            defaultView: defaultView,
            density: density,
            hideSlotsAfter: hideSlotsAfter,
            rowHeight: 44,
            backgroundOpacity: backgroundOpacity,
            backgroundOpacityDark: backgroundOpacityDark,
            backgroundImageData: backgroundPath.isEmpty
                ? nil
                : try? Data(contentsOf: Self.backgroundFileURL),
            backgroundImageDataDark: backgroundPathDark.isEmpty
                ? nil
                : try? Data(contentsOf: Self.backgroundFileURL(dark: true))
        )
    }

    /// Display preferences are single values, so a restore replaces them rather
    /// than merging the way tables and courses do.
    func apply(_ snapshot: DisplaySnapshot) {
        showWeekend = snapshot.showWeekend
        showDateHeader = snapshot.showDateHeader
        showFreeTimeCourses = snapshot.showFreeTimeCourses ?? true
        defaultView = Self.viewOptions.contains(snapshot.defaultView) ? snapshot.defaultView : "week"
        density = Self.densityOptions.contains(snapshot.density) ? snapshot.density : "comfortable"
        hideSlotsAfter = Self.clampedHideSlotsAfter(snapshot.hideSlotsAfter ?? Self.defaultHideSlotsAfter)
        backgroundOpacity = Self.clampedOpacity(snapshot.backgroundOpacity)
        backgroundOpacityDark = Self.clampedOpacity(
            snapshot.backgroundOpacityDark ?? Self.defaultDarkOpacity(light: backgroundOpacity)
        )
        // A backup without an image leaves the current one alone; clearing is an
        // explicit action in settings, not a side effect of restoring.
        if let data = snapshot.backgroundImageData, !data.isEmpty {
            try? setBackgroundData(data)
        }
        if let data = snapshot.backgroundImageDataDark, !data.isEmpty {
            try? setBackgroundData(data, dark: true)
        }
    }

    /// NapTable keeps its own copy: CpuTime wrote into `Application Support/CPUTime`,
    /// which would collide with the real client when both are installed.
    /// 浅色沿用最早只有一张图时的文件名，升级上来的背景不用搬家。
    static func backgroundFileURL(dark: Bool) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NapTable", isDirectory: true)
        return directory.appendingPathComponent(dark ? "schedule-background-dark.jpg" : "schedule-background.jpg")
    }

    /// 裁剪前的原图（已缩到长边 3000 像素）。课表页只读裁好的那张。
    static func backgroundSourceURL(dark: Bool) -> URL {
        backgroundFileURL(dark: dark).deletingLastPathComponent()
            .appendingPathComponent(dark ? "schedule-background-dark-source.jpg" : "schedule-background-source.jpg")
    }

    static var backgroundFileURL: URL { backgroundFileURL(dark: false) }
    static var backgroundSourceURL: URL { backgroundSourceURL(dark: false) }

    private func path(dark: Bool) -> String {
        dark ? backgroundPathDark : backgroundPath
    }

    private func setPath(_ value: String, dark: Bool) {
        if dark { backgroundPathDark = value } else { backgroundPath = value }
    }

    private static func placementKey(dark: Bool) -> String {
        dark ? Key.backgroundPlacementDark : Key.backgroundPlacement
    }

    func reset() {
        showWeekend = true
        showDateHeader = true
        showFreeTimeCourses = true
        defaultView = "week"
        density = "comfortable"
        hideSlotsAfter = Self.defaultHideSlotsAfter
        backgroundPath = ""
        backgroundPathDark = ""
        backgroundOpacity = Self.defaultBackgroundOpacity
        backgroundOpacityDark = Self.defaultDarkOpacity(light: Self.defaultBackgroundOpacity)
        backgroundImage = nil
        backgroundImageDark = nil
    }

    /// 直接换一张已经裁好的图（从备份恢复时），传 nil 就是移除这个外观的图。
    /// 它和旧原图对不上，所以旧原图和摆放一并清掉，之后再调整就以这张图本身为原图。
    func setBackgroundData(_ data: Data?, dark: Bool = false) throws {
        let url = Self.backgroundFileURL(dark: dark)
        try? FileManager.default.removeItem(at: Self.backgroundSourceURL(dark: dark))
        defaults.removeObject(forKey: Self.placementKey(dark: dark))
        if let data {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            setPath(url.path, dark: dark)
        } else {
            try? FileManager.default.removeItem(at: url)
            setPath("", dark: dark)
        }
    }

    /// 编辑页按「使用」：裁好的图给课表页显示，原图和摆放留着下次再调。
    func setBackground(cropped: Data, source: Data, placement: BackgroundPlacement, dark: Bool = false) throws {
        let url = Self.backgroundFileURL(dark: dark)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: Self.backgroundSourceURL(dark: dark), options: .atomic)
        try cropped.write(to: url, options: .atomic)
        defaults.set(try? JSONEncoder().encode(placement), forKey: Self.placementKey(dark: dark))
        // 路径不变时 didSet 照样会触发，裁好的新图会被重新读进来。
        setPath(url.path, dark: dark)
    }

    /// 重新调整时用的原图。没有单独存原图（旧版本设的背景、从备份恢复的背景）
    /// 就拿裁好的那张顶上。
    func backgroundSourceData(dark: Bool = false) -> Data? {
        guard hasOwnBackground(dark: dark) else { return nil }
        return FileManager.default.contents(atPath: Self.backgroundSourceURL(dark: dark).path)
            ?? FileManager.default.contents(atPath: Self.backgroundFileURL(dark: dark).path)
    }

    /// 上次的摆放；只有原图还在时才有意义，否则从头摆。
    func backgroundPlacement(dark: Bool = false) -> BackgroundPlacement {
        guard FileManager.default.fileExists(atPath: Self.backgroundSourceURL(dark: dark).path),
              let data = defaults.data(forKey: Self.placementKey(dark: dark)),
              let placement = try? JSONDecoder().decode(BackgroundPlacement.self, from: data) else {
            return BackgroundPlacement()
        }
        return placement
    }

    private func loadBackgroundImage() {
        backgroundImage = Self.loadImage(path: backgroundPath, dark: false)
        backgroundImageDark = Self.loadImage(path: backgroundPathDark, dark: true)
    }

    /// 存下来的绝对路径只当「设过背景」的标记用：沙盒目录的 UUID 会在
    /// App 更新或重装后变掉，按旧路径读会让背景图在升级后凭空消失。
    private static func loadImage(path: String, dark: Bool) -> ScheduleBackgroundImage? {
        guard !path.isEmpty else { return nil }
        let file = backgroundFileURL(dark: dark).path
        #if canImport(UIKit)
        return UIImage(contentsOfFile: file)
        #else
        return NSImage(contentsOfFile: file)
        #endif
    }

    private func persist() {
        guard ready else { return }
        defaults.set(showWeekend, forKey: Key.showWeekend)
        defaults.set(showDateHeader, forKey: Key.showDateHeader)
        defaults.set(showFreeTimeCourses, forKey: Key.showFreeTimeCourses)
        defaults.set(Self.viewOptions.contains(defaultView) ? defaultView : "week", forKey: Key.defaultView)
        defaults.set(Self.densityOptions.contains(density) ? density : "comfortable", forKey: Key.density)
        defaults.set(Self.clampedHideSlotsAfter(hideSlotsAfter), forKey: Key.hideSlotsAfter)
        defaults.set(backgroundPath, forKey: Key.backgroundPath)
        defaults.set(backgroundPathDark, forKey: Key.backgroundPathDark)
        defaults.set(Self.clampedOpacity(backgroundOpacity), forKey: Key.backgroundOpacity)
        defaults.set(Self.clampedOpacity(backgroundOpacityDark), forKey: Key.backgroundOpacityDark)
    }
}
