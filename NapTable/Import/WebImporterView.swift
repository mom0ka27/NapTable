import SwiftUI
import WebKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The configuration-driven importer.
///
/// Port of `ImportFromBEView`: load the school's login page in a `WKWebView`, let
/// the user sign in there, wait for the configured target URL, run the school's
/// `preExtractJS`, then run its `extractJS` and hand the returned payload to
/// `ImportPipeline`. Credentials never pass through the app.
struct WebImporterView: View {
    let school: SchoolConfig
    let requiresCourses: Bool
    /// Called with the parsed schedule and the chosen destination once the user
    /// confirms.
    let onFinish: (ImportedSchedule, AppStore.ImportMode) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var state: WebImportState = .loading
    @State private var didStartExtraction = false
    @State private var statusMessage = "正在打开登录页面…"
    @State private var progress = 0.0
    @State private var parsed: ImportedSchedule?
    /// Bumped to ask the web view to load the entry page again.
    @State private var reloadToken = 0
    /// Bumped to ask the web view to run its extractor again.
    @State private var extractToken = 0
    @State private var mode: AppStore.ImportMode
    /// 确认页上可以改的课表名称，每次解析成功后重置成默认名。
    @State private var tableName = ""
    /// 避开同名课表后的默认名，名称留空时用它。
    @State private var defaultName = ""
    /// 撞车的时段选了哪一节：组 id -> `parsed.courses` 下标。每次重新解析清空。
    @State private var conflictChoice: [Int: Int] = [:]
    /// 只有部分周次重叠的那几节怎么处理：`parsed.courses` 下标 -> 处理方式。
    @State private var conflictDispositions: [Int: ImportConflictDisposition] = [:]
    /// 页面上的学期和当前学期对不上时，点「导入」先问一次。
    @State private var confirmingTermMismatch = false

    /// `initialMode` is the destination chosen on the import hub. Without it the
    /// sheet always started on `.replaceCurrent`, which made the hub's
    /// 「导入方式」picker a dead control: whatever the user chose there, the
    /// confirmation screen showed — and imported with — "覆盖当前课表".
    init(
        school: SchoolConfig,
        initialMode: AppStore.ImportMode = .replaceCurrent,
        requiresCourses: Bool = false,
        onFinish: @escaping (ImportedSchedule, AppStore.ImportMode) -> Void
    ) {
        self.school = school
        self.requiresCourses = requiresCourses
        self.onFinish = onFinish
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // 网页一直留在视图树里，确认页只是盖在上面。移出去会销毁 WKWebView，
                // 点「返回」时新建的网页又从登录页开始，登录状态和课表页都丢了。
                browser
                    .opacity(parsed == nil ? 1 : 0)
                    .allowsHitTesting(parsed == nil)
                    .accessibilityHidden(parsed != nil)
                if let parsed {
                    ImportedScheduleForm(
                        schedule: parsed, mode: $mode, tableName: $tableName,
                        defaultName: defaultName, nameTaken: nameTaken,
                        conflicts: conflicts, conflictChoice: $conflictChoice,
                        conflictDispositions: $conflictDispositions
                    )
                }
            }
            .task(id: school.id) {
                // Start fetching as soon as the import route is selected.
                // The pipeline validates the matching term before confirmation.
                _ = try? await ScheduleSharingService.shared.loadSchools()
            }
            .safeAreaInset(edge: .bottom) {
                if requiresCourses && parsed?.courses.isEmpty == true {
                    Text("未读取到课程，请返回并确认学期或更换导入入口。首次使用需导入有课程的课表。")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding().frame(maxWidth: .infinity).background(.regularMaterial)
                } else if let mismatch = parsed?.termMismatch {
                    Label("\(mismatch)。如果这不是本学期的课表，请返回，在教务系统里切换到本学期后重新解析。",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                        .padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
                }
            }
            .navigationTitle(parsed == nil ? school.pageTitle : "确认导入")
            .appInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(parsed == nil ? "取消" : "返回") {
                        if parsed == nil { dismiss() } else { backToPage() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let parsed {
                        Button("导入") {
                            if parsed.termMismatch != nil { confirmingTermMismatch = true; return }
                            onFinish(resolved(parsed), mode)
                            dismiss()
                        }
                        // 冲突没选完就导入，等于替用户随便留一节，所以先拦住。
                        .disabled((requiresCourses && parsed.courses.isEmpty) || hasUnresolvedConflicts || nameTaken)
                        // 挂在「导入」按钮上：iOS 26 起确认框从触发它的视图旁边弹出。
                        .confirmationDialog(
                            "学期和当前学期不一致",
                            isPresented: $confirmingTermMismatch,
                            titleVisibility: .visible
                        ) {
                            Button("仍然导入") {
                                onFinish(resolved(parsed), mode)
                                dismiss()
                            }
                            Button("返回切换学期") { backToPage() }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("\(parsed.termMismatch ?? "")。仍然导入的话，这些课会按当前学期的开学日期和作息排列。")
                        }
                    } else {
                        Button("重新解析") { retry() }
                            .disabled(state == .importing)
                    }
                }
            }
        }
    }

    private var effectiveName: String {
        let name = tableName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? defaultName : name
    }

    /// 只有新建课表才用这个名字；覆盖和追加都沿用当前课表的名字。
    private var nameTaken: Bool {
        mode == .newTable && store.isTableNameTaken(effectiveName)
    }

    /// 同一时段撞在一起的课。下标指向 `parsed.courses`，所以每次重新解析都要
    /// 连同 `conflictChoice` 一起作废。
    /// 选定一节之后，组里和它不相交的成员会重新分成后续的组接着问。
    private var conflicts: [ImportConflictGroup] {
        ImportConflictFinder.expandedGroups(in: parsed?.courses ?? [], keeping: conflictChoice)
    }

    /// 还没选保留哪一节，或者部分重叠的那几节还没说怎么处理。
    private var hasUnresolvedConflicts: Bool {
        ImportConflictFinder.hasUnresolvedConflicts(
            in: parsed?.courses ?? [], keeping: conflictChoice, dispositions: conflictDispositions
        )
    }

    /// 写库之前把没选中的那几节收起来。
    /// 从确认页回到网页。页面还停在课表页上：回到「已加载」让「重新解析」直接重新读取；
    /// `didStartExtraction` 保持为真，免得页面一有动静就又自动提取。
    private func backToPage() {
        parsed = nil
        conflictChoice = [:]
        conflictDispositions = [:]
        state = .loaded
        statusMessage = "已返回课表页面。需要重新读取时点右上角「重新解析」。"
    }

    private func resolved(_ schedule: ImportedSchedule) -> ImportedSchedule {
        var value = schedule
        value.name = effectiveName
        value.courses = ImportConflictFinder.apply(
            keeping: conflictChoice, dispositions: conflictDispositions,
            to: schedule.courses, groups: conflicts
        )
        return value
    }

    private var browser: some View {
        Group {
            VStack(spacing: 0) {
                if let banner = school.bannerContent, !banner.isEmpty {
                    bannerView(banner)
                }
                statusBar
                ZStack {
                    SchoolWebView(
                        school: school,
                        state: $state,
                        didStartExtraction: $didStartExtraction,
                        statusMessage: $statusMessage,
                        progress: $progress,
                        reloadToken: reloadToken,
                        extractToken: extractToken,
                        onExtract: handleExtraction
                    )
                    if state == .importing {
                        Color.black.opacity(0.18).ignoresSafeArea()
                        ProgressView("正在读取课程与学校配置…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if state == .importing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: state.isFailure ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(state.isFailure ? .orange : .secondary)
            }
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if progress > 0, progress < 1 {
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.appSecondaryGroupedBackground)
    }

    /// Re-runs extraction. A page that never finished loading cannot be
    /// extracted from, so it is reloaded from the school's entry point instead
    /// of leaving the user with a dead button. An *extraction* failure keeps the
    /// page the user navigated to: reloading the entry page there would throw
    /// them back to the login screen.
    private func retry() {
        didStartExtraction = false
        if state == .loaded || state == .finished || state == .failed {
            state = .loaded
            statusMessage = "正在重新读取…"
            extractToken += 1
        } else {
            // The page never loaded; start over from the school's entry point.
            statusMessage = "页面未加载完成，正在重新打开…"
            state = .loading
            reloadToken += 1
        }
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        #endif
    }

    private func bannerView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let urlString = school.bannerURL, let url = URL(string: urlString), let action = school.bannerAction {
                Link(action, destination: url)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    private func handleExtraction(_ result: Result<String, Error>) {
        switch result {
        case .success(let payload):
            state = .importing
            statusMessage = "正在解析课表并匹配学校学期…"
            ImportPipeline.shared.ingest(payload: payload, school: school) { outcome in
                switch outcome {
                case .success(let schedule):
                    state = .finished
                    statusMessage = "已解析 \(schedule.courses.count) 条课程安排"
                    conflictChoice = [:]
                    conflictDispositions = [:]
                    parsed = schedule
                    defaultName = store.uniqueTableName(schedule.name)
                    tableName = defaultName
                case .failure(let error):
                    state = .failed
                    statusMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            state = .failed
            statusMessage = error.localizedDescription
        }
    }
}

nonisolated enum WebImportState: Equatable {
    case loading
    case loaded
    case importing
    /// 页面已经加载过，但读取或解析课表失败。重试时在当前页面上重新提取。
    case failed
    /// 页面本身没能打开。重试时从学校的入口页重新加载。
    case loadFailed
    case finished

    var isFailure: Bool { self == .failed || self == .loadFailed }
}

/// Owns the navigation script. Shared by both platform wrappers so the two
/// `#if` branches only carry the representable boilerplate.
@MainActor
final class SchoolWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let school: SchoolConfig
    let state: Binding<WebImportState>
    let didStartExtraction: Binding<Bool>
    let statusMessage: Binding<String>
    let progress: Binding<Double>
    let onExtract: (Result<String, Error>) -> Void

    weak var webView: WKWebView?
    #if DEBUG
    static weak var lastWebView: WKWebView?
    #endif
    private var observation: NSKeyValueObservation?
    private var isExtracting = false
    private var lastPageFacts: String?
    /// 最近几次主框架跳转经过的地址（去掉查询参数，ticket 不外露），跳转失败时附在提示里。
    private var redirectTrail: [String] = []
    /// 遇到重定向循环时只自动清一次登录记录，避免清了还循环时无限重试。
    private var clearedLoopCookies = false
    /// 从创建时传入的值开始：coordinator 重建时（比如视图被重新创建）如果从 0
    /// 开始，第一次 `update` 就会误以为有新的重载 / 提取请求。
    private var lastReloadToken: Int
    private var lastExtractToken: Int

    init(
        school: SchoolConfig,
        state: Binding<WebImportState>,
        didStartExtraction: Binding<Bool>,
        statusMessage: Binding<String>,
        progress: Binding<Double>,
        reloadToken: Int,
        extractToken: Int,
        onExtract: @escaping (Result<String, Error>) -> Void
    ) {
        self.school = school
        self.state = state
        self.didStartExtraction = didStartExtraction
        self.statusMessage = statusMessage
        self.progress = progress
        self.lastReloadToken = reloadToken
        self.lastExtractToken = extractToken
        self.onExtract = onExtract
    }

    /// Applies the screen's reload / re-extract requests.
    func update(tokens: (reload: Int, extract: Int), webView: WKWebView) {
        if tokens.reload != lastReloadToken {
            lastReloadToken = tokens.reload
            didStartExtraction.wrappedValue = false
            clearedLoopCookies = false
            redirectTrail = []
            if let url = URL(string: school.initialURL) {
                webView.load(URLRequest(url: url))
            }
        }
        if tokens.extract != lastExtractToken {
            lastExtractToken = tokens.extract
            isExtracting = false
            startExtraction()
        }
    }

    static func makeWebView(coordinator: SchoolWebCoordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let controller = WKUserContentController()
        controller.add(coordinator, name: "SnackbarJSChannel")
        controller.add(coordinator, name: "NapTableBridge")
        if coordinator.school.serviceSchoolID == "sysu" {
            controller.add(coordinator, name: "NapTableRoute")
            controller.addUserScript(WKUserScript(source: """
            (() => {
              const report = () => window.webkit.messageHandlers.NapTableRoute.postMessage(location.href);
              for (const method of ['pushState', 'replaceState']) {
                const original = history[method];
                history[method] = function(...args) {
                  const result = original.apply(this, args);
                  report();
                  return result;
                };
              }
              addEventListener('popstate', report);
              addEventListener('hashchange', report);
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.userContentController = controller
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        // 页面用 window.open / target=_blank 打开课表时，没有 uiDelegate 就什么都不发生。
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = true
        // Some 教务 pages only render the mobile layout for a phone UA.
        webView.customUserAgent = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        coordinator.webView = webView
        #if DEBUG
        SchoolWebCoordinator.lastWebView = webView
        #endif
        coordinator.observe(webView)
        if let url = URL(string: coordinator.school.initialURL) {
            webView.load(URLRequest(url: url))
        } else {
            coordinator.statusMessage.wrappedValue = "学校配置的登录地址无效"
            coordinator.state.wrappedValue = .loadFailed
        }
        return webView
    }

    func observe(_ webView: WKWebView) {
        observation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                self?.progress.wrappedValue = webView.estimatedProgress
            }
        }
    }

    func stopObserving() {
        observation?.invalidate()
        observation = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "SnackbarJSChannel")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "NapTableBridge")
        if school.serviceSchoolID == "sysu" {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "NapTableRoute")
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? ""
        guard state.wrappedValue != .importing, state.wrappedValue != .finished else { return }
        state.wrappedValue = .loaded
        checkTarget(url)
    }

    private func checkTarget(_ url: String) {
        guard state.wrappedValue != .importing, state.wrappedValue != .finished,
              !didStartExtraction.wrappedValue else { return }
        if matches(url, pattern: school.targetURL) {
            didStartExtraction.wrappedValue = true
            // `startExtraction` owns the `delayTime` wait so that `preExtractJS`
            // runs as soon as the target page is reached, like the Flutter app.
            startExtraction()
        } else if !school.redirectURL.isEmpty, url.hasPrefix(school.redirectURL) {
            statusMessage.wrappedValue = "已登录，正在打开课表页面…"
        } else {
            let path = URL(string: url)?.path ?? url
            statusMessage.wrappedValue = "当前页面：\(path)\n"
                + "请在这个页面里登录，并手动进入「我的课表」；到达课表页面后会自动读取。"
                + "如果已经能看到课表但仍没反应，点右上角「重新解析」。"
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        statusMessage.wrappedValue = "页面加载失败：\(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        recordHop(webView.url)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        recordHop(webView.url)
    }

    private func recordHop(_ url: URL?) {
        guard let url, let host = url.host else { return }
        let hop = "\(url.scheme ?? "")://\(host)\(url.path)"
        if redirectTrail.last != hop { redirectTrail.append(hop) }
        if redirectTrail.count > 6 { redirectTrail.removeFirst(redirectTrail.count - 6) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // 统一认证的登录 Cookie 还在、业务系统却不认它的 ticket 时，两边会来回 302
        // 直到 WebKit 放弃。清掉这所学校的网页数据、从入口页重来一次。
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorHTTPTooManyRedirects, !clearedLoopCookies {
            clearedLoopCookies = true
            statusMessage.wrappedValue = "登录跳转出现循环，正在清除学校网站的登录记录后重试…"
            clearSchoolWebsiteData { [weak self, weak webView] in
                guard let self, let webView, let url = URL(string: self.school.initialURL) else { return }
                self.redirectTrail = []
                self.state.wrappedValue = .loading
                webView.load(URLRequest(url: url))
            }
            return
        }
        var message = "无法打开页面：\(error.localizedDescription)"
        if nsError.code == NSURLErrorHTTPTooManyRedirects, !redirectTrail.isEmpty {
            message += "\n已清除过学校网站的登录记录仍然循环，请把以下跳转地址反馈给我们：\n"
                + redirectTrail.joined(separator: "\n")
        }
        // 已经打开过的页面上某次跳转失败，页面本身还在，别让重试把人带回入口页。
        guard webView.url == nil || state.wrappedValue == .loading else {
            statusMessage.wrappedValue = message
            return
        }
        state.wrappedValue = .loadFailed
        statusMessage.wrappedValue = message
    }

    /// 只清这所学校域名下的网页数据（Cookie、缓存等），别的学校的登录状态不动。
    private func clearSchoolWebsiteData(then completion: @escaping @MainActor () -> Void) {
        let domains = Set([school.initialURL, school.targetURL].compactMap(Self.host(of:)).map(Self.siteDomain(of:)))
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let matching = records.filter { record in
                domains.contains { record.displayName == $0 || record.displayName.hasSuffix("." + $0) }
            }
            store.removeData(ofTypes: types, for: matching) {
                Task { @MainActor in completion() }
            }
        }
    }

    /// `jwxt.njfu.edu.cn` -> `njfu.edu.cn`，`xk.nju.edu.cn` -> `nju.edu.cn`。
    static func siteDomain(of host: String) -> String {
        let labels = host.split(separator: ".")
        let keep = host.hasSuffix(".edu.cn") || host.hasSuffix(".ac.cn") || host.hasSuffix(".com.cn") ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    // MARK: WKUIDelegate

    /// 教务页面常用 window.open / target=_blank 打开课表。App 里只有一个网页，
    /// 所以在当前网页里打开，而不是另起一个窗口。
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == false {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // 页面里的第三方 iframe 也能调到 messageHandlers，只听主框架的。
        guard message.frameInfo.isMainFrame else { return }
        if message.name == "NapTableRoute", let url = message.body as? String {
            if state.wrappedValue == .loaded { checkTarget(url) }
            return
        }
        if let text = message.body as? String {
            statusMessage.wrappedValue = text
        }
    }

    /// What the page looks like right now, appended to a failure so the user can
    /// report something concrete.
    private var pageSuffix: String {
        guard let facts = lastPageFacts else { return "" }
        return "\n页面：" + facts
    }

    /// Reads a compact description of the current document. The URL comes from
    /// the web view itself, so this still says something useful when the page
    /// script cannot run at all (about:blank, a failed load, a TLS error page).
    private func pageFacts(of webView: WKWebView) async -> String {
        let url = webView.url?.absoluteString ?? "nil"
        let script = """
        (() => {
          const body = document.body;
          const tr = document.querySelector('table tbody tr');
          const cells = tr ? Array.from(tr.querySelectorAll('td')).map(td => td.textContent.trim().slice(0, 12)) : null;
          return JSON.stringify({
            title: document.title,
            ready: document.readyState,
            bodyLength: body ? body.innerHTML.length : -1,
            tables: document.querySelectorAll('table').length,
            rows: document.querySelectorAll('table tbody tr').length,
            term: (document.querySelector('#dqxnxqkclb') || {}).textContent || null,
            courseHead: document.getElementsByClassName('course-head').length,
            cells: cells,
          });
        })();
        """
        // Evaluated as a plain script (not through `callAsyncJavaScript`) so the
        // IIFE's value is the script's completion value and actually comes back.
        if let value = try? await webView.evaluateJavaScript(script),
           let json = value as? String {
            return "url=\(url) \(json)"
        }
        return "url=\(url) 页面脚本无法执行（可能还没开始加载或已失败）"
    }

    /// `targetUrl` may contain the shell's `*default` wildcard, in which case only
    /// the stable prefix can be matched.
    private func matches(_ url: String, pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        if school.serviceSchoolID == "sysu",
           let page = URLComponents(string: url), let target = URLComponents(string: pattern) {
            let path = page.path.replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
            return page.scheme == target.scheme && page.host == target.host && path == target.path
        }
        if let star = pattern.firstIndex(of: "*") {
            return url.hasPrefix(String(pattern[pattern.startIndex..<star]))
        }
        // A single-page portal keeps its route in the hash, so compare the part
        // before the hash and then require the hash to line up when both have one.
        let targetHash = pattern.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init)
        let urlHash = url.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init)
        let targetPath = pattern.split(separator: "#", maxSplits: 1).first.map(String.init) ?? pattern
        let urlPath = url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? url
        guard urlPath.hasPrefix(targetPath) || url.hasPrefix(targetPath) else { return false }
        if let targetHash, let urlHash { return urlHash.hasPrefix(targetHash) }
        return true
    }

    // MARK: Extraction

    /// Runs the school's optional `preExtractJS`, waits `delayTime`, then reads
    /// the payload.
    ///
    /// This mirrors `ImportFromBEView.import` in the Flutter app, which runs the
    /// pre-script first and only then delays: several schools use it to click a
    /// tab that loads the real table, so extracting in the same tick would read
    /// a table that is not there yet.
    private func startExtraction() {
        // 学校脚本只该在教务系统自己的页面上跑。停在登录页或别的站点时直接提示，
        // 不把脚本（和它读到的内容）交给别人的页面。中大的脚本自己检查来源。
        if school.serviceSchoolID != "sysu", let problem = hostMismatch() {
            isExtracting = false
            onExtract(.failure(ImportError.notReady(problem)))
            return
        }
        let pre = school.preExtractJS
        let delay = max(0, school.delayTime)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !pre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let webView = self.webView {
                // A failing pre-script is deliberately not fatal: Flutter runs it
                // as a separate, fire-and-forget script, so a missing button must
                // not stop the extractor from running.
                _ = try? await webView.evaluateJavaScript(pre)
            }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            self.runExtraction()
        }
    }

    /// 当前页面和学校课表页不在同一个 host 时返回给用户看的说明。
    private func hostMismatch() -> String? {
        guard let target = Self.host(of: school.targetURL) else { return nil }
        let current = webView?.url?.host?.lowercased()
        guard current != target else { return nil }
        return "当前页面（\(current ?? "未打开")）不是教务系统的课表页。请先登录，并进入「我的课表」页面，再点右上角「重新解析」。"
    }

    /// `targetUrl` 可能带 `*default` 这种通配段，`URL(string:)` 不一定认，所以手动取 host。
    static func host(of pattern: String) -> String? {
        if let host = URLComponents(string: pattern)?.host, !host.isEmpty { return host.lowercased() }
        guard let scheme = pattern.range(of: "://") else { return nil }
        let rest = pattern[scheme.upperBound...]
        let host = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != ":" }
        return host.isEmpty ? nil : host.lowercased()
    }

    private func runExtraction() {
        guard let webView, !isExtracting else { return }
        isExtracting = true
        statusMessage.wrappedValue = "正在读取课表数据…"
        lastPageFacts = nil
        Task { @MainActor in lastPageFacts = await pageFacts(of: webView) }
        let extract = school.extractJS
        // School scripts follow the Flutter app's
        // `runJavaScriptReturningResult` convention: the payload is the
        // *completion value of the script's last statement* — a bare
        // `scheduleHtmlParser();` call or an IIFE — and never a top-level
        // `return`. Evaluating them as the body of a function, as
        // `callAsyncJavaScript` does, discards that value, which made every
        // school fail with "学校解析脚本没有返回内容". Evaluating them as a plain
        // script preserves the completion value, and the try/catch below still
        // routes script errors into the `NAP_ERROR:` channel.
        let script = """
        try {
          \(extract)
        } catch (error) {
          "NAP_ERROR:" + (error && error.message ? error.message : String(error));
        }
        """
        Task { @MainActor in
            do {
                let value = try await webView.evaluateJavaScript(script)
                isExtracting = false
                guard let text = value as? String, !text.isEmpty, text != "undefined" else {
                    // The extractor returned nothing: the page is not the one the
                    // school's script expects, or its data has not loaded yet.
                    onExtract(.failure(ImportError.emptyResult(
                        "学校解析脚本没有返回内容" + pageSuffix
                            + "。请确认已经登录并停在课表页面（页面上能看到课程表），然后点「重新解析」。"
                    )))
                    return
                }
                if text.hasPrefix("NAP_ERROR:") {
                    let detail = text.replacingOccurrences(of: "NAP_ERROR:", with: "")
                    onExtract(.failure(ImportError.emptyResult(
                        "学校解析脚本在页面里出错了：" + detail + pageSuffix
                    )))
                    return
                }
                onExtract(.success(text))
            } catch {
                isExtracting = false
                onExtract(.failure(ImportError.emptyResult("无法在页面中解析课表：\(error.localizedDescription)")))
            }
        }
    }
}
