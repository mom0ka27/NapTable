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
    /// 是否收起晚间的空行。关掉时 `hideSlotsAfter` 仍保留，再打开还是原来的节数。
    @Published var hideLateSlots: Bool { didSet { persist() } }
    /// 第几节之后的空行不画（至少 1）。那一周有更晚的课就一直画到那节课。
    @Published var hideSlotsAfter: Int { didSet { persist() } }
    @Published var backgroundPath: String { didSet { loadBackgroundImage(); persist() } }
    /// 关掉只是不在课表上显示，图片、摆放和不透明度都留着，打开就回来。
    @Published var backgroundEnabled: Bool { didSet { persist() } }
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
    /// Background images are kept outside the course data because they are
    /// large binary files. Each timetable gets its own profile; the old
    /// unscoped profile remains the fallback for upgraded installations.
    private var tableBackgroundProfiles: [String: TableBackgroundProfile] = [:]
    private var globalBackgroundProfile = TableBackgroundProfile()
    private var activeTableKey: String?
    /// Nil means this table is still inheriting the legacy/default profile.
    private var activeStorageKey: String?
    private var switchingProfile = false


    private enum Key {
        static let showWeekend = "nativeSchedule.showWeekend"
        static let showDateHeader = "nativeSchedule.showDateHeader"
        static let showFreeTimeCourses = "nativeSchedule.showFreeTimeCourses"
        static let defaultView = "nativeSchedule.defaultView"
        static let density = "nativeSchedule.density"
        static let hideSlotsAfter = "nativeSchedule.hideSlotsAfter"
        static let hideLateSlots = "nativeSchedule.hideLateSlots"
        static let backgroundPath = "nativeSchedule.backgroundPath"
        static let backgroundOpacity = "nativeSchedule.backgroundOpacity"
        static let backgroundOpacityDark = "nativeSchedule.backgroundOpacityDark"
        static let backgroundPlacement = "nativeSchedule.backgroundPlacement"
        static let backgroundPathDark = "nativeSchedule.backgroundPathDark"
        static let backgroundEnabled = "nativeSchedule.backgroundEnabled"
        static let backgroundPlacementDark = "nativeSchedule.backgroundPlacementDark"
        static let tableBackgroundProfiles = "nativeSchedule.tableBackgroundProfiles"
    }

    private struct TableBackgroundProfile: Codable, Equatable {
        var backgroundPath = ""
        var backgroundPathDark = ""
        var backgroundEnabled = true
        var backgroundOpacity = NativeSchedulePreferences.defaultBackgroundOpacity
        var backgroundOpacityDark = NativeSchedulePreferences.defaultDarkOpacity(
            light: NativeSchedulePreferences.defaultBackgroundOpacity
        )
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
        density = Self.densityOptions.contains(savedDensity) ? savedDensity : "comfortable"
        // 旧版本用 hideSlotsAfter = 0 表示不隐藏，还没有单独的开关。
        let savedHideAfter = defaults.object(forKey: Key.hideSlotsAfter) as? Int ?? Self.defaultHideSlotsAfter
        hideLateSlots = defaults.object(forKey: Key.hideLateSlots) as? Bool ?? (savedHideAfter > 0)
        hideSlotsAfter = savedHideAfter > 0 ? Self.clampedHideSlotsAfter(savedHideAfter) : Self.defaultHideSlotsAfter
        backgroundPath = defaults.string(forKey: Key.backgroundPath) ?? ""
        backgroundPathDark = defaults.string(forKey: Key.backgroundPathDark) ?? ""
        backgroundEnabled = defaults.object(forKey: Key.backgroundEnabled) as? Bool ?? true
        let opacity = Self.clampedOpacity(defaults.object(forKey: Key.backgroundOpacity) as? Double ?? Self.defaultBackgroundOpacity)
        backgroundOpacity = opacity
        // 升级上来还没有单独设过深色的，按浅色的值推一个默认值。
        backgroundOpacityDark = Self.clampedOpacity(
            defaults.object(forKey: Key.backgroundOpacityDark) as? Double ?? Self.defaultDarkOpacity(light: opacity)
        )
        backgroundImage = nil
        backgroundImageDark = nil
        loadBackgroundImage()
        globalBackgroundProfile = currentBackgroundProfile
        if let data = defaults.data(forKey: Key.tableBackgroundProfiles),
           let profiles = try? JSONDecoder().decode([String: TableBackgroundProfile].self, from: data) {
            tableBackgroundProfiles = profiles
        }
        ready = true
    }

    /// Switches the background profile used by the timetable surface and by
    /// the per-table settings page. A nil id means a shared/default profile
    /// (for example while viewing a followed shared timetable).
    func activate(tableID: Int?) {
        let key = tableID.map { "table:\($0)" }
        guard key != activeTableKey else { return }
        if ready { saveCurrentBackgroundProfile(promote: false) }
        activeTableKey = key
        activeStorageKey = key.flatMap { tableBackgroundProfiles[$0] == nil ? nil : $0 }
        let profile = key.flatMap { tableBackgroundProfiles[$0] } ?? globalBackgroundProfile
        switchingProfile = true
        backgroundPath = profile.backgroundPath
        backgroundPathDark = profile.backgroundPathDark
        backgroundEnabled = profile.backgroundEnabled
        backgroundOpacity = Self.clampedOpacity(profile.backgroundOpacity)
        backgroundOpacityDark = Self.clampedOpacity(profile.backgroundOpacityDark)
        switchingProfile = false
        loadBackgroundImage()
        objectWillChange.send()
    }

    var activeTableID: Int? {
        guard let key = activeTableKey, key.hasPrefix("table:") else { return nil }
        return Int(key.dropFirst("table:".count))
    }

    var usesDefaultBackground: Bool {
        activeTableKey != nil && activeStorageKey == nil && (backgroundImage != nil || backgroundImageDark != nil)
    }

    private var currentBackgroundProfile: TableBackgroundProfile {
        TableBackgroundProfile(
            backgroundPath: backgroundPath,
            backgroundPathDark: backgroundPathDark,
            backgroundEnabled: backgroundEnabled,
            backgroundOpacity: Self.clampedOpacity(backgroundOpacity),
            backgroundOpacityDark: Self.clampedOpacity(backgroundOpacityDark)
        )
    }

    private func saveCurrentBackgroundProfile(promote: Bool = true) {
        if promote { promoteActiveTableIfNeeded() }
        let profile = currentBackgroundProfile
        if let activeTableKey {
            tableBackgroundProfiles[activeTableKey] = profile
            if let data = try? JSONEncoder().encode(tableBackgroundProfiles) {
                defaults.set(data, forKey: Key.tableBackgroundProfiles)
            }
        } else {
            globalBackgroundProfile = profile
        }
    }

    /// Creates a private copy only when the user edits an inherited table.
    /// Until then the table continues to follow the existing default image.
    private func promoteActiveTableIfNeeded() {
        guard let key = activeTableKey, activeStorageKey == nil else { return }
        let copied = materializeGlobalProfile(for: key)
        activeStorageKey = key
        switchingProfile = true
        backgroundPath = copied.backgroundPath
        backgroundPathDark = copied.backgroundPathDark
        switchingProfile = false
        tableBackgroundProfiles[key] = copied
        if let data = try? JSONEncoder().encode(tableBackgroundProfiles) {
            defaults.set(data, forKey: Key.tableBackgroundProfiles)
        }
    }

    private func materializeGlobalProfile(for tableKey: String) -> TableBackgroundProfile {
        var profile = globalBackgroundProfile
        for dark in [false, true] {
            let source = Self.backgroundFileURL(dark: dark, tableKey: nil)
            let destination = Self.backgroundFileURL(dark: dark, tableKey: tableKey)
            guard !path(dark: dark).isEmpty,
                  FileManager.default.fileExists(atPath: source.path) else {
                if dark { profile.backgroundPathDark = "" } else { profile.backgroundPath = "" }
                continue
            }
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
                if dark { profile.backgroundPathDark = destination.path } else { profile.backgroundPath = destination.path }
                let sourceURL = Self.backgroundSourceURL(dark: dark, tableKey: nil)
                let destinationSource = Self.backgroundSourceURL(dark: dark, tableKey: tableKey)
                if FileManager.default.fileExists(atPath: sourceURL.path) {
                    try? FileManager.default.copyItem(at: sourceURL, to: destinationSource)
                }
                if let placement = defaults.data(forKey: Self.placementKey(dark: dark)) {
                    defaults.set(placement, forKey: placementKey(dark: dark, tableKey: tableKey))
                }
            } catch {
                if dark { profile.backgroundPathDark = "" } else { profile.backgroundPath = "" }
            }
        }
        return profile
    }

    static let viewOptions = ["week", "day", "month"]
    /// 卡片密度：宽松只加高行距，卡片排版和舒适一样；紧凑同时换用小字号卡片。
    static let densityOptions = ["relaxed", "comfortable", "compact"]

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

    /// 课表上实际铺的图：开关关着就是没有。
    func visibleBackgroundImage(dark: Bool) -> ScheduleBackgroundImage? {
        backgroundEnabled ? backgroundImage(dark: dark) : nil
    }

    /// 两种外观里至少有一张图。
    var hasAnyBackground: Bool {
        hasOwnBackground(dark: false) || hasOwnBackground(dark: true)
    }

    /// 这个外观有没有自己的一张图（而不是沿用另一个外观的）。
    func hasOwnBackground(dark: Bool) -> Bool {
        (activeTableKey == nil || activeStorageKey != nil) && !path(dark: dark).isEmpty
    }

    static let defaultHideSlotsAfter = 9

    static func clampedHideSlotsAfter(_ value: Int) -> Int {
        max(1, min(30, value))
    }

    /// 网格画几行：默认画到第 `hideSlotsAfter` 节；这一周最晚的课比它晚，就画到那节课。
    /// `lastOccupiedSlot` 按整周算，所以同一周里每一天、周视图和日视图的行数都一样。
    func visibleSlotCount(total: Int, lastOccupiedSlot: Int) -> Int {
        guard hideLateSlots else { return total }
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
        /// 沿用旧含义：0 表示不隐藏，旧版本 App 读新备份时行为一致。
        var hideSlotsAfter: Int? = nil
        /// 开关关着时 `hideSlotsAfter` 写 0，节数另存在这里，恢复后再打开还是原来的值。
        var hideSlotsAfterCount: Int? = nil
        // Retained for decoding older backups; fixed grid heights ignore it.
        var rowHeight: Double
        var backgroundOpacity: Double
        /// Optional so backups made before this preference existed still decode.
        var backgroundOpacityDark: Double? = nil
        var backgroundImageData: Data?
        /// Optional so backups made before this preference existed still decode.
        var backgroundImageDataDark: Data? = nil
        /// Optional so backups made before this preference existed still decode.
        var backgroundEnabled: Bool? = nil
    }

    func makeSnapshot() -> DisplaySnapshot {
        DisplaySnapshot(
            showWeekend: showWeekend,
            showDateHeader: showDateHeader,
            showFreeTimeCourses: showFreeTimeCourses,
            defaultView: defaultView,
            density: density,
            hideSlotsAfter: hideLateSlots ? hideSlotsAfter : 0,
            hideSlotsAfterCount: hideSlotsAfter,
            rowHeight: 44,
            backgroundOpacity: backgroundOpacity,
            backgroundOpacityDark: backgroundOpacityDark,
            backgroundImageData: backgroundPath.isEmpty
                ? nil
                : try? Data(contentsOf: Self.backgroundFileURL),
            backgroundImageDataDark: backgroundPathDark.isEmpty
                ? nil
                : try? Data(contentsOf: Self.backgroundFileURL(dark: true)),
            backgroundEnabled: backgroundEnabled
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
        let hideAfter = snapshot.hideSlotsAfter ?? Self.defaultHideSlotsAfter
        hideLateSlots = hideAfter > 0
        hideSlotsAfter = Self.clampedHideSlotsAfter(
            snapshot.hideSlotsAfterCount ?? (hideAfter > 0 ? hideAfter : Self.defaultHideSlotsAfter)
        )
        backgroundEnabled = snapshot.backgroundEnabled ?? true
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

    /// Per-table files live in separate directories so switching tables never
    /// overwrites another table's light or dark image.
    private static func backgroundFileURL(dark: Bool, tableKey: String?) -> URL {
        guard let tableKey else { return backgroundFileURL(dark: dark) }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NapTable", isDirectory: true)
            .appendingPathComponent("backgrounds", isDirectory: true)
            .appendingPathComponent(tableKey.replacingOccurrences(of: ":", with: "-"), isDirectory: true)
        return directory.appendingPathComponent(dark ? "dark.jpg" : "light.jpg")
    }

    /// 裁剪前的原图（已缩到长边 3000 像素）。课表页只读裁好的那张。
    static func backgroundSourceURL(dark: Bool) -> URL {
        backgroundFileURL(dark: dark).deletingLastPathComponent()
            .appendingPathComponent(dark ? "schedule-background-dark-source.jpg" : "schedule-background-source.jpg")
    }

    private static func backgroundSourceURL(dark: Bool, tableKey: String?) -> URL {
        backgroundFileURL(dark: dark, tableKey: tableKey).deletingLastPathComponent()
            .appendingPathComponent(dark ? "dark-source.jpg" : "light-source.jpg")
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

    private func placementKey(dark: Bool, tableKey: String?) -> String {
        guard let tableKey else { return Self.placementKey(dark: dark) }
        return "\(Self.placementKey(dark: dark)).\(tableKey)"
    }

    func reset() {
        showWeekend = true
        showDateHeader = true
        showFreeTimeCourses = true
        defaultView = "week"
        density = "comfortable"
        hideLateSlots = true
        hideSlotsAfter = Self.defaultHideSlotsAfter
        backgroundPath = ""
        backgroundPathDark = ""
        backgroundEnabled = true
        backgroundOpacity = Self.defaultBackgroundOpacity
        backgroundOpacityDark = Self.defaultDarkOpacity(light: Self.defaultBackgroundOpacity)
        backgroundImage = nil
        backgroundImageDark = nil
    }

    /// 直接换一张已经裁好的图（从备份恢复时），传 nil 就是移除这个外观的图。
    /// 它和旧原图对不上，所以旧原图和摆放一并清掉，之后再调整就以这张图本身为原图。
    func setBackgroundData(_ data: Data?, dark: Bool = false) throws {
        promoteActiveTableIfNeeded()
        let url = Self.backgroundFileURL(dark: dark, tableKey: activeStorageKey)
        try? FileManager.default.removeItem(at: Self.backgroundSourceURL(dark: dark, tableKey: activeStorageKey))
        defaults.removeObject(forKey: placementKey(dark: dark, tableKey: activeStorageKey))
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
        promoteActiveTableIfNeeded()
        let url = Self.backgroundFileURL(dark: dark, tableKey: activeStorageKey)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: Self.backgroundSourceURL(dark: dark, tableKey: activeStorageKey), options: .atomic)
        try cropped.write(to: url, options: .atomic)
        defaults.set(try? JSONEncoder().encode(placement), forKey: placementKey(dark: dark, tableKey: activeStorageKey))
        // 路径不变时 didSet 照样会触发，裁好的新图会被重新读进来。
        setPath(url.path, dark: dark)
    }

    /// 重新调整时用的原图。没有单独存原图（旧版本设的背景、从备份恢复的背景）
    /// 就拿裁好的那张顶上。
    func backgroundSourceData(dark: Bool = false) -> Data? {
        guard hasOwnBackground(dark: dark) else { return nil }
        return FileManager.default.contents(atPath: Self.backgroundSourceURL(dark: dark, tableKey: activeStorageKey).path)
            ?? FileManager.default.contents(atPath: Self.backgroundFileURL(dark: dark, tableKey: activeStorageKey).path)
    }

    /// 上次的摆放；只有原图还在时才有意义，否则从头摆。
    func backgroundPlacement(dark: Bool = false) -> BackgroundPlacement {
        guard FileManager.default.fileExists(atPath: Self.backgroundSourceURL(dark: dark, tableKey: activeStorageKey).path),
              let data = defaults.data(forKey: placementKey(dark: dark, tableKey: activeStorageKey)),
              let placement = try? JSONDecoder().decode(BackgroundPlacement.self, from: data) else {
            return BackgroundPlacement()
        }
        return placement
    }

    private func loadBackgroundImage() {
        backgroundImage = loadImage(path: backgroundPath, dark: false)
        backgroundImageDark = loadImage(path: backgroundPathDark, dark: true)
    }

    /// 存下来的绝对路径只当「设过背景」的标记用：沙盒目录的 UUID 会在
    /// App 更新或重装后变掉，按旧路径读会让背景图在升级后凭空消失。
    private func loadImage(path: String, dark: Bool) -> ScheduleBackgroundImage? {
        guard !path.isEmpty else { return nil }
        let file = Self.backgroundFileURL(dark: dark, tableKey: activeStorageKey).path
        #if canImport(UIKit)
        return UIImage(contentsOfFile: file)
        #else
        return NSImage(contentsOfFile: file)
        #endif
    }

    private func persist() {
        guard ready, !switchingProfile else { return }
        defaults.set(showWeekend, forKey: Key.showWeekend)
        defaults.set(showDateHeader, forKey: Key.showDateHeader)
        defaults.set(showFreeTimeCourses, forKey: Key.showFreeTimeCourses)
        defaults.set(Self.viewOptions.contains(defaultView) ? defaultView : "week", forKey: Key.defaultView)
        defaults.set(Self.densityOptions.contains(density) ? density : "comfortable", forKey: Key.density)
        defaults.set(hideLateSlots, forKey: Key.hideLateSlots)
        defaults.set(Self.clampedHideSlotsAfter(hideSlotsAfter), forKey: Key.hideSlotsAfter)
        // The legacy keys represent the shared/default profile. A table edit
        // must never overwrite that profile for the next app launch.
        if activeTableKey == nil {
            defaults.set(backgroundPath, forKey: Key.backgroundPath)
            defaults.set(backgroundPathDark, forKey: Key.backgroundPathDark)
            defaults.set(backgroundEnabled, forKey: Key.backgroundEnabled)
            defaults.set(Self.clampedOpacity(backgroundOpacity), forKey: Key.backgroundOpacity)
            defaults.set(Self.clampedOpacity(backgroundOpacityDark), forKey: Key.backgroundOpacityDark)
        }
        saveCurrentBackgroundProfile()
    }
}
