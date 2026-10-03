import Foundation
import SwiftUI
import WebKit

struct SchoolConfig {
    var serviceSchoolID = "ruc"
    var initialURL = RucLoginFlow.loginURL
    var targetURL = RucLoginFlow.timetableURL
    var postLoginURL: String? = RucLoginFlow.timetableURL
    var preExtractJS = ""
    var delayTime = 0.0
    var extractJS = "EXTRACT_TEST_TIMETABLE"
}

@MainActor
private final class PageState {
    var state: WebImportState = .loaded
    var started = false
    var message = ""
    var url = RucLoginFlow.homeURL
    var progress = 1.0
    var extracted = false
}

/// 只模拟 WebKit 返回值；导航与轮询运行生产的 SchoolWebCoordinator。
@MainActor
private final class TimetableWebView: WKWebView {
    var pageURL = URL(string: RucLoginFlow.homeURL)!
    var ready = false
    var attempts = 0
    override var url: URL? { pageURL }
    override var isLoading: Bool { false }

    override func evaluateJavaScript(_ javaScriptString: String,
        completionHandler: (@MainActor (Any?, Error?) -> Void)? = nil) {
        if javaScriptString.contains("visiblePassword") {
            completionHandler?(["login": false, "ready": ready], nil)
        } else if javaScriptString.contains("router.replace") {
            attempts += 1
            // 第一次切换被首页初始化覆盖；不发送 didFinish/hash 回调。
            if attempts >= 2 { pageURL = URL(string: RucLoginFlow.timetableURL)! }
            completionHandler?(true, nil)
        } else if javaScriptString.contains("EXTRACT_TEST_TIMETABLE") {
            precondition(pageURL.absoluteString == RucLoginFlow.timetableURL)
            completionHandler?("TIMETABLE_PAYLOAD", nil)
        } else {
            completionHandler?("{}", nil)
        }
    }
}

@main
struct RucNavigationChecks {
    @MainActor static func main() async throws {
        let page = PageState()
        let webView = TimetableWebView(frame: .zero)
        let coordinator = SchoolWebCoordinator(school: SchoolConfig(),
            state: Binding(get: { page.state }, set: { page.state = $0 }),
            didStartExtraction: Binding(get: { page.started }, set: { page.started = $0 }),
            statusMessage: Binding(get: { page.message }, set: { page.message = $0 }),
            currentURL: Binding(get: { page.url }, set: { page.url = $0 }),
            progress: Binding(get: { page.progress }, set: { page.progress = $0 }),
            reloadToken: 0, extractToken: 0, onExtract: { result in
                switch result {
                case .success(let payload):
                    precondition(payload == "TIMETABLE_PAYLOAD")
                    page.extracted = true
                    page.state = .finished
                case .failure(let error):
                    precondition((error as? ImportError)?.shouldRetryWhenPageLoads == true)
                }
            })
        coordinator.webView = webView
        coordinator.observe(webView)
        defer { coordinator.stopObserving() }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        precondition(webView.attempts == 0 && !page.extracted)
        webView.ready = true
        // 无导航事件、无 SwiftUI extractToken 重试，首页监测仍能独立恢复并提取。
        for _ in 0..<100 where !page.extracted {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(page.extracted && webView.attempts == 2)
        let attempts = webView.attempts
        webView.pageURL = URL(string: RucLoginFlow.homeURL)!
        try await Task.sleep(nanoseconds: 1_100_000_000)
        precondition(webView.attempts == attempts, "Import completion must stop automatic navigation")
        print("RUC navigation checks passed: delayed homepage, lost route events, overwritten jump, automatic recovery and stop after import")
    }
}
