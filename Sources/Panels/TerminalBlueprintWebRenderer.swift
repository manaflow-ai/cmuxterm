import AppKit
import SwiftUI
import WebKit

/// Panel-owned WebKit session for a blueprint canvas.
///
/// SwiftUI may recreate `TerminalBlueprintWebRenderer` wrappers when the pane
/// is re-laid out, collapsed, or moved. The session keeps the coordinator, and
/// with it the web view, tied to the panel so the canvas survives those churns.
@MainActor
final class TerminalBlueprintWebSession {
    let coordinator = TerminalBlueprintWebRenderer.Coordinator()

    var webView: WKWebView? {
        coordinator.webView
    }

    /// Drops the web view so the next mount starts from a fresh page.
    func teardown() {
        coordinator.teardown()
    }
}

/// Hosts the bundled Excalidraw page for one terminal's blueprint.
struct TerminalBlueprintWebRenderer: NSViewRepresentable {
    static let messageHandlerName = "cmuxBlueprint"

    let state: TerminalBlueprintState
    let session: TerminalBlueprintWebSession
    let isDark: Bool
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        session.coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.bind(state: state)
        if let webView = coordinator.webView {
            if webView.superview != nil {
                webView.removeFromSuperview()
            }
            (webView as? TerminalBlueprintWebView)?.onPointerDown = onRequestPanelFocus
            coordinator.applyTheme(isDark: isDark)
            return webView
        }

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        if let rootDirectory = CmuxBlueprintAssetResolver.defaultRootDirectory() {
            let resolver = CmuxBlueprintAssetResolver(rootDirectory: rootDirectory)
            let schemeHandler = CmuxBlueprintURLSchemeHandler(resolver: resolver)
            coordinator.schemeHandler = schemeHandler
            config.setURLSchemeHandler(schemeHandler, forURLScheme: CmuxBlueprintAssetResolver.scheme)
        }
        config.userContentController.add(
            WeakMarkdownScriptMessageHandler(coordinator),
            name: Self.messageHandlerName
        )
        let webView = TerminalBlueprintWebView(frame: .zero, configuration: config)
        webView.onPointerDown = onRequestPanelFocus
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        if #available(macOS 13.3, *) {
#if DEBUG
            webView.isInspectable = true
#else
            webView.isInspectable = false
#endif
        }
        coordinator.webView = webView
        coordinator.loadPage(isDark: isDark)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.bind(state: state)
        (nsView as? TerminalBlueprintWebView)?.onPointerDown = onRequestPanelFocus
        context.coordinator.applyTheme(isDark: isDark)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // The session retains the web view across SwiftUI churn; only an
        // explicit teardown releases it.
        if let retained = coordinator.webView, retained === nsView {
            return
        }
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
    }

    /// Owns the web view and speaks the `window.cmuxBlueprint` contract.
    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, TerminalBlueprintWebControlling {
        private(set) weak var state: TerminalBlueprintState?
        var webView: WKWebView?
        var schemeHandler: CmuxBlueprintURLSchemeHandler?
        private var loadedIsDark: Bool?
        private var didLoadPage = false

        func bind(state: TerminalBlueprintState) {
            if self.state !== state {
                self.state = state
            }
            state.webController = self
        }

        func loadPage(isDark: Bool) {
            guard let webView else { return }
            loadedIsDark = isDark
            didLoadPage = true
            webView.load(URLRequest(url: CmuxBlueprintAssetResolver.pageURL(isDark: isDark)))
        }

        func applyTheme(isDark: Bool) {
            guard loadedIsDark != isDark else { return }
            loadedIsDark = isDark
            guard state?.isWebViewReady == true else { return }
            Task { await setTheme(isDark: isDark) }
        }

        func teardown() {
            guard let webView else { return }
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: TerminalBlueprintWebRenderer.messageHandlerName
            )
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
            self.webView = nil
            didLoadPage = false
            state?.webViewDidReset()
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == TerminalBlueprintWebRenderer.messageHandlerName,
                  let decoded = TerminalBlueprintBridgeMessage(body: message.body) else {
                return
            }
            state?.handleBridgeMessage(decoded)
        }

        // MARK: WKNavigationDelegate

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            state?.webViewDidReset()
            if let loadedIsDark {
                loadPage(isDark: loadedIsDark)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let isPageScheme = navigationAction.request.url?.scheme?.lowercased() == CmuxBlueprintAssetResolver.scheme
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            decisionHandler(isPageScheme || !isMainFrame ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            state?.handleBridgeMessage(.error(message: error.localizedDescription))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            state?.handleBridgeMessage(.error(message: error.localizedDescription))
        }

        // MARK: TerminalBlueprintWebControlling

        func setScene(_ sceneJSON: String, source: TerminalBlueprintDocument.Author) async throws -> Int {
            let result = try await call(
                "return await window.cmuxBlueprint.setScene(sceneJSON, opts);",
                arguments: ["sceneJSON": sceneJSON, "opts": ["source": source.rawValue]]
            )
            return Self.integer((result as? [String: Any])?["elementCount"]) ?? 0
        }

        func currentSceneJSON() async throws -> String {
            let result = try await call("return await window.cmuxBlueprint.getScene();")
            guard let sceneJSON = (result as? [String: Any])?["sceneJSON"] as? String else {
                throw TerminalBlueprintError.webViewUnavailable
            }
            return sceneJSON
        }

        func summary() async throws -> String {
            let result = try await call("return await window.cmuxBlueprint.getSummary();")
            return result as? String ?? ""
        }

        func requestExport(
            requestID: String,
            png: Bool,
            svg: Bool,
            mermaid: Bool,
            scale: Double,
            dark: Bool
        ) async throws {
            _ = try await call(
                "window.cmuxBlueprint.requestExport(requestId, opts); return true;",
                arguments: [
                    "requestId": requestID,
                    "opts": ["png": png, "svg": svg, "mermaid": mermaid, "scale": scale, "dark": dark],
                ]
            )
        }

        func setTheme(isDark: Bool) async {
            _ = try? await call(
                "window.cmuxBlueprint.setTheme(theme); return true;",
                arguments: ["theme": isDark ? "dark" : "light"]
            )
        }

        func zoomToFit() async {
            _ = try? await call("window.cmuxBlueprint.zoomToFit(); return true;")
        }

        func clearScene() async {
            _ = try? await call("window.cmuxBlueprint.clear(); return true;")
        }

        private func call(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
            guard let webView else { throw TerminalBlueprintError.webViewUnavailable }
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page)
        }

        private static func integer(_ value: Any?) -> Int? {
            if let int = value as? Int { return int }
            if let double = value as? Double, double.isFinite { return Int(double) }
            if let number = value as? NSNumber { return number.intValue }
            return nil
        }
    }
}
