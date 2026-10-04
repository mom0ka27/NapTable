import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct ImageImportResult: Decodable {
    struct Period: Decodable { var start: String; var end: String }
    struct Entry: Decodable {
        var name: String; var teacher: String; var classroom: String
        var weekday: Int; var startPeriod: Int; var endPeriod: Int; var weeks: [Int]
    }
    var name: String
    var semesterStartMonday: String?
    var weekCount: Int?
    var classTimes: [Period]
    var courses: [Entry]
    var warnings: [String]

    func draft() throws -> ManualScheduleDraft {
        guard !courses.isEmpty, courses.count <= 200 else {
            throw ScheduleServiceError.server("没有识别到课程，请换一张清晰、完整的课表图片。")
        }
        let weeks = weekCount ?? max(SchoolDefaults.defaultWeekCount, courses.flatMap(\.weeks).max() ?? 1)
        guard (1...40).contains(weeks) else { throw ScheduleServiceError.invalidResponse }
        let maxPeriod = courses.map(\.endPeriod).max() ?? 1
        guard (1...20).contains(maxPeriod) else { throw ScheduleServiceError.invalidResponse }
        var times = classTimes.map { ClassTime(start: $0.start, end: $0.end) }
        if times.isEmpty {
            times = ClassTimeGenerator().make()
            if maxPeriod > times.count {
                times = ClassTimeGenerator(lessonMinutes: 35, smallBreakMinutes: 5, largeBreakMinutes: 10,
                    blocks: [.init(title: "全天", start: 8 * 60, count: maxPeriod)]).make()
            }
        }
        guard times.count <= 20, ClassTimeValidator.problem(in: times) == nil else { throw ScheduleServiceError.invalidResponse }
        var draft = ManualScheduleDraft(name: name, weekCount: weeks, classTimes: times)
        if let start = semesterStartMonday {
            guard let date = WeekCalculator.parseDay(start), WeekCalculator.format(WeekCalculator.monday(of: date)) == start else {
                throw ScheduleServiceError.invalidResponse
            }
            draft.semesterStartMonday = start
        }
        for entry in courses {
            var meeting = ManualMeetingDraft(weekday: entry.weekday, startPeriod: entry.startPeriod,
                endPeriod: entry.endPeriod, classroom: entry.classroom)
            if !entry.weeks.isEmpty {
                guard entry.weeks.allSatisfy({ (1...weeks).contains($0) }) else { throw ScheduleServiceError.invalidResponse }
                meeting.kind = .custom
                meeting.customWeeks = Set(entry.weeks)
            }
            let course = ManualCourseDraft(name: entry.name, teacher: entry.teacher, meetings: [meeting])
            guard course.problem(periodCount: times.count, weekCount: weeks) == nil else { throw ScheduleServiceError.invalidResponse }
            if let index = draft.courses.firstIndex(where: { $0.name == entry.name && $0.teacher == entry.teacher }) {
                draft.courses[index].meetings.append(meeting)
            } else { draft.courses.append(course) }
        }
        return draft
    }

    var reviewWarnings: [String] {
        var result = warnings
        if semesterStartMonday == nil { result.append("未读到学期第一周，已暂填本周星期一，请修改。") }
        if weekCount == nil { result.append("未读到学期总周数，请核对。") }
        if classTimes.isEmpty { result.append("未读到完整节次时间，已暂填默认作息，请按学校时间修改。") }
        if courses.contains(where: { $0.weeks.isEmpty }) { result.append("部分课程未标明周次，已暂填全学期，请逐门确认。") }
        return Array(Set(result)).sorted()
    }
}

@MainActor enum ImageImportService {
    struct Configuration: Decodable { var enabled: Bool; var maxImageBytes: Int }

    static func configuration() async throws -> Configuration {
        try JSONDecoder().decode(Configuration.self, from: await request(path: "v1/import/image/config", body: nil))
    }

    static func recognize(_ image: Data) async throws -> ImageImportResult {
        try JSONDecoder().decode(ImageImportResult.self, from: await request(path: "v1/import/image", body: ["imageBase64": image.base64EncodedString()]))
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
            throw ScheduleServiceError.server(message ?? "图片导入暂不可用，请稍后再试")
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
