import Foundation

/// Turns whatever an importer produced into an `ImportedSchedule`.
///
/// The Flutter app had this spread across `ImportFromBEView.import`,
/// `ImportFromJWPresenter.getClasses` and the two `CourseParser` classes: a
/// WebView extractor returns JSON, the direct NJU client returns HTML. Both
/// arrive here so a caller only has to deal with one outcome type.
@MainActor
final class ImportPipeline {
    static let shared = ImportPipeline()

    enum Outcome {
        case success(ImportedSchedule)
        case failure(ImportError)
    }

    /// Strings shorter than this cannot be a course page.
    private static let minimumHTMLHint = 200

    func ingest(payload: String, school: SchoolConfig?, completion: @escaping (Outcome) -> Void) {
        let text = decodePayload(payload)
        guard !text.isEmpty else {
            completion(.failure(.emptyResult("导入结果为空，请确认已登录并停留在课表页面")))
            return
        }
        if looksLikeJSON(text) {
            do {
                var schedule = try CoursePayloadCodec.decode(json: text)
                if schedule.courses.isEmpty {
                    completion(.failure(.emptyResult("课表页面没有课程，可能是当前学期没有选课")))
                    return
                }
                schedule.name = normalizedName(schedule.name, school: school)
                // The extractors only return `{name, courses}`. The bell
                // schedule and the semester anchor ship with the school entry —
                // the same data the Flutter app writes out of
                // `widget.config['semester_start_monday']` in `ImportFromBEView`
                // — so fall back to them here instead of dropping them. Without
                // this the table never learns when week 1 started and the app
                // can only ever sit on week 1.
                if schedule.classTimeList == nil, let list = school?.classTimeList {
                    schedule.classTimeList = list
                }
                if schedule.semesterStartMonday == nil,
                   let start = school?.semesterStartMonday,
                   !start.isEmpty {
                    schedule.semesterStartMonday = start
                }
                completeWithSchoolTemplate(schedule, school: school, completion: completion)
            } catch let error as ImportError {
                completion(.failure(error))
            } catch {
                completion(.failure(.malformedPayload(error.localizedDescription)))
            }
            return
        }
        switch parse(html: text, school: school) {
        case .success(let schedule): completeWithSchoolTemplate(schedule, school: school, completion: completion)
        case .failure(let error): completion(.failure(error))
        }
    }

    private func completeWithSchoolTemplate(
        _ schedule: ImportedSchedule, school: SchoolConfig?, completion: @escaping (Outcome) -> Void
    ) {
        guard let school else { completion(.success(schedule)); return }
        Task { @MainActor in
            do {
                let schools = try await ScheduleSharingService.shared.loadSchools()
                let resolved = try SchoolTemplateResolver.applying(
                    to: schedule, schoolID: school.serviceSchoolID, schools: schools
                )
                completion(.success(resolved))
            } catch {
                completion(.failure(.malformedPayload("无法读取对应学校的学期配置：\(error.localizedDescription)。课程尚未写入，可重试导入。")))
            }
        }
    }

    func parse(html: String, school: SchoolConfig?) -> Outcome {
        var courses: [Course] = []
        var name: String?

        if html.contains("course-head") || html.contains("course-body") {
            courses = CourseHTMLParser.parseSelectionCourses(fromHTML: html)
            name = CourseHTMLParser.selectionTableName(fromHTML: html)
        }
        if courses.isEmpty, html.contains("TABLE_TR_01") || html.contains("TABLE_TR_02") {
            courses = CourseHTMLParser.parseLegacyJWCourses(fromHTML: html)
            name = CourseHTMLParser.courseTableName(fromHTML: html)
        }
        if courses.isEmpty, html.count > Self.minimumHTMLHint {
            // Unknown layout: try both readers before giving up.
            let legacy = CourseHTMLParser.parseLegacyJWCourses(fromHTML: html)
            let selection = CourseHTMLParser.parseSelectionCourses(fromHTML: html)
            courses = legacy.count >= selection.count ? legacy : selection
            name = CourseHTMLParser.courseTableName(fromHTML: html)
                ?? CourseHTMLParser.selectionTableName(fromHTML: html)
        }
        guard !courses.isEmpty else {
            return .failure(.emptyResult("没有在页面中找到课程，可能是页面结构已变化或尚未进入课表页"))
        }
        return .success(ImportedSchedule(
            name: normalizedName(name, school: school),
            courses: courses,
            classTimeList: school?.classTimeList,
            semesterStartMonday: school?.semesterStartMonday
        ))
    }

    /// A payload may arrive URL-encoded (the extractors call
    /// `encodeURIComponent`) or wrapped in quotes by the JavaScript bridge.
    private func decodePayload(_ payload: String) -> String {
        var value = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 2 {
            value = String(value.dropFirst().dropLast())
        }
        if value.contains("%7B") || value.contains("%5B") || value.hasPrefix("%") {
            if let decoded = value.removingPercentEncoding { value = decoded }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first == "{" || first == "["
    }

    private func normalizedName(_ raw: String?, school: SchoolConfig?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty { return value }
        if let school { return school.title }
        return CoursePayloadCodec.defaultTableName()
    }
}
