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
    /// Called with the parsed schedule and the chosen destination once the user
    /// confirms.
    let onFinish: (ImportedSchedule, AppStore.ImportMode) -> Void

    @Environment(\.dismiss) private var dismiss
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

    /// `initialMode` is the destination chosen on the import hub. Without it the
    /// sheet always started on `.replaceCurrent`, which made the hub's
    /// 「导入方式」picker a dead control: whatever the user chose there, the
    /// confirmation screen showed — and imported with — "覆盖当前课表".
    init(
        school: SchoolConfig,
        initialMode: AppStore.ImportMode = .replaceCurrent,
        onFinish: @escaping (ImportedSchedule, AppStore.ImportMode) -> Void
    ) {
        self.school = school
        self.onFinish = onFinish
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let parsed {
                    ImportedScheduleForm(schedule: parsed, mode: $mode)
                } else {
                    browser
                }
            }
            .task(id: school.id) {
                // Start fetching as soon as the import route is selected.
                // The pipeline validates the matching term before confirmation.
                _ = try? await ScheduleSharingService.shared.loadSchools()
            }
            .navigationTitle(parsed == nil ? school.pageTitle : "确认导入")
            .appInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(parsed == nil ? "取消" : "返回") {
                        if parsed == nil { dismiss() } else { self.parsed = nil }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let parsed {
                        Button("导入") {
                            onFinish(parsed, mode)
                            dismiss()
                        }
                    } else {
                        Button("重新解析") { retry() }
                            .disabled(state == .importing)
                    }
                }
            }
        }
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
                Image(systemName: state == .failed ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(state == .failed ? .orange : .secondary)
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
    /// of leaving the user with a dead button.
    private func retry() {
        didStartExtraction = false
        if state == .loaded || state == .finished {
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
                    parsed = schedule
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
    case failed
    case finished
}

/// Owns the navigation script. Shared by both platform wrappers so the two
/// `#if` branches only carry the representable boilerplate.
@MainActor
final class SchoolWebCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
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
    private let reloadToken: Int
    private let extractToken: Int
    private var lastReloadToken = 0
    private var lastExtractToken = 0

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
        self.reloadToken = reloadToken
        self.extractToken = extractToken
        self.onExtract = onExtract
    }

    /// Applies the screen's reload / re-extract requests.
    func update(tokens: (reload: Int, extract: Int), webView: WKWebView) {
        if tokens.reload != lastReloadToken {
            lastReloadToken = tokens.reload
            didStartExtraction.wrappedValue = false
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
        configuration.userContentController = controller
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
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
            coordinator.state.wrappedValue = .failed
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
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? ""
        guard state.wrappedValue != .importing, state.wrappedValue != .finished else { return }
        state.wrappedValue = .loaded
        guard !didStartExtraction.wrappedValue else { return }
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

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        state.wrappedValue = .failed
        statusMessage.wrappedValue = "无法打开页面：\(error.localizedDescription)"
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
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
