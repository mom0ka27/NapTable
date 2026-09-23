import Foundation

@main
struct ShareRotationChecks {
    @MainActor static func main() throws {
        let defaults = UserDefaults.standard
        let keys = ["naptable.shares", "naptable.shareCode", "naptable.shareToken"]
        let backup = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, backup) { defaults.set(value, forKey: key) } }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let service = ScheduleSharingService.shared
        var table = CourseTable(id: 12, name: "课表", schoolID: "nju", termID: "fall", termWeekCount: 18)
        let first = Course(id: 1, tableId: 12, name: "数学", weeks: [1, 2], weekTime: 1,
                           startTime: 1, timeCount: 1, importType: 1)
        var second = first
        second.name = "物理"
        let fingerprint = try service.shareFingerprint(courses: [first, second], table: table)
        precondition(service.canShare(courses: [first, second], table: table))
        let old = ShareCredential(code: "OLD", token: "token", label: "旧课表", updatedAt: "",
                                  tableID: table.id, fingerprint: fingerprint)
        service.remember(old)
        var reassigned = first
        reassigned.id = 999; reassigned.courseKey = 999; reassigned.weeks = [2, 1]
        precondition(!service.canShare(courses: [second, reassigned], table: table))
        second.classroom = "新教室"
        precondition(service.canShare(courses: [first, second], table: table))
        second.classroom = nil
        table.termVersion = 900
        table.name = "重命名"
        precondition(!service.canShare(courses: [first, second], table: table))
        table.termWeekCount = 19
        precondition(service.canShare(courses: [first, second], table: table))
        let other = ShareCredential(code: "OTHER", token: "token2", label: "另一张", updatedAt: "", tableID: 13)
        service.remember(other)
        service.replaceRemembered([old], with: ShareCredential(code: "NEW", token: "token3", label: "新课表", updatedAt: "", tableID: 12))
        precondition(Set(service.myShares.map(\.code)) == ["OTHER", "NEW"])
        let legacy = Data(#"{"code":"LEGACY","token":"secret","label":"课表","updatedAt":""}"#.utf8)
        let decoded = try JSONDecoder().decode(ShareCredential.self, from: legacy)
        precondition(decoded.tableID == nil)
        print("PASS: change detection, order and ID independence, independent tables, credential replacement, legacy decoding")
    }
}
