import Foundation

/// 显示偏好随备份导出 / 恢复的离线校验。
///
/// 只编译 `NapTable/Schedule/SchedulePreferences.swift`，不需要模拟器：
/// `tests/check-display-snapshot.sh`
@main
struct DisplaySnapshotChecks {
    static func main() {
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            guard condition else {
                FileHandle.standardError.write(Data("FAIL: \(message())\n".utf8))
                exit(1)
            }
        }

        // 每个用例用独立的 UserDefaults 域，避免污染开发机上的真实偏好。
        func makePreferences(_ name: String) -> NativeSchedulePreferences {
            let suite = "naptable.checks.\(name)"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            guard let defaults = UserDefaults(suiteName: suite) else {
                FileHandle.standardError.write(Data("FAIL: 建不出 \(suite)\n".utf8))
                exit(1)
            }
            return NativeSchedulePreferences(defaults: defaults)
        }

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // 默认值：升级上来的用户布局不变
        let fresh = makePreferences("fresh")
        expect(fresh.showWeekend && fresh.showLocation && fresh.showTeacher && fresh.showWeeks,
               "新装默认全部显示")
        expect(fresh.rowHeight == NativeSchedulePreferences.defaultRowHeight,
               "默认行高是 \(NativeSchedulePreferences.defaultRowHeight)，实际 \(fresh.rowHeight)")
        expect(fresh.visibleDays == Array(1...7), "默认排满七天")

        // 隐藏周末只剩周一到周五
        fresh.showWeekend = false
        expect(fresh.visibleDays == [1, 2, 3, 4, 5], "隐藏周末后 \(fresh.visibleDays)")

        // 导出 → JSON → 恢复，逐项还原
        let source = makePreferences("source")
        source.showLocation = false
        source.showTeacher = false
        source.showWeeks = false
        source.showWeekend = false
        source.showDateHeader = false
        source.defaultView = "day"
        source.density = "compact"
        source.rowHeight = 52
        source.backgroundOpacity = 0.33
        let backgroundBytes = Data("背景图占位字节".utf8)
        try! source.setBackgroundData(backgroundBytes)

        let json = try! encoder.encode(source.makeSnapshot())
        let restored = try! decoder.decode(NativeSchedulePreferences.DisplaySnapshot.self, from: json)
        expect(restored.backgroundImageData == backgroundBytes, "备份带上了背景图字节")

        let target = makePreferences("target")
        target.apply(restored)
        expect(!target.showLocation && !target.showTeacher && !target.showWeeks, "卡片开关已还原")
        expect(!target.showWeekend && !target.showDateHeader, "周末与日期栏开关已还原")
        expect(target.defaultView == "day" && target.density == "compact", "视图与密度已还原")
        expect(target.rowHeight == 52, "行高已还原，实际 \(target.rowHeight)")
        expect(abs(target.backgroundOpacity - 0.33) < 0.0001, "背景不透明度已还原")
        expect(target.backgroundImage != nil || !target.backgroundPath.isEmpty, "背景图已写回本机")

        // 手改过的备份不能把界面带进非法状态
        let hostile = NativeSchedulePreferences.DisplaySnapshot(
            showLocation: true,
            showTeacher: true,
            showWeeks: true,
            showWeekend: true,
            showDateHeader: true,
            defaultView: "galaxy",
            density: "airy",
            rowHeight: 9000,
            backgroundOpacity: 12,
            backgroundImageData: nil
        )
        let clamped = makePreferences("clamped")
        clamped.apply(hostile)
        expect(clamped.defaultView == "week", "未知视图回落到周课表")
        expect(clamped.density == "comfortable", "未知密度回落到舒适")
        expect(clamped.rowHeight == NativeSchedulePreferences.rowHeightRange.upperBound,
               "行高被夹到上限，实际 \(clamped.rowHeight)")
        expect(clamped.backgroundOpacity == 0.5, "不透明度被夹到上限")

        // 备份里没有背景图时，保留本机现有的那张
        let keeper = makePreferences("keeper")
        try! keeper.setBackgroundData(Data("本机原有背景".utf8))
        let existingPath = keeper.backgroundPath
        var withoutImage = restored
        withoutImage.backgroundImageData = nil
        keeper.apply(withoutImage)
        expect(keeper.backgroundPath == existingPath, "没带图的备份不会清掉现有背景")

        // 旧备份没有 display 字段，解码后为 nil 而不是失败
        struct LegacyDocument: Decodable {
            var version: Int
            var display: NativeSchedulePreferences.DisplaySnapshot?
        }
        let legacy = try! decoder.decode(
            LegacyDocument.self,
            from: Data(#"{"version":1}"#.utf8)
        )
        expect(legacy.display == nil && legacy.version == 1, "旧备份仍可解码")

        try? FileManager.default.removeItem(at: NativeSchedulePreferences.backgroundFileURL)
        for name in ["fresh", "source", "target", "clamped", "keeper"] {
            UserDefaults.standard.removePersistentDomain(forName: "naptable.checks.\(name)")
        }
        print("ok")
    }
}
