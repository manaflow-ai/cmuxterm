import AppKit
import SwiftUI
import WebKit

/// A 1×1, fully transparent WKWebView that owns the microphone and the WebRTC
/// call to the local voice sidecar. It draws nothing; every visible control is
/// native SwiftUI in `VoiceAgentSidebarView`. Pipecat has no macOS Swift
/// client, so the page runs the Pipecat JS client and forwards events over the
/// `cmuxVoice` script-message bridge.
///
/// The view must stay in the window's view hierarchy (not `isHidden`) or WebKit
/// may throttle the page and stall audio.
struct VoiceAgentAudioWebView: NSViewRepresentable {
    let url: URL
    let state: VoiceAgentSessionState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, expectedPort: url.port)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: Coordinator.handlerName)
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.alphaValue = 0
        webView.setAccessibilityElement(false)
        context.coordinator.attach(webView)
        state.audioController = context.coordinator
        context.coordinator.load(url)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedURL != url {
            context.coordinator.load(url)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, VoiceAgentAudioControlling {
        static let handlerName = "cmuxVoice"

        private let state: VoiceAgentSessionState
        private let expectedPort: Int?
        private weak var webView: WKWebView?
        private(set) var loadedURL: URL?

        init(state: VoiceAgentSessionState, expectedPort: Int?) {
            self.state = state
            self.expectedPort = expectedPort
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func load(_ url: URL) {
            loadedURL = url
            webView?.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
        }

        func tearDown() {
            stop()
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
            webView?.stopLoading()
            if state.audioController === self {
                state.audioController = nil
            }
            webView = nil
        }

        // MARK: VoiceAgentAudioControlling

        func setMuted(_ muted: Bool) {
            evaluate("window.cmuxVoice && window.cmuxVoice.setMuted(\(muted ? "true" : "false"))")
        }

        func stop() {
            evaluate("window.cmuxVoice && window.cmuxVoice.stop()")
        }

        func requestRecap(surfaceID: String?) {
            let literal: String
            if let surfaceID, let data = try? JSONSerialization.data(withJSONObject: [surfaceID]),
               let json = String(data: data, encoding: .utf8) {
                literal = String(json.dropFirst().dropLast())  // the quoted string
            } else {
                literal = "null"
            }
            evaluate("window.cmuxVoice && window.cmuxVoice.recap(\(literal))")
        }

        private func evaluate(_ script: String) {
            webView?.evaluateJavaScript(script) { _, _ in }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.handlerName else { return }
            state.handleBridgeMessage(message.body)
        }

        // MARK: WKUIDelegate

        /// Grants the microphone only to our own loopback sidecar page. The page
        /// is first-party cmux UI, so no per-origin prompt is shown; macOS still
        /// asks for the app-level microphone permission the first time.
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            let isLoopback = origin.host == "127.0.0.1" || origin.host == "localhost"
            let portMatches = expectedPort == nil || origin.port == expectedPort
            decisionHandler(type == .microphone && isLoopback && portMatches ? .grant : .deny)
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            state.fail(String(
                localized: "voiceAgent.error.audioPageLoad",
                defaultValue: "Could not load the voice audio page: \(error.localizedDescription)"
            ))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            state.fail(String(
                localized: "voiceAgent.error.audioPageLoad",
                defaultValue: "Could not load the voice audio page: \(error.localizedDescription)"
            ))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            state.fail(String(
                localized: "voiceAgent.error.audioPageCrashed",
                defaultValue: "The voice audio page stopped unexpectedly. Start the session again."
            ))
        }
    }
}
