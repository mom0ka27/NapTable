import Combine
import Foundation

struct ServiceClassPeriod: Codable, Identifiable, Equatable { var id: Int; var name: String; var start: String; var end: String }
struct ServiceTermConfiguration: Codable, Identifiable, Equatable {
    var id: String; var version: Int; var semesterStartMonday: String; var weekCount: Int; var periods: [ServiceClassPeriod]; var timezone: String; var note: String; var updatedAt: String?
    /// 这个学期的调休安排。老服务端没有这个字段，解码成 `nil`。
    var adjustments: [CalendarAdjustment]?
    var classTimes: [ClassTime] { periods.map { ClassTime(start: $0.start, end: $0.end) } }
    var calendarAdjustments: [CalendarAdjustment] { adjustments ?? [] }
}
struct ServiceSchoolConfiguration: Codable, Identifiable, Equatable {
    var id: String; var name: String; var timezone: String; var terms: [ServiceTermConfiguration]; var note: String; var updatedAt: String?
}
struct SharedScheduleEnvelope: Codable { var id: String; var owner: String; var schoolID: String; var schoolName: String; var name: String?; var termID: String; var termVersion: Int; var courses: [[String: AnyCodable]]; var createdAt: String; var updatedAt: String; var writeToken: String? }
struct AnyCodable: Codable {
    let value: Any
    init(from decoder: Decoder) throws { let c = try decoder.singleValueContainer(); if let v = try? c.decode(String.self) { value=v } else if let v = try? c.decode(Int.self) { value=v } else if let v = try? c.decode(Double.self) { value=v } else if let v = try? c.decode(Bool.self) { value=v } else { value=NSNull() } }
    func encode(to encoder: Encoder) throws { var c=encoder.singleValueContainer(); switch value { case let v as String: try c.encode(v); case let v as Int: try c.encode(v); case let v as Double: try c.encode(v); case let v as Bool: try c.encode(v); default: try c.encodeNil() } }
}
enum ScheduleServiceError: LocalizedError { case invalidResponse, server(String), missingBaseURL; var errorDescription: String? { switch self { case .invalidResponse: return "服务返回格式错误"; case .server(let v): return v; case .missingBaseURL: return "未配置 NapTable 服务地址" } } }

@MainActor final class ScheduleSharingService: ObservableObject {
    static let shared = ScheduleSharingService(); @Published private(set) var schools: [ServiceSchoolConfiguration] = []
    @Published private(set) var usingCachedSchools = false
    private let defaults = UserDefaults.standard
    var serverURLString: String { defaults.string(forKey: "naptable.serverURL") ?? "http://127.0.0.1:8787" }
    private var baseURL: URL? { URL(string: serverURLString) }
    /// The most recently created share, kept for the screens that only ever
    /// showed one. `myShares` is the full list.
    var savedShareCode: String? { myShares.last?.code }
    func setServerURL(_ value: String) throws { let normalized=value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")); guard let url=URL(string: normalized), url.scheme != nil, url.host != nil else { throw ScheduleServiceError.missingBaseURL }; defaults.set(normalized, forKey: "naptable.serverURL") }
    func loadSchools() async throws -> [ServiceSchoolConfiguration] {
        let cacheKey = "naptable.schoolsCache." + serverURLString
        usingCachedSchools = false
        do {
            let data = try await request(path: "/v1/schools", method: "GET")
            let result = try JSONDecoder().decode([String: [ServiceSchoolConfiguration]].self, from: data)
            guard let loaded = result["schools"] else { throw ScheduleServiceError.invalidResponse }
            schools = loaded
            defaults.set(data, forKey: cacheKey)
        } catch {
            guard let data = defaults.data(forKey: cacheKey),
                  let result = try? JSONDecoder().decode([String: [ServiceSchoolConfiguration]].self, from: data),
                  let cached = result["schools"] else { throw error }
            schools = cached
            usingCachedSchools = true
        }
        return schools
    }
    func share(courses: [Course], schoolID: String, termID: String, owner: String="我") async throws -> SharedScheduleEnvelope {
        let rows = try courses.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) as! [String:Any] }
        let schoolName = schools.first(where: { $0.id == schoolID })?.name ?? schoolID
        let body:[String:Any] = ["owner":owner,"schoolID":schoolID,"termID":termID,"schoolName":schoolName,"courses":rows]
        let result = try JSONDecoder().decode(SharedScheduleEnvelope.self, from: try await request(path:"/v1/shares",method:"POST",body:body))
        remember(ShareCredential(code: result.id, token: result.writeToken ?? "", label: result.name ?? result.schoolName, updatedAt: result.updatedAt))
        return result
    }
    func lookup(_ code:String) async throws -> ImportedSchedule { try CoursePayloadCodec.decode(data: try await request(path:"/v1/shares/\(code.trimmingCharacters(in:.whitespacesAndNewlines).uppercased())",method:"GET")) }
    func revokeSavedShare() async throws { guard let credential = myShares.last else { throw ScheduleServiceError.server("本机没有可撤销的分享") }; try await revoke(credential) }
    /// Not private: `ScheduleSharing.swift` extends this service with the
    /// share endpoints and needs the same transport.
    func request(path:String,method:String,body:Any?=nil,headers:[String:String]=[:]) async throws -> Data { guard let baseURL, let url=URL(string:path,relativeTo:baseURL) else { throw ScheduleServiceError.missingBaseURL }; var r=URLRequest(url:url); r.httpMethod=method; r.setValue("application/json",forHTTPHeaderField:"Content-Type"); headers.forEach { r.setValue($1,forHTTPHeaderField:$0) }; if let body { r.httpBody=try JSONSerialization.data(withJSONObject:body) }; let (data,response)=try await URLSession.shared.data(for:r); guard let http=response as? HTTPURLResponse else { throw ScheduleServiceError.invalidResponse }; guard (200..<300).contains(http.statusCode) else { let m=(try? JSONSerialization.jsonObject(with:data) as? [String:Any])?["error"] as? String ?? "HTTP \(http.statusCode)"; throw ScheduleServiceError.server(m) }; return data }
}
enum ServiceSchoolCatalog { static let nju=ServiceSchoolConfiguration(id:"nju",name:"南京大学",timezone:"Asia/Shanghai",terms:[],note:"服务端模板，需按校历校准") }
