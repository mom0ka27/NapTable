import Foundation

@main
struct WebImportRetryChecks {
    static func main() {
        let waiting = ImportError.notReady("登录页尚未完成")
        precondition(waiting.shouldRetryWhenPageLoads)
        let errors: [ImportError] = [
            .emptyResult("无法识别周六的上课安排"),
            .malformedPayload("格式有误"), .network("连接失败"), .cancelled,
        ]
        precondition(errors.allSatisfy { !$0.shouldRetryWhenPageLoads })

        let start = Date(timeIntervalSince1970: 1_000)
        var window = WebImportRetryWindow(timeout: 240)
        precondition(window.canRetry(now: start))
        // 两秒一次的连续失败必须保持同一截止时间，不能永远等待。
        for second in stride(from: 2, to: 240, by: 2) {
            precondition(window.canRetry(now: start.addingTimeInterval(Double(second))))
            precondition(window.deadline == start.addingTimeInterval(240))
        }
        precondition(!window.canRetry(now: start.addingTimeInterval(240)))
        precondition(!window.canRetry(now: start.addingTimeInterval(300)))
        // 手动重新解析开启新的等待窗口。
        window.reset()
        precondition(window.canRetry(now: start.addingTimeInterval(300)))
        precondition(window.deadline == start.addingTimeInterval(540))

        let login = "https://cas.ruc.edu.cn/cas/login?service=https%3A%2F%2Fcas.ruc.edu.cn%2Fcas%2Foauth2.0%2FcallbackAuthorize"
        let callback = "https://cas.ruc.edu.cn/cas/oauth2.0/callbackAuthorize"
        let home = "https://jw.ruc.edu.cn/Njw2017/index.html#/"
        let timetable = "https://jw.ruc.edu.cn/Njw2017/index.html#/student/student-course-list/"
        precondition(RucLoginFlow.loginURL == login && RucLoginFlow.homeURL == home && RucLoginFlow.timetableURL == timetable)
        precondition(RucLoginFlow.isPortal(home) && !RucLoginFlow.isTimetable(home))
        precondition(RucLoginFlow.isTimetable(timetable))
        precondition(RucLoginFlow.isTimetable(String(timetable.dropLast())))
        precondition(RucLoginFlow.isTimetable(timetable + "?tab=all"))
        precondition(!RucLoginFlow.isTimetable(timetable + "other"))
        precondition(!RucLoginFlow.isPortal("https://jw.ruc.edu.cn.example.com/Njw2017/index.html#/"))
        precondition(!RucLoginFlow.isPortal(home.replacingOccurrences(of: "https:", with: "http:")))

        var flow = RucLoginFlow()
        // 登录页始终交给用户，密码/短信登录都不能被 App 的跳转打断。
        precondition(flow.destination(after: login, isLoginPage: true, portalReady: false) == nil)
        precondition(flow.destination(after: login, isLoginPage: false, portalReady: false) == nil)
        precondition(flow.destination(after: callback + "?error=access_denied", isLoginPage: false, portalReady: false) == nil)
        precondition(flow.destination(after: callback, isLoginPage: false, portalReady: false)?.absoluteString == home)
        precondition(flow.destination(after: callback, isLoginPage: false, portalReady: false) == nil)
        // 等到教务初始化完成，随后只跳转一次课表；重复 didFinish/hash 事件不会重载。
        precondition(flow.destination(after: home, isLoginPage: false, portalReady: false) == nil)
        precondition(flow.destination(after: home, isLoginPage: false, portalReady: true)?.absoluteString == timetable)
        precondition(flow.destination(after: home, isLoginPage: false, portalReady: true) == nil)
        precondition(flow.destination(after: timetable, isLoginPage: false, portalReady: true) == nil)

        // 学校已自动跳到教务首页或用户已打开课表时，省掉已有的跳转。
        var naturalRedirect = RucLoginFlow()
        precondition(naturalRedirect.destination(after: home, isLoginPage: false, portalReady: true)?.absoluteString == timetable)
        precondition(naturalRedirect.destination(after: callback, isLoginPage: false, portalReady: false) == nil)
        var directTimetable = RucLoginFlow()
        precondition(directTimetable.destination(after: timetable, isLoginPage: false, portalReady: true) == nil)
        precondition(directTimetable.destination(after: home, isLoginPage: false, portalReady: true) == nil)
        // 请求课表后被网页自己的初始化切回首页，间隔后必须能够再次跳转。
        var bounced = RucLoginFlow()
        precondition(bounced.destination(after: home, isLoginPage: false, portalReady: true,
            now: start)?.absoluteString == timetable)
        precondition(bounced.destination(after: home, isLoginPage: false, portalReady: true,
            now: start.addingTimeInterval(1)) == nil)
        precondition(bounced.destination(after: home, isLoginPage: false, portalReady: true,
            now: start.addingTimeInterval(4))?.absoluteString == timetable)
        precondition(bounced.destination(after: timetable, isLoginPage: false, portalReady: true,
            now: start.addingTimeInterval(5)) == nil)
        precondition(bounced.destination(after: home, isLoginPage: false, portalReady: true,
            now: start.addingTimeInterval(6)) == nil)
        precondition(bounced.destination(after: home, isLoginPage: false, portalReady: true,
            now: start.addingTimeInterval(9))?.absoluteString == timetable)
        // 首页没有继续产生导航事件，稍后才完成初始化，轮询仍能推进跳转。
        var delayedHome = RucLoginFlow()
        for second in 0..<10 {
            precondition(delayedHome.destination(after: home, isLoginPage: false, portalReady: false,
                now: start.addingTimeInterval(Double(second))) == nil)
        }
        precondition(delayedHome.destination(after: home, isLoginPage: false, portalReady: true,
            now: start.addingTimeInterval(10))?.absoluteString == timetable)
        print("Web import login and retry checks passed")
    }
}
