import SwiftUI
import WebKit

/// Hosts the school's login page. The two platform wrappers are identical apart
/// from the representable protocol, so the web view and the navigation script
/// live in `SchoolWebCoordinator` and both branches stay three lines long.
#if os(macOS)
struct SchoolWebView: NSViewRepresentable {
    let school: SchoolConfig
    @Binding var state: WebImportState
    @Binding var didStartExtraction: Bool
    @Binding var statusMessage: String
    @Binding var progress: Double
    let reloadToken: Int
    let extractToken: Int
    let onExtract: (Result<String, Error>) -> Void

    func makeCoordinator() -> SchoolWebCoordinator {
        SchoolWebCoordinator(
            school: school,
            state: $state,
            didStartExtraction: $didStartExtraction,
            statusMessage: $statusMessage,
            progress: $progress,
            reloadToken: reloadToken,
            extractToken: extractToken,
            onExtract: onExtract
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        SchoolWebCoordinator.makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(tokens: (reloadToken, extractToken), webView: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: SchoolWebCoordinator) {
        coordinator.stopObserving()
    }
}
#else
struct SchoolWebView: UIViewRepresentable {
    let school: SchoolConfig
    @Binding var state: WebImportState
    @Binding var didStartExtraction: Bool
    @Binding var statusMessage: String
    @Binding var progress: Double
    let reloadToken: Int
    let extractToken: Int
    let onExtract: (Result<String, Error>) -> Void

    func makeCoordinator() -> SchoolWebCoordinator {
        SchoolWebCoordinator(
            school: school,
            state: $state,
            didStartExtraction: $didStartExtraction,
            statusMessage: $statusMessage,
            progress: $progress,
            reloadToken: reloadToken,
            extractToken: extractToken,
            onExtract: onExtract
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        SchoolWebCoordinator.makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(tokens: (reloadToken, extractToken), webView: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: SchoolWebCoordinator) {
        coordinator.stopObserving()
    }
}
#endif
