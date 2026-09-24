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

    /// What each course card prints under the course name.
    @Published var showLocation: Bool { didSet { persist() } }
    @Published var showTeacher: Bool { didSet { persist() } }
    @Published var showWeeks: Bool { didSet { persist() } }
    /// Whether the week grid and the day picker include 周六/周日.
    @Published var showWeekend: Bool { didSet { persist() } }
    @Published var showDateHeader: Bool { didSet { persist() } }
    @Published var showFreeTimeCourses: Bool { didSet { persist() } }
    @Published var defaultView: String { didSet { persist() } }
    @Published var density: String { didSet { persist() } }
    @Published var backgroundPath: String { didSet { loadBackgroundImage(); persist() } }
    @Published var backgroundOpacity: Double { didSet { persist() } }
    @Published private(set) var backgroundImage: ScheduleBackgroundImage?

    private let defaults: UserDefaults
    private var ready = false


    private enum Key {
        static let showLocation = "nativeSchedule.showLocation"
        static let showTeacher = "nativeSchedule.showTeacher"
        static let showWeeks = "nativeSchedule.showWeeks"
        static let showWeekend = "nativeSchedule.showWeekend"
        static let showDateHeader = "nativeSchedule.showDateHeader"
        static let showFreeTimeCourses = "nativeSchedule.showFreeTimeCourses"
        static let defaultView = "nativeSchedule.defaultView"
        static let density = "nativeSchedule.density"
        static let backgroundPath = "nativeSchedule.backgroundPath"
        static let backgroundOpacity = "nativeSchedule.backgroundOpacity"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showLocation = defaults.object(forKey: Key.showLocation) as? Bool ?? true
        showTeacher = defaults.object(forKey: Key.showTeacher) as? Bool ?? true
        showWeeks = defaults.object(forKey: Key.showWeeks) as? Bool ?? true
        showWeekend = defaults.object(forKey: Key.showWeekend) as? Bool ?? true
        showDateHeader = defaults.object(forKey: Key.showDateHeader) as? Bool ?? true
        showFreeTimeCourses = defaults.object(forKey: Key.showFreeTimeCourses) as? Bool ?? true
        let savedView = defaults.string(forKey: Key.defaultView) ?? "week"
        defaultView = Self.viewOptions.contains(savedView) ? savedView : "week"
        let savedDensity = defaults.string(forKey: Key.density) ?? "comfortable"
        density = savedDensity == "compact" ? "compact" : "comfortable"
        backgroundPath = defaults.string(forKey: Key.backgroundPath) ?? ""
        let opacity = defaults.object(forKey: Key.backgroundOpacity) as? Double ?? 0.18
        backgroundOpacity = min(0.5, max(0.05, opacity))
        backgroundImage = nil
        loadBackgroundImage()
        ready = true
    }

    static let viewOptions = ["week", "day", "month"]
    static let densityOptions = ["comfortable", "compact"]

    /// The weekday columns the grid draws, Monday-first.
    var visibleDays: [Int] { showWeekend ? Array(1...7) : Array(1...5) }

    /// 隐藏普通周末时，仍保留当前周有调休安排的日期。
    func visibleDays(adjustedDays: Set<Int>) -> [Int] {
        (1...7).filter { showWeekend || $0 <= 5 || adjustedDays.contains($0) }
    }

    // MARK: Backup

    /// These values live in `UserDefaults` rather than the app's JSON state
    /// file, so they need their own representation to ride along in an exported
    /// backup. The background image travels as its file bytes (base64 in the
    /// JSON), which is the only part of a backup that can get large.
    struct DisplaySnapshot: Codable, Equatable {
        var showLocation: Bool
        var showTeacher: Bool
        var showWeeks: Bool
        var showWeekend: Bool
        var showDateHeader: Bool
        /// Optional so backups made before this preference existed still decode.
        var showFreeTimeCourses: Bool? = nil
        var defaultView: String
        var density: String
        // Retained for decoding older backups; fixed grid heights ignore it.
        var rowHeight: Double
        var backgroundOpacity: Double
        var backgroundImageData: Data?
    }

    func makeSnapshot() -> DisplaySnapshot {
        DisplaySnapshot(
            showLocation: showLocation,
            showTeacher: showTeacher,
            showWeeks: showWeeks,
            showWeekend: showWeekend,
            showDateHeader: showDateHeader,
            showFreeTimeCourses: showFreeTimeCourses,
            defaultView: defaultView,
            density: density,
            rowHeight: 44,
            backgroundOpacity: backgroundOpacity,
            backgroundImageData: backgroundPath.isEmpty
                ? nil
                : try? Data(contentsOf: URL(fileURLWithPath: backgroundPath))
        )
    }

    /// Display preferences are single values, so a restore replaces them rather
    /// than merging the way tables and courses do.
    func apply(_ snapshot: DisplaySnapshot) {
        showLocation = snapshot.showLocation
        showTeacher = snapshot.showTeacher
        showWeeks = snapshot.showWeeks
        showWeekend = snapshot.showWeekend
        showDateHeader = snapshot.showDateHeader
        showFreeTimeCourses = snapshot.showFreeTimeCourses ?? true
        defaultView = Self.viewOptions.contains(snapshot.defaultView) ? snapshot.defaultView : "week"
        density = Self.densityOptions.contains(snapshot.density) ? snapshot.density : "comfortable"
        backgroundOpacity = min(0.5, max(0.05, snapshot.backgroundOpacity))
        // A backup without an image leaves the current one alone; clearing is an
        // explicit action in settings, not a side effect of restoring.
        if let data = snapshot.backgroundImageData, !data.isEmpty {
            try? setBackgroundData(data)
        }
    }

    /// NapTable keeps its own copy: CpuTime wrote into `Application Support/CPUTime`,
    /// which would collide with the real client when both are installed.
    static var backgroundFileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NapTable", isDirectory: true)
        return directory.appendingPathComponent("schedule-background.jpg")
    }

    func reset() {
        showLocation = true
        showTeacher = true
        showWeeks = true
        showWeekend = true
        showDateHeader = true
        showFreeTimeCourses = true
        defaultView = "week"
        density = "comfortable"
        backgroundPath = ""
        backgroundOpacity = 0.18
        backgroundImage = nil
    }

    func setBackgroundData(_ data: Data?) throws {
        let url = Self.backgroundFileURL
        if let data {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            backgroundPath = url.path
        } else {
            try? FileManager.default.removeItem(at: url)
            backgroundPath = ""
        }
    }

    private func loadBackgroundImage() {
        guard !backgroundPath.isEmpty else {
            backgroundImage = nil
            return
        }
        #if canImport(UIKit)
        backgroundImage = UIImage(contentsOfFile: backgroundPath)
        #else
        backgroundImage = NSImage(contentsOfFile: backgroundPath)
        #endif
    }

    private func persist() {
        guard ready else { return }
        defaults.set(showLocation, forKey: Key.showLocation)
        defaults.set(showTeacher, forKey: Key.showTeacher)
        defaults.set(showWeeks, forKey: Key.showWeeks)
        defaults.set(showWeekend, forKey: Key.showWeekend)
        defaults.set(showDateHeader, forKey: Key.showDateHeader)
        defaults.set(showFreeTimeCourses, forKey: Key.showFreeTimeCourses)
        defaults.set(Self.viewOptions.contains(defaultView) ? defaultView : "week", forKey: Key.defaultView)
        defaults.set(Self.densityOptions.contains(density) ? density : "comfortable", forKey: Key.density)
        defaults.set(backgroundPath, forKey: Key.backgroundPath)
        defaults.set(min(0.5, max(0.05, backgroundOpacity)), forKey: Key.backgroundOpacity)
    }
}
