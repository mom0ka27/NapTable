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
        expect(fresh.showWeekend && fresh.showFreeTimeCourses,
               "新装默认全部显示")
        fresh.showFreeTimeCourses = false
        let reloaded = NativeSchedulePreferences(defaults: UserDefaults(suiteName: "naptable.checks.fresh")!)
        expect(!reloaded.showFreeTimeCourses, "自由时间开关持久化")
        expect(fresh.visibleDays == Array(1...7), "默认排满七天")
        expect(abs(fresh.backgroundOpacityDark - fresh.backgroundOpacity - 0.1) < 0.0001, "深色默认比浅色高 10%")

        // 隐藏第 N 节之后的行：默认第 9 节，有更晚的课就画到那节课
        expect(fresh.hideSlotsAfter == 9, "默认隐藏第 9 节之后")
        expect(fresh.visibleSlotCount(total: 11, lastOccupiedSlot: 0) == 9, "没课时画到第 9 节")
        expect(fresh.visibleSlotCount(total: 11, lastOccupiedSlot: 6) == 9, "早于第 9 节的课不影响")
        expect(fresh.visibleSlotCount(total: 11, lastOccupiedSlot: 10) == 10, "有第 10 节的课就画到第 10 节")
        expect(fresh.visibleSlotCount(total: 8, lastOccupiedSlot: 0) == 8, "课表只有 8 节时全部画出")
        fresh.hideSlotsAfter = 0
        expect(fresh.visibleSlotCount(total: 11, lastOccupiedSlot: 0) == 11, "关掉后全部显示")
        fresh.hideSlotsAfter = 7
        expect(NativeSchedulePreferences(defaults: UserDefaults(suiteName: "naptable.checks.fresh")!).hideSlotsAfter == 7,
               "隐藏节次持久化")
        expect(fresh.visibleDays(pinnedDays: [6]) == Array(1...7), "显示周末时仍保留七天")

        // 隐藏周末只剩周一到周五
        fresh.showWeekend = false
        expect(fresh.visibleDays == [1, 2, 3, 4, 5], "隐藏周末后 \(fresh.visibleDays)")
        expect(fresh.visibleDays(pinnedDays: []) == [1, 2, 3, 4, 5], "普通周末隐藏")
        expect(fresh.visibleDays(pinnedDays: [6]) == [1, 2, 3, 4, 5, 6], "仅周六调休或有课时保留周六")
        expect(fresh.visibleDays(pinnedDays: [7]) == [1, 2, 3, 4, 5, 7], "仅周日调休或有课时保留周日")
        expect(fresh.visibleDays(pinnedDays: [6, 7]) == Array(1...7), "周末两天都需保留时全部保留")

        // 导出 → JSON → 恢复，逐项还原
        let source = makePreferences("source")
        source.hideSlotsAfter = 6
        source.showWeekend = false
        source.showDateHeader = false
        source.showFreeTimeCourses = false
        source.defaultView = "day"
        source.density = "compact"
        source.backgroundOpacity = 0.33
        source.backgroundOpacityDark = 0.61
        let backgroundBytes = Data("背景图占位字节".utf8)
        try! source.setBackgroundData(backgroundBytes)

        let json = try! encoder.encode(source.makeSnapshot())
        let restored = try! decoder.decode(NativeSchedulePreferences.DisplaySnapshot.self, from: json)
        expect(restored.backgroundImageData == backgroundBytes, "备份带上了背景图字节")

        let target = makePreferences("target")
        target.apply(restored)
        expect(target.hideSlotsAfter == 6, "隐藏节次已还原")
        expect(!target.showWeekend && !target.showDateHeader, "周末与日期栏开关已还原")
        expect(!target.showFreeTimeCourses, "自由时间开关已还原")
        expect(target.defaultView == "day" && target.density == "compact", "视图与密度已还原")
        expect(target.makeSnapshot().rowHeight == 44, "备份行高固定为 44")
        expect(abs(target.backgroundOpacity - 0.33) < 0.0001, "背景不透明度已还原")
        expect(abs(target.backgroundOpacityDark - 0.61) < 0.0001, "深色背景不透明度已还原")
        expect(target.backgroundOpacity(dark: true) == target.backgroundOpacityDark
               && target.backgroundOpacity(dark: false) == target.backgroundOpacity, "按外观取不透明度")
        expect(target.backgroundImage != nil || !target.backgroundPath.isEmpty, "背景图已写回本机")

        // 手改过的备份不能把界面带进非法状态
        let hostile = NativeSchedulePreferences.DisplaySnapshot(
            showWeekend: true,
            showDateHeader: true,
            defaultView: "galaxy",
            density: "airy",
            hideSlotsAfter: -3,
            rowHeight: 9000,
            backgroundOpacity: 12,
            backgroundImageData: nil
        )
        let clamped = makePreferences("clamped")
        clamped.apply(hostile)
        expect(clamped.defaultView == "week", "未知视图回落到周课表")
        expect(clamped.density == "comfortable", "未知密度回落到舒适")
        expect(clamped.makeSnapshot().rowHeight == 44, "旧备份行高不会改变固定布局")
        expect(clamped.backgroundOpacity == 1, "不透明度被夹到上限")
        expect(clamped.backgroundOpacityDark == 1, "旧备份没有深色值时按浅色推算并夹到上限")
        expect(clamped.hideSlotsAfter == 0, "负数节次回落到不隐藏")

        // 旧版显示设置备份没有新字段，恢复后仍默认显示自由时间课程。
        var oldBackup = try! JSONSerialization.jsonObject(with: json) as! [String: Any]
        oldBackup.removeValue(forKey: "showFreeTimeCourses")
        oldBackup.removeValue(forKey: "hideSlotsAfter")
        let oldSnapshot = try! decoder.decode(
            NativeSchedulePreferences.DisplaySnapshot.self,
            from: JSONSerialization.data(withJSONObject: oldBackup)
        )
        target.apply(oldSnapshot)
        expect(target.showFreeTimeCourses, "旧显示设置备份默认显示自由时间课程")
        expect(target.hideSlotsAfter == 9, "旧显示设置备份默认隐藏第 9 节之后")

        // 备份里没有背景图时，保留本机现有的那张
        let keeper = makePreferences("keeper")
        try! keeper.setBackgroundData(Data("本机原有背景".utf8))
        let existingPath = keeper.backgroundPath
        var withoutImage = restored
        withoutImage.backgroundImageData = nil
        keeper.apply(withoutImage)
        expect(keeper.backgroundPath == existingPath, "没带图的备份不会清掉现有背景")

        // 编辑页保存：原图和摆放留着，下次调整接着用
        let placement = NativeSchedulePreferences.BackgroundPlacement(scale: 2.5, offsetX: -0.2, offsetY: 0.1)
        try! keeper.setBackground(cropped: Data("裁好的图".utf8), source: Data("原图".utf8), placement: placement)
        expect(keeper.backgroundSourceData() == Data("原图".utf8), "重新调整时拿到的是原图")
        expect(keeper.backgroundPlacement() == placement, "摆放已保存")
        let reopened = NativeSchedulePreferences(defaults: UserDefaults(suiteName: "naptable.checks.keeper")!)
        expect(reopened.backgroundPlacement() == placement, "摆放重开后仍在")

        // 直接换成一张裁好的图（恢复备份）：旧原图对不上，退回用这张图本身
        try! keeper.setBackgroundData(Data("备份里的图".utf8))
        expect(keeper.backgroundSourceData() == Data("备份里的图".utf8), "没有原图时用裁好的图顶上")
        expect(keeper.backgroundPlacement() == NativeSchedulePreferences.BackgroundPlacement(), "摆放回到默认")

        try! keeper.setBackgroundData(nil)
        expect(keeper.backgroundSourceData() == nil, "移除背景后没有原图")
        expect(!FileManager.default.fileExists(atPath: NativeSchedulePreferences.backgroundSourceURL.path), "原图文件已删")

        // 深色单独一张图：两个外观各存各的，没设的一方沿用另一方
        let pair = makePreferences("pair")
        try! pair.setBackground(cropped: Data("浅色裁图".utf8), source: Data("浅色原图".utf8), placement: .init())
        expect(pair.hasOwnBackground(dark: false) && !pair.hasOwnBackground(dark: true), "只设了浅色")
        expect(pair.backgroundSourceData(dark: true) == nil, "深色没有自己的原图")
        let darkPlacement = NativeSchedulePreferences.BackgroundPlacement(scale: 1.5, offsetX: 0.1, offsetY: 0)
        try! pair.setBackground(cropped: Data("深色裁图".utf8), source: Data("深色原图".utf8), placement: darkPlacement, dark: true)
        expect(pair.hasOwnBackground(dark: true), "深色有了自己的图")
        expect(pair.backgroundSourceData(dark: true) == Data("深色原图".utf8)
               && pair.backgroundSourceData(dark: false) == Data("浅色原图".utf8), "两个外观的原图互不覆盖")
        expect(pair.backgroundPlacement(dark: true) == darkPlacement
               && pair.backgroundPlacement(dark: false) == .init(), "两个外观的摆放互不覆盖")

        let pairBackup = try! decoder.decode(
            NativeSchedulePreferences.DisplaySnapshot.self,
            from: encoder.encode(pair.makeSnapshot())
        )
        expect(pairBackup.backgroundImageDataDark == Data("深色裁图".utf8), "备份带上了深色背景图")

        try! pair.setBackgroundData(nil, dark: true)
        expect(!pair.hasOwnBackground(dark: true) && pair.hasOwnBackground(dark: false), "移除深色图不影响浅色")
        expect(!FileManager.default.fileExists(atPath: NativeSchedulePreferences.backgroundSourceURL(dark: true).path),
               "深色原图文件已删")

        pair.apply(pairBackup)
        expect(pair.hasOwnBackground(dark: true), "恢复备份写回深色背景图")
        try! pair.setBackgroundData(nil)
        try! pair.setBackgroundData(nil, dark: true)

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
