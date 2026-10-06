import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct ImageImportResult: Decodable {
    struct Period: Decodable { var start: String; var end: String }
    struct PartialPeriod: Decodable { var period: Int; var start: String?; var end: String? }
    struct Entry: Decodable {
        var name: String; var teacher: String; var classroom: String
        var weekday: Int; var startPeriod: Int; var endPeriod: Int; var weeks: [Int]
    }
    var semesterStartMonday: String?
    var weekCount: Int?
    var periodCount: Int?
    var classTimes: [Period]
    var periodTimes: [PartialPeriod]?
    var courses: [Entry]
    var warnings: [String]

    func draft(now: Date = Date()) throws -> ManualScheduleDraft {
        guard courses.count <= 200 else { throw ScheduleServiceError.server("识别到的课程超过 200 条，请裁剪课表后重试。") }
        let weeks = weekCount ?? max(SchoolDefaults.defaultWeekCount, courses.flatMap(\.weeks).max() ?? 1)
        guard (1...40).contains(weeks) else { throw ScheduleServiceError.server("识别到的学期总周数不在 1–40 周内。") }
        let times = try resolvedClassTimes()
        var draft = ManualScheduleDraft(name: WeekCalculator.semesterName(for: now),
            semesterStartMonday: WeekCalculator.format(WeekCalculator.monday(of: now)), weekCount: weeks, classTimes: times)
        if let start = semesterStartMonday {
            guard let date = WeekCalculator.parseDay(start), WeekCalculator.format(WeekCalculator.monday(of: date)) == start else {
                throw ScheduleServiceError.server("识别到的学期第一周日期无效，应为星期一。")
            }
            draft.semesterStartMonday = start
            draft.name = WeekCalculator.semesterName(for: date)
        }
        for (index, entry) in courses.enumerated() {
            guard (0...7).contains(entry.weekday), (0...times.count).contains(entry.startPeriod),
                  (0...times.count).contains(entry.endPeriod),
                  entry.startPeriod == 0 || entry.endPeriod == 0 || entry.endPeriod >= entry.startPeriod else {
                throw ScheduleServiceError.server("第 \(index + 1) 条课程的星期或节次超出范围。")
            }
            var meeting = ManualMeetingDraft(weekday: entry.weekday, startPeriod: entry.startPeriod,
                endPeriod: entry.endPeriod, classroom: entry.classroom)
            if !entry.weeks.isEmpty {
                guard entry.weeks.allSatisfy({ (1...weeks).contains($0) }) else {
                    throw ScheduleServiceError.server("第 \(index + 1) 条课程的周次超出了学期总周数。")
                }
            }
            // Empty weeks stay unselected until the user supplies them.
            meeting.kind = .custom
            meeting.customWeeks = Set(entry.weeks)
            let course = ManualCourseDraft(name: entry.name, teacher: entry.teacher, meetings: [meeting])
            if !entry.name.isEmpty, let index = draft.courses.firstIndex(where: { $0.name == entry.name && $0.teacher == entry.teacher }) {
                draft.courses[index].meetings.append(meeting)
            } else { draft.courses.append(course) }
        }
        return draft
    }

    private var requiredPeriodCount: Int {
        max(courses.flatMap { [$0.startPeriod, $0.endPeriod] }.max() ?? 0, periodTimes?.map(\.period).max() ?? 0, classTimes.count)
    }

    private var resolvedPeriodCount: Int {
        periodCount ?? (classTimes.isEmpty ? max(ClassTimeGenerator().periodCount, requiredPeriodCount) : requiredPeriodCount)
    }

    private func resolvedClassTimes() throws -> [ClassTime] {
        let count = resolvedPeriodCount
        guard (1...20).contains(count), requiredPeriodCount <= count else {
            throw ScheduleServiceError.server("识别到的节次超出了每天总节数或 20 节上限。")
        }
        var known: [Int: Period] = [:]
        for (index, period) in classTimes.enumerated() {
            guard !period.start.isEmpty, !period.end.isEmpty else {
                throw ScheduleServiceError.server("第 \(index + 1) 节识别到的上下课时间不完整。")
            }
            known[index + 1] = period
        }
        var seen = Set<Int>()
        for period in periodTimes ?? [] {
            guard (1...count).contains(period.period), seen.insert(period.period).inserted,
                  period.start != nil || period.end != nil else {
                throw ScheduleServiceError.server("识别到的部分节次编号重复、越界或缺少时间。")
            }
            var time = known[period.period] ?? Period(start: "", end: "")
            if let start = period.start {
                guard !start.isEmpty else { throw ScheduleServiceError.server("第 \(period.period) 节的上课时间格式不正确。") }
                guard time.start.isEmpty || time.start == start else { throw ScheduleServiceError.server("第 \(period.period) 节的上课时间互相矛盾。") }
                time.start = start
            }
            if let end = period.end {
                guard !end.isEmpty else { throw ScheduleServiceError.server("第 \(period.period) 节的下课时间格式不正确。") }
                guard time.end.isEmpty || time.end == end else { throw ScheduleServiceError.server("第 \(period.period) 节的下课时间互相矛盾。") }
                time.end = end
            }
            known[period.period] = time
        }
        var previous = -1
        for index in known.keys.sorted() {
            let time = known[index]!
            for clock in [time.start, time.end] where !clock.isEmpty {
                guard let minutes = ClassTimeValidator.minutes(clock), minutes >= previous else {
                    throw ScheduleServiceError.server("第 \(index) 节识别到的时间无效或与前面节次重叠。")
                }
                previous = minutes
            }
            if let start = ClassTimeValidator.minutes(time.start), let end = ClassTimeValidator.minutes(time.end), start == end {
                throw ScheduleServiceError.server("第 \(index) 节识别到的上下课时间相同。")
            }
        }
        var times = ClassTimeGenerator().make()
        if count > times.count {
            times = ClassTimeGenerator(lessonMinutes: 35, smallBreakMinutes: 5, largeBreakMinutes: 10,
                blocks: [.init(title: "全天", start: 8 * 60, count: count)]).make()
        }
        times = Array(times.prefix(count))
        for (index, period) in known {
            if !period.start.isEmpty { times[index - 1].start = period.start }
            if !period.end.isEmpty { times[index - 1].end = period.end }
        }
        // Temporary defaults can conflict with recognized times. Keep the evidence
        // and let the periods step require correction instead of losing all courses.
        return times
    }

    var periodReviewWarnings: [String] {
        guard (1...20).contains(resolvedPeriodCount) else { return [] }
        if classTimes.isEmpty, (periodTimes ?? []).isEmpty {
            return ["未读到节次时间，已暂填 \(resolvedPeriodCount) 节默认作息，请按学校时间修改。"]
        }
        var missing: [String: [Int]] = [:]
        for index in 1...resolvedPeriodCount where index > classTimes.count {
            let period = periodTimes?.first { $0.period == index }
            let fields = [period?.start == nil ? "上课" : nil, period?.end == nil ? "下课" : nil].compactMap { $0 }.joined(separator: "、")
            if !fields.isEmpty { missing[fields, default: []].append(index) }
        }
        var notes = missing.keys.sorted().map { field in
            let periods = missing[field]!.map(String.init).joined(separator: "、")
            return "第 \(periods) 节未读到\(field)时间，已暂填，请核对修改。"
        }
        if let times = try? resolvedClassTimes(), let problem = ClassTimeValidator.problem(in: times) {
            notes.append("暂填作息与已识别时间需要调整：\(problem)。请在节次步骤修正后继续。")
        }
        return notes
    }

    var reviewWarnings: [String] {
        var result = warnings
        if semesterStartMonday == nil { result.append("未读到学期第一周，已暂填本周星期一，请修改。") }
        if weekCount == nil { result.append("未读到学期总周数，请核对。") }
        result.append(contentsOf: periodReviewWarnings)
        if courses.isEmpty { result.append("未识别到课程，已保留可读的学期和节次信息，请在课程步骤手动添加。") }
        if courses.contains(where: { $0.weeks.isEmpty }) { result.append("部分课程未读到周次，已留空，请逐门设置。") }
        if courses.contains(where: { $0.name.isEmpty || $0.weekday == 0 || $0.startPeriod == 0 || $0.endPeriod == 0 }) {
            result.append("部分课程的名称、星期或节次未读到，已保留其他内容，请在课程步骤补全。")
        }
        return Array(Set(result)).sorted()
    }
}

// Missing recognition fields are allowed. Zero denotes an unselected weekday
// or period in the editing draft; it cannot pass the final course validation.
extension ImageImportResult.Entry {
    private enum CodingKeys: String, CodingKey {
        case name, teacher, classroom, weekday, startPeriod, endPeriod, weeks
    }

    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        teacher = try values.decodeIfPresent(String.self, forKey: .teacher) ?? ""
        classroom = try values.decodeIfPresent(String.self, forKey: .classroom) ?? ""
        weekday = try values.decodeIfPresent(Int.self, forKey: .weekday) ?? 0
        startPeriod = try values.decodeIfPresent(Int.self, forKey: .startPeriod) ?? 0
        endPeriod = try values.decodeIfPresent(Int.self, forKey: .endPeriod) ?? 0
        weeks = try values.decodeIfPresent([Int].self, forKey: .weeks) ?? []
    }
}

extension ImageImportResult {
    private enum CodingKeys: String, CodingKey {
        case semesterStartMonday, weekCount, periodCount, classTimes, periodTimes, courses, warnings
    }

    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        semesterStartMonday = try values.decodeIfPresent(String.self, forKey: .semesterStartMonday)
        weekCount = try values.decodeIfPresent(Int.self, forKey: .weekCount)
        periodCount = try values.decodeIfPresent(Int.self, forKey: .periodCount)
        classTimes = try values.decodeIfPresent([Period].self, forKey: .classTimes) ?? []
        periodTimes = try values.decodeIfPresent([PartialPeriod].self, forKey: .periodTimes)
        courses = try values.decodeIfPresent([Entry].self, forKey: .courses) ?? []
        warnings = try values.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

@MainActor enum ImageImportService {
    struct Configuration: Decodable { var enabled: Bool; var maxImageBytes: Int }

    static func configuration() async throws -> Configuration {
        try JSONDecoder().decode(Configuration.self, from: await request(path: "v1/import/image/config", body: nil))
    }

    static func recognize(_ image: Data) async throws -> ImageImportResult {
        let data = try await request(path: "v1/import/image", body: ["imageBase64": image.base64EncodedString()])
        do { return try JSONDecoder().decode(ImageImportResult.self, from: data) }
        catch {
            throw ScheduleServiceError.server("识别服务返回的课表数据格式不正确，请稍后重试；持续出现时请联系管理员。")
        }
    }

    private static func request(path: String, body: [String: String]?) async throws -> Data {
        guard let base = ScheduleSharingService.shared.validatedBaseURL, base.scheme == "https" else {
            throw ScheduleServiceError.missingBaseURL
        }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = 100
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: AppAttestService.shared.signed(request))
        AppAttestService.shared.observe(response)
        guard let http = response as? HTTPURLResponse else { throw ScheduleServiceError.invalidResponse }
        guard http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ScheduleServiceError.server(message ?? "图片导入请求失败（HTTP \(http.statusCode)），请稍后再试。")
        }
        return data
    }

    /// Downsample before decoding full pixels; re-encode to omit EXIF and other metadata.
    nonisolated static func prepare(_ data: Data) throws -> Data {
        guard data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2400
              ] as CFDictionary) else { throw ScheduleServiceError.server("无法读取图片，请选择静态课表截图。") }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScheduleServiceError.invalidResponse
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flattened = context.makeImage() else { throw ScheduleServiceError.invalidResponse }
        for quality in [0.9, 0.75, 0.55] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw ScheduleServiceError.invalidResponse
            }
            CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length <= 3 * 1024 * 1024 { return output as Data }
        }
        throw ScheduleServiceError.server("图片过大，请裁剪到课表区域后重试。")
    }
}
