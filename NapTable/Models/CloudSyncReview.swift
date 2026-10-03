import Foundation

nonisolated enum CloudTableDestination: Equatable {
    case matching, current(Int), new
}

nonisolated struct CloudSyncChange: Identifiable {
    enum Direction { case upload, download }
    let key: String
    let direction: Direction
    let title: String
    let details: [String]
    let device: String
    let modifiedAt: Date
    let incomingTable: CloudTable?
    var id: String { (direction == .upload ? "upload:" : "download:") + key }
}

nonisolated struct CloudSyncReview: Identifiable {
    let id: UUID
    let account: String
    let local: CloudSyncDocument
    let remote: CloudSyncDocument
    let merged: CloudSyncDocument
    let changes: [CloudSyncChange]

    init(account: String, local: CloudSyncDocument, remote: CloudSyncDocument, id: UUID = UUID()) {
        self.id = id
        self.account = account
        self.local = local
        self.remote = remote
        merged = local.merged(with: remote)
        var changes: [CloudSyncChange] = []
        for (key, entry) in merged.entries.sorted(by: { $0.key < $1.key }) {
            let previous = local.entries[key]
            guard Self.requiresConfirmation(before: previous?.payload, after: entry.payload) else { continue }
            var incoming: CloudTable?
            if case .table(let table) = entry.payload { incoming = table }
            changes.append(CloudSyncChange(key: key, direction: .download,
                title: Self.title(entry.payload ?? previous?.payload, key: key),
                details: Self.details(before: previous?.payload, after: entry.payload),
                device: entry.writerName ?? "设备 \(entry.writer.prefix(6))（旧版未记录名称）",
                modifiedAt: entry.modifiedAt, incomingTable: incoming))
        }
        self.changes = changes
    }

    /// Only incoming timetable content needs confirmation. Metadata/settings,
    /// credentials, caring selection and local uploads are automatic.
    private static func requiresConfirmation(before: CloudSyncPayload?, after: CloudSyncPayload?) -> Bool {
        switch (before, after) {
        case (.table(let a), .table(let b)): return a.courses != b.courses
        case (.shared(let a), .shared(let b)): return a.courses != b.courses || a.isRevoked != b.isRevoked
        case (_, .table), (_, .shared): return true
        case (.table, nil), (.shared, nil): return true
        default: return false
        }
    }

    static func sameCourseContent(_ a: CloudSyncPayload?, _ b: CloudSyncPayload?) -> Bool {
        switch (a, b) {
        case (.table(let a), .table(let b)): return a.courses == b.courses
        case (.shared(let a), .shared(let b)): return a.courses == b.courses && a.isRevoked == b.isRevoked
        case (nil, nil): return true
        default: return false
        }
    }

    func hasSameCourseChanges(as other: Self) -> Bool {
        guard changes.map(\.key) == other.changes.map(\.key) else { return false }
        return changes.allSatisfy { change in
            Self.sameCourseContent(merged.entries[change.key]?.payload, other.merged.entries[change.key]?.payload)
                && Self.sameCourseContent(local.entries[change.key]?.payload, other.local.entries[change.key]?.payload)
        }
    }

    /// Keep unapproved timetable content on this device while independently
    /// applying settings and credentials. The cloud still retains the full merge.
    func automaticDocument() -> CloudSyncDocument {
        var document = merged
        for change in changes { document.entries[change.key] = local.entries[change.key] }
        if case .caring(let selection) = document.entries["settings:caring"]?.payload,
           let code = selection.code, document.entries["shared:" + code]?.payload == nil {
            document.entries["settings:caring"] = local.entries["settings:caring"]
        }
        return document
    }

    private static func title(_ payload: CloudSyncPayload?, key: String) -> String {
        switch payload {
        case .table(let value): return "课表：\(value.table.name)"
        case .shared(let value): return "共享课表：\(value.name)"
        case .credential(let value): return "分享管理：\(value.credential.label)"
        case .caring: return "关心对象"
        case .notifications: return "通知设置"
        case nil: return key.hasPrefix("table:") ? "已删除的课表" : "已删除的记录"
        }
    }

    private static func details(before: CloudSyncPayload?, after: CloudSyncPayload?) -> [String] {
        guard let after else { return ["删除这条记录"] }
        guard before != after else { return ["更新同步记录版本，内容不变"] }
        switch after {
        case .table(let value):
            guard case .table(let old) = before else {
                return ["新增课表，\(value.courses.count) 条课程记录"] + value.courses.map { "新增课程：\($0.name)" }
            }
            return tableDetails(old, value)
        case .shared(let value):
            var result = [before == nil ? "保存共享课表 \(value.meta.code)" : "更新共享课表 \(value.meta.code)"]
            if case .shared(let old) = before {
                if old.remark != value.remark { result.append("备注：\(old.remark ?? "无") → \(value.remark ?? "无")") }
                if old.courses != value.courses { result.append("课程内容更新，共 \(value.courses.count) 条记录") }
                if old.classTimes != value.classTimes { result.append("节次时间更新") }
                if old.adjustments != value.adjustments { result.append("调休安排更新") }
                if old.revoked != value.revoked { result.append(value.isRevoked ? "分享已撤销" : "分享状态更新") }
            } else { result.append("备注：\(value.remark ?? "无")") }
            return result
        case .credential:
            return [before == nil ? "新增分享管理凭证，可在本机更新或撤销该分享" : "更新分享管理凭证"]
        case .caring(let value):
            if case .caring(let old) = before { return ["\(old.code ?? "未关心") → \(value.code ?? "未关心")"] }
            return [value.code.map { "关心共享课表 \($0)" } ?? "取消关心"]
        case .notifications: return []
        }
    }

    static func tableDetails(_ old: CloudTable, _ new: CloudTable) -> [String] {
        var result: [String] = []
        let a = old.table, b = new.table
        if a.name != b.name { result.append("名称：\(a.name) → \(b.name)") }
        if a.semesterStartMonday != b.semesterStartMonday { result.append("第一周周一：\(a.semesterStartMonday) → \(b.semesterStartMonday)") }
        if a.termWeekCount != b.termWeekCount { result.append("学期周数：\(a.termWeekCount ?? 0) → \(b.termWeekCount ?? 0)") }
        if a.classTimeList != b.classTimeList { result.append("节次时间更新") }
        if a.seasonalPeriods != b.seasonalPeriods { result.append("季节作息更新") }
        if a.calendarAdjustments != b.calendarAdjustments { result.append("课表调休安排更新") }
        if a.unifiedHolidaysEnabled != b.unifiedHolidaysEnabled { result.append("统一放假设置更新") }
        if a.unifiedMakeupEnabled != b.unifiedMakeupEnabled { result.append("统一补班设置更新") }
        if a.schoolID != b.schoolID || a.termID != b.termID || a.termVersion != b.termVersion || a.termTimezone != b.termTimezone {
            result.append("学校或学期配置更新")
        }
        if a.serviceConfigurationUpdatesEnabled != b.serviceConfigurationUpdatesEnabled { result.append("学校配置自动更新设置变更") }
        // Ignore local/canonical integer IDs when matching course rows.
        func normalized(_ course: Course) -> Course {
            var value = course
            value.id = 0; value.tableId = 0; value.courseKey = nil
            return value
        }
        var remaining = old.courses.map(normalized)
        var changed: [Course] = []
        for course in new.courses.map(normalized) {
            if let index = remaining.firstIndex(of: course) { remaining.remove(at: index) }
            else { changed.append(course) }
        }
        for course in changed {
            if let index = remaining.firstIndex(where: { $0.name == course.name }) {
                let previous = remaining.remove(at: index)
                var fields: [String] = []
                if previous.teacher != course.teacher { fields.append("教师：\(previous.teacher ?? "无") → \(course.teacher ?? "无")") }
                if previous.classroom != course.classroom { fields.append("教室：\(previous.classroom ?? "无") → \(course.classroom ?? "无")") }
                if previous.weeks != course.weeks { fields.append("周次更新") }
                if previous.weekTime != course.weekTime || previous.startTime != course.startTime || previous.timeCount != course.timeCount { fields.append("上课时间更新") }
                if previous.isHidden != course.isHidden { fields.append(course.isHidden ? "隐藏课程" : "显示课程") }
                if previous.info != course.info { fields.append("备注更新") }
                if previous.link != course.link { fields.append("课程链接更新") }
                if previous.classNumber != course.classNumber { fields.append("班级信息更新") }
                if previous.testTime != course.testTime || previous.testLocation != course.testLocation { fields.append("考试信息更新") }
                if previous.color != course.color { fields.append("课程颜色更新") }
                if previous.displayPriority != course.displayPriority { fields.append("重叠课程显示顺序更新") }
                if fields.isEmpty { fields.append("课程信息更新") }
                result.append("课程「\(course.name)」：" + fields.joined(separator: "，"))
            } else { result.append("新增课程：\(course.name)") }
        }
        result += remaining.map { "删除课程：\($0.name)" }
        if old.courses.map(\.courseKey) != new.courses.map(\.courseKey) { result.append("课程分组更新") }
        return result.isEmpty ? ["课表信息更新"] : result
    }
}
