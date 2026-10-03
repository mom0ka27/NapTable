import Foundation

/// 本科入口先完成 CAS，再等教务首页初始化，最后进入完整课表。
nonisolated struct RucLoginFlow {
    static let loginURL = "https://cas.ruc.edu.cn/cas/login?service=https%3A%2F%2Fcas.ruc.edu.cn%2Fcas%2Foauth2.0%2FcallbackAuthorize"
    static let homeURL = "https://jw.ruc.edu.cn/Njw2017/index.html#/"
    static let timetableURL = "https://jw.ruc.edu.cn/Njw2017/index.html#/student/student-course-list/"

    private var requestedHome = false
    private var lastTimetableAttempt: Date?
    private static let retryInterval: TimeInterval = 3

    static func isPortal(_ value: String) -> Bool {
        guard let url = URLComponents(string: value) else { return false }
        return url.scheme == "https" && url.host?.lowercased() == "jw.ruc.edu.cn"
            && url.path.lowercased() == "/njw2017/index.html"
    }

    static func isTimetable(_ value: String) -> Bool {
        guard isPortal(value), let url = URLComponents(string: value) else { return false }
        let route = (url.fragment ?? "").split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        return route.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "student/student-course-list"
    }

    /// CAS 的服务器重定向优先；回调已经停留时才补上教务首页这一跳。
    /// 首页初始化可能覆盖 App 发出的 hash 跳转；未导入前允许间隔重试。
    mutating func destination(after value: String, isLoginPage: Bool, portalReady: Bool, now: Date = Date()) -> URL? {
        guard !isLoginPage, let url = URLComponents(string: value), url.scheme == "https" else { return nil }
        if url.host?.lowercased() == "cas.ruc.edu.cn",
           url.path.lowercased() == "/cas/oauth2.0/callbackauthorize",
           !requestedHome,
           !(url.queryItems ?? []).contains(where: { $0.name == "error" }) {
            requestedHome = true
            return URL(string: Self.homeURL)
        }
        guard Self.isPortal(value) else { return nil }
        if Self.isTimetable(value) {
            if portalReady {
                requestedHome = true
                lastTimetableAttempt = now
            }
            return nil
        }
        guard portalReady else { return nil }
        if let lastTimetableAttempt, now.timeIntervalSince(lastTimetableAttempt) < Self.retryInterval { return nil }
        requestedHome = true
        lastTimetableAttempt = now
        return URL(string: Self.timetableURL)
    }
}
