import Foundation

/// 调休解析的回归检查：`CalendarAdjustmentResolver` 把服务端下发的日期表换算成
/// 「第几周 / 星期几」，课表、月历、小组件和实时活动都按它覆盖课程。
///
/// 只编译模型层，不需要模拟器：`tests/check-calendar-adjustment.sh`
@main
struct CalendarAdjustmentChecks {
    static func main() {
        var failures = 0

        func expect(_ condition: Bool, _ message: String) {
            if condition {
                print("✅ \(message)")
            } else {
                failures += 1
                print("❌ \(message)")
            }
        }

        // 学期第一周周一 = 2026-09-14。10 月 1、2 日放假，10 月 11 日（周日）补 10 月
        // 9 日（周五）的课——日期只是样例，形状和国务院通知一致就够了。
        let anchor = "2026-09-14"
        let index = CalendarAdjustmentResolver.index([
            CalendarAdjustment(date: "2026-10-01", kind: .off, note: "国庆节"),
            CalendarAdjustment(date: "2026-10-02", kind: .off),
            CalendarAdjustment(date: "2026-10-11", kind: .swap, source: "2026-10-09"),
        ], semesterStartMonday: anchor)

        expect(index.count == 4, "三条配置调整和一个被调走的来源日期都解析出来了")

        if let off = index["2026-10-01"] {
            expect(off.kind == .off && off.suppressesCourses, "放假那天不画课")
            expect(off.badge == "休", "放假角标是「休」")
            expect(off.detail == "国庆节", "有说明时用服务端给的说明")
        } else {
            expect(false, "10 月 1 日应该有调整")
        }

        expect(index["2026-10-02"]?.detail == "放假，不上课", "没写说明时兜底一句话")

        if let swap = index["2026-10-11"] {
            // 2026-09-14 是第 1 周周一，10-05 那周是第 4 周；10-09 和 10-11 在同一周。
            expect(swap.sourceDay == 5, "补 10 月 9 日的课 → 星期五，实际 \(swap.sourceDay.map(String.init) ?? "nil")")
            expect(swap.sourceWeek == 4, "10 月 9 日在第 4 周，实际 \(swap.sourceWeek.map(String.init) ?? "nil")")
            expect(!swap.suppressesCourses, "补班那天要画课")
            expect(swap.badge == "班", "补班角标是「班」")
            expect(swap.detail == "上 10.9 周五的课", "兜底说明写清楚上哪天的课：\(swap.detail)")
        } else {
            expect(false, "10 月 11 日应该有调整")
        }

        // 跨周调课：下周一的课挪到这周日上，周次要跟着源日期走，不能留在本周。
        let crossWeek = CalendarAdjustmentResolver.index([
            CalendarAdjustment(date: "2026-09-20", kind: .swap, source: "2026-09-21"),
        ], semesterStartMonday: anchor)
        expect(crossWeek["2026-09-20"]?.sourceWeek == 2, "源日期在下一周时取下一周的周次")
        expect(crossWeek["2026-09-20"]?.sourceDay == 1, "9 月 21 日是周一")

        // 学期锚点缺失时不能瞎猜周次：解析不出周次就当这天没课，而不是画错的课。
        let noAnchor = CalendarAdjustmentResolver.index([
            CalendarAdjustment(date: "2026-10-11", kind: .swap, source: "2026-10-09"),
        ], semesterStartMonday: "")
        expect(noAnchor["2026-10-11"]?.sourceWeek == nil, "没有学期锚点就算不出周次")
        expect(noAnchor["2026-10-11"]?.suppressesCourses == true, "算不出周次时宁可不画课")

        // 调课缺 source 会把一天的课悄悄删掉，服务端已经拦了，客户端再兜一次底。
        let brokenSwap = CalendarAdjustmentResolver.index([
            CalendarAdjustment(date: "2026-10-11", kind: .swap, source: "   "),
        ], semesterStartMonday: anchor)
        expect(brokenSwap["2026-10-11"]?.sourceDay == nil, "调课没写源日期时不解析出星期")

        // 同一天写两次：后面的覆盖前面的，和服务端列表顺序一致。
        let duplicated = CalendarAdjustmentResolver.index([
            CalendarAdjustment(date: "2026-10-01", kind: .off, note: "先写的"),
            CalendarAdjustment(date: "2026-10-01", kind: .off, note: "后写的"),
        ], semesterStartMonday: anchor)
        expect(duplicated["2026-10-01"]?.note == "后写的", "同一天重复时后面的生效")

        let movedSource = CalendarAdjustmentResolver.index([
            CalendarAdjustment(date: "2026-10-11", kind: .swap, source: "2026-10-09"),
        ], semesterStartMonday: anchor)
        expect(movedSource["2026-10-09"]?.suppressesCourses == true, "被调走的来源日期不重复显示课程")

        // 老存档没有这个键，解码要能落到 nil 而不是抛错。
        struct Legacy: Codable { var name: String }
        let table = try! JSONDecoder().decode(
            CourseTable.self,
            from: #"{"id":1,"name":"默认课表","classTimeList":[],"semesterStartMonday":"2026-09-14"}"#.data(using: .utf8)!
        )
        expect(table.calendarAdjustments == nil, "旧存档没有调休字段也能解码")
        expect(table.calendarAdjustmentIndex(anchor: anchor).isEmpty, "没有调休时索引是空的")

        // 服务端 JSON 走的是 CoursePayloadCodec，字段名和 kind 取值要对上。
        let decoded = CoursePayloadCodec.decodeAdjustments([
            ["date": "2026-10-11", "kind": "swap", "source": "2026-10-09", "note": "补周四"],
            ["date": "2026-10-01", "kind": "off", "note": "国庆节"],
            ["date": "坏日期", "kind": "off"],
            ["date": "2026-10-12", "kind": "swap"],
        ])
        expect(decoded?.count == 2, "坏日期和缺源日期的调课都被丢掉，实际 \(decoded?.count ?? -1)")
        expect(decoded?.first?.kind == .swap && decoded?.first?.source == "2026-10-09", "调课的源日期解析出来了")

        print(failures == 0 ? "\n全部通过" : "\n\(failures) 项未通过")
        exit(failures == 0 ? 0 : 1)

    }
}
