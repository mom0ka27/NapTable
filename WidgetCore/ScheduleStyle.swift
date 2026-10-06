import Foundation

/// 视觉风格与主题色独立。持久化使用稳定英文标识，未知值回退为当前默认外观。
nonisolated enum ScheduleStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case minimal, grid, table, paper, board

    var id: String { rawValue }
    static let storageKey = "scheduleVisualStyle"

    static func load(from defaults: UserDefaults?) -> Self {
        defaults?.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .minimal
    }

    var title: String {
        switch self {
        case .minimal: "简约"
        case .grid: "格子"
        case .table: "表格"
        case .paper: "素笺"
        case .board: "站牌"
        }
    }

    var subtitle: String {
        switch self {
        case .minimal: "淡彩卡片，轻松查课"
        case .grid: "独立方格，空闲一目了然"
        case .table: "整齐行列，集中呈现课程"
        case .paper: "纸墨色调，安静阅读"
        case .board: "时间优先，关注下一节"
        }
    }

    var symbol: String {
        switch self {
        case .minimal: "rectangle.grid.1x2"
        case .grid: "square.grid.3x3"
        case .table: "tablecells"
        case .paper: "book.closed"
        case .board: "clock"
        }
    }

    var layout: ScheduleStyleLayout {
        switch self {
        case .minimal: .init(grid: .rows, course: .card, cornerRadius: 9, borderWidth: 0, centered: false, font: .rounded)
        case .grid: .init(grid: .cells, course: .card, cornerRadius: 8, borderWidth: 1.5, centered: true, font: .rounded)
        case .table: .init(grid: .table, course: .stripe, cornerRadius: 0, borderWidth: 0, centered: false, font: .standard)
        case .paper: .init(grid: .rows, course: .ink, cornerRadius: 2, borderWidth: 0, centered: false, font: .serif)
        case .board: .init(grid: .sessions, course: .departure, cornerRadius: 2, borderWidth: 0, centered: false, font: .monospaced)
        }
    }
}

nonisolated struct ScheduleStyleLayout: Equatable, Sendable {
    enum Grid: Equatable, Sendable { case rows, cells, table, sessions }
    enum Course: Equatable, Sendable { case card, stripe, ink, departure }
    enum Typography: Equatable, Sendable { case standard, rounded, serif, monospaced }
    let grid: Grid
    let course: Course
    let cornerRadius: Double
    let borderWidth: Double
    let centered: Bool
    let font: Typography
}
