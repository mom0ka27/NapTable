import CryptoKit
import Combine
import Foundation

struct ServiceClassPeriod: Codable, Identifiable, Equatable { var id: Int; var name: String; var start: String; var end: String }
struct ServiceTermConfiguration: Codable, Identifiable, Equatable {
    var id: String; var version: Int; var semesterStartMonday: String; var weekCount: Int; var periods: [ServiceClassPeriod]; var timezone: String; var note: String; var updatedAt: String?
    var current: Bool? = nil
    /// 这个学期的调休安排。老服务端没有这个字段，解码成 `nil`。
    var adjustments: [CalendarAdjustment]?
    var classTimes: [ClassTime] { periods.map { ClassTime(start: $0.start, end: $0.end) } }
    var calendarAdjustments: [CalendarAdjustment] { adjustments ?? [] }
}
struct ServiceSchoolConfiguration: Codable, Identifiable, Equatable {
    var id: String; var name: String; var timezone: String; var terms: [ServiceTermConfiguration]; var note: String; var updatedAt: String?
    var periods: [ServiceClassPeriod]? = nil
    var currentTermID: String? = nil
    var currentTerm: ServiceTermConfiguration? {
        if let currentTermID, let term = terms.first(where: { $0.id == currentTermID }) { return term }
        return terms.first(where: { $0.current == true })
    }
}
struct SharedScheduleEnvelope: Codable { var id: String; var owner: String; var schoolID: String; var schoolName: String; var name: String?; var termID: String; var termVersion: Int; var courses: [[String: AnyCodable]]; var createdAt: String; var updatedAt: String; var writeToken: String? }
struct AnyCodable: Codable {
    let value: Any
    init(from decoder: Decoder) throws { let c = try decoder.singleValueContainer(); if let v = try? c.decode(String.self) { value=v } else if let v = try? c.decode(Int.self) { value=v } else if let v = try? c.decode(Double.self) { value=v } else if let v = try? c.decode(Bool.self) { value=v } else { value=NSNull() } }
    func encode(to encoder: Encoder) throws { var c=encoder.singleValueContainer(); switch value { case let v as String: try c.encode(v); case let v as Int: try c.encode(v); case let v as Double: try c.encode(v); case let v as Bool: try c.encode(v); default: try c.encodeNil() } }
}
enum ScheduleServiceError: LocalizedError { case invalidResponse, server(String), missingBaseURL; var errorDescription: String? { switch self { case .invalidResponse: return "服务返回格式错误"; case .server(let v): return v; case .missingBaseURL: return "未配置 NapTable 服务地址" } } }

private func napTableSupportedSchools(_ schools: [ServiceSchoolConfiguration]) -> [ServiceSchoolConfiguration] {
    // Only Nanjing University is currently visible in the client.
    schools.filter { $0.id.caseInsensitiveCompare("nju") == .orderedSame }
}

@MainActor final class ScheduleSharingService: ObservableObject {
    static let shared = ScheduleSharingService(); @Published private(set) var schools: [ServiceSchoolConfiguration] = []
    @Published private(set) var usingCachedSchools = false
    private var generatingShare = false
    private let defaults = UserDefaults.standard
    /// The production service. Device credentials and schedule data only ever
    /// travel over HTTPS to this host, so the address is fixed in the app
    /// instead of being configurable.
    let serverURLString = "https://naptable.mom0ka27.top"
    var validatedBaseURL: URL? { URL(string: serverURLString) }
    /// The most recently created share, kept for the screens that only ever
    /// showed one. `myShares` is the full list.
    var savedShareCode: String? { myShares.last?.code }
    func loadSchools() async throws -> [ServiceSchoolConfiguration] {
        let cacheKey = "naptable.schoolsCache." + serverURLString
        usingCachedSchools = false
        do {
            let data = try await request(path: "/v1/schools", method: "GET")
            let result = try JSONDecoder().decode([String: [ServiceSchoolConfiguration]].self, from: data)
            guard let loaded = result["schools"] else { throw ScheduleServiceError.invalidResponse }
            schools = napTableSupportedSchools(loaded)
            defaults.set(data, forKey: cacheKey)
        } catch {
            guard let data = defaults.data(forKey: cacheKey),
                  let result = try? JSONDecoder().decode([String: [ServiceSchoolConfiguration]].self, from: data),
                  let cached = result["schools"] else { throw error }
            schools = napTableSupportedSchools(cached)
            usingCachedSchools = true
        }
        return schools
    }
    func refreshCurrentTerms(in store: AppStore) async {
        guard let schools = try? await loadSchools() else { return }
        store.refreshServiceConfiguration(schools)
    }
    func shareFingerprint(courses: [Course], table: CourseTable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rows = try courses.map { course -> String in
            var value = course
            value.id = 0; value.tableId = 0; value.courseKey = nil
            value.weeks = Array(Set(value.weeks)).sorted()
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }.sorted()
        // Include the actual calendar, not version counters or update timestamps.
        let calendar: [String: Any] = ["school": table.schoolID ?? "", "term": table.termID ?? "",
            "start": table.semesterStartMonday, "weeks": table.termWeekCount ?? 0,
            "timezone": table.termTimezone ?? "",
            "periods": try JSONSerialization.jsonObject(with: encoder.encode(table.effectiveClassTimeList)),
            "adjustments": try JSONSerialization.jsonObject(with: encoder.encode(table.calendarAdjustments ?? [])),
            "courses": rows]
        let data = try JSONSerialization.data(withJSONObject: calendar, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func canShare(courses: [Course], table: CourseTable) -> Bool {
        guard table.schoolID != nil, table.termID != nil,
              let fingerprint = try? shareFingerprint(courses: courses, table: table) else { return false }
        return myShares.last(where: { $0.tableID == table.id })?.fingerprint != fingerprint
    }

    func share(courses: [Course], table: CourseTable, owner: String = "我") async throws -> SharedScheduleEnvelope {
        guard !generatingShare else { throw ScheduleServiceError.server("正在生成分享码，请稍候") }
        generatingShare = true
        defer { generatingShare = false }
        guard let schoolID = table.schoolID, let termID = table.termID,
              schoolID.caseInsensitiveCompare("cpu") != .orderedSame else {
            throw ScheduleServiceError.server("请先从对应学校导入课表")
        }
        let fingerprint = try shareFingerprint(courses: courses, table: table)
        var obsolete = myShares.filter { $0.tableID == table.id }
        var previous = obsolete.last
        // Older builds did not retain the local table association. Recover it
        // from the uploaded rows without mixing two tables from the same school.
        if previous == nil {
            for credential in myShares.reversed() where credential.tableID == nil {
                let data: Data
                do { data = try await request(path: "/v1/shares/\(credential.code)", method: "GET") }
                catch ScheduleServiceError.server(let reason) where reason == "share not found" { continue }
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      value["schoolID"] as? String == schoolID, value["termID"] as? String == termID,
                      let rows = value["courses"] as? [[String: Any]],
                      !rows.isEmpty, rows.allSatisfy({ $0["tableId"] as? Int == table.id }) else { continue }
                obsolete.append(credential)
                if previous == nil { previous = credential }
            }
        }
        guard previous?.fingerprint != fingerprint else {
            throw ScheduleServiceError.server("课表没有变更，请继续使用现有分享码")
        }
        let rows = try courses.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        let body: [String: Any] = ["owner": owner, "schoolID": schoolID, "termID": termID, "courses": rows,
            "previousShares": obsolete.filter { $0.code != previous?.code }.map { ["code": $0.code, "token": $0.token] }]
        let path = previous.map { "/v1/shares/\($0.code)/replace" } ?? "/v1/shares"
        let headers = previous.map { ["X-Write-Token": $0.token] } ?? [:]
        let data: Data
        do { data = try await request(path: path, method: "POST", body: body, headers: headers) }
        catch ScheduleServiceError.server(let reason) where reason == "课表没有变更，请继续使用现有分享码" {
            // Bind legacy credentials after the server verifies equality too.
            for var credential in obsolete {
                credential.tableID = table.id
                credential.fingerprint = fingerprint
                remember(credential)
            }
            throw ScheduleServiceError.server(reason)
        }
        let result = try JSONDecoder().decode(SharedScheduleEnvelope.self, from: data)
        guard let token = result.writeToken, !token.isEmpty else { throw ScheduleServiceError.invalidResponse }
        replaceRemembered(obsolete, with: ShareCredential(code: result.id, token: token,
            label: table.name, updatedAt: result.updatedAt, tableID: table.id, fingerprint: fingerprint))
        return result
    }
    func lookup(_ code:String) async throws -> ImportedSchedule { try CoursePayloadCodec.decode(data: try await request(path:"/v1/shares/\(code.trimmingCharacters(in:.whitespacesAndNewlines).uppercased())",method:"GET")) }
    func revokeSavedShare() async throws { guard let credential = myShares.last else { throw ScheduleServiceError.server("本机没有可撤销的分享") }; try await revoke(credential) }
    /// Not private: `ScheduleSharing.swift` extends this service with the
    /// share endpoints and needs the same transport.
    func request(path:String,method:String,body:Any?=nil,headers:[String:String]=[:]) async throws -> Data { guard let baseURL=validatedBaseURL, let url=URL(string:path,relativeTo:baseURL) else { throw ScheduleServiceError.missingBaseURL }; var r=URLRequest(url:url); r.httpMethod=method; r.setValue("application/json",forHTTPHeaderField:"Content-Type"); headers.forEach { r.setValue($1,forHTTPHeaderField:$0) }; if let body { r.httpBody=try JSONSerialization.data(withJSONObject:body) }; let (data,response)=try await URLSession.shared.data(for:r); guard let http=response as? HTTPURLResponse else { throw ScheduleServiceError.invalidResponse }; guard (200..<300).contains(http.statusCode) else { let m=(try? JSONSerialization.jsonObject(with:data) as? [String:Any])?["error"] as? String ?? "HTTP \(http.statusCode)"; throw ScheduleServiceError.server(m) }; return data }
}
enum ServiceSchoolCatalog { static let nju=ServiceSchoolConfiguration(id:"nju",name:"南京大学",timezone:"Asia/Shanghai",terms:[],note:"服务端模板，需按校历校准") }
