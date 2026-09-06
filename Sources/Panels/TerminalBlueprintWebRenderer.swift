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

    /// Creates and loads the canvas page without a host view, so agents can
    /// draw into a terminal whose drawer is closed or whose pane is off
    /// screen. The drawer adopts the same web view when it mounts.
    func ensureLoaded(state: TerminalBlueprintState, isDark: Bool) {
        coordinator.bind(state: state)
        _ = coordinator.makeWebViewIfNeeded(isDark: isDark)
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
        let existing = coordinator.webView
        let webView = coordinator.makeWebViewIfNeeded(isDark: isDark)
        if existing != nil, webView.superview != nil {
            webView.removeFromSuperview()
        }
        (webView as? TerminalBlueprintWebView)?.onPointerDown = onRequestPanelFocus
        coordinator.applyTheme(isDark: isDark)
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

        /// Returns the live web view, creating and loading it on first use.
        /// A view created here has no window yet; WebKit still runs the page,
        /// which is what lets agents draw into hidden drawers.
        func makeWebViewIfNeeded(isDark: Bool) -> WKWebView {
            if let webView { return webView }
            let config = WKWebViewConfiguration()
            config.suppressesIncrementalRendering = false
            if let rootDirectory = CmuxBlueprintAssetResolver.defaultRootDirectory() {
                let resolver = CmuxBlueprintAssetResolver(rootDirectory: rootDirectory)
                let schemeHandler = CmuxBlueprintURLSchemeHandler(resolver: resolver)
                self.schemeHandler = schemeHandler
                config.setURLSchemeHandler(schemeHandler, forURLScheme: CmuxBlueprintAssetResolver.scheme)
            }
            config.userContentController.add(
                WeakMarkdownScriptMessageHandler(self),
                name: TerminalBlueprintWebRenderer.messageHandlerName
            )
            // A non-zero frame keeps Excalidraw's layout sane while offscreen.
            let webView = TerminalBlueprintWebView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                configuration: config
            )
            webView.setValue(false, forKey: "drawsBackground")
            webView.allowsBackForwardNavigationGestures = false
            webView.allowsLinkPreview = false
            webView.navigationDelegate = self
            webView.uiDelegate = self
            if #available(macOS 13.3, *) {
#if DEBUG
                webView.isInspectable = true
#else
                webView.isInspectable = false
#endif
            }
            self.webView = webView
            loadPage(isDark: isDark)
            return webView
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
            failPendingInvocations(TerminalBlueprintError.webViewUnavailable)
            state?.webViewDidReset()
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == TerminalBlueprintWebRenderer.messageHandlerName else { return }
            if handleInvocationReply(message.body) { return }
            guard let decoded = TerminalBlueprintBridgeMessage(body: message.body) else { return }
            state?.handleBridgeMessage(decoded)
        }

        // MARK: WKNavigationDelegate

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            failPendingInvocations(TerminalBlueprintError.webViewUnavailable)
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
            let object = try await callObject(
                "window.cmuxBlueprint.setScene(sceneJSON, opts)",
                arguments: ["sceneJSON": sceneJSON, "opts": ["source": source.rawValue]]
            )
            return Self.integer(object["elementCount"]) ?? 0
        }

        func currentSceneJSON() async throws -> String {
            let object = try await callObject("window.cmuxBlueprint.getScene()")
            guard let sceneJSON = object["sceneJSON"] as? String else {
                throw TerminalBlueprintError.renderFailed("getScene returned no sceneJSON")
            }
            return sceneJSON
        }

        func summary() async throws -> String {
            let value = try await callValue("window.cmuxBlueprint.getSummary()")
            return value as? String ?? ""
        }

        func renderMermaid(_ source: String, mode: TerminalBlueprintState.MermaidMode) async throws -> TerminalBlueprintRenderOutcome {
            let object = try await callObject(
                "window.cmuxBlueprint.renderMermaid(source, opts)",
                arguments: ["source": source, "opts": ["mode": mode.rawValue]]
            )
            return TerminalBlueprintRenderOutcome(
                elementCount: Self.integer(object["elementCount"]) ?? 0,
                warnings: (object["warnings"] as? [String]) ?? []
            )
        }

        func applyOps(_ ops: [[String: Any]]) async throws -> Int {
            let object = try await callObject(
                "window.cmuxBlueprint.applyOps(ops)",
                arguments: ["ops": ops]
            )
            return Self.integer(object["applied"]) ?? 0
        }

        func requestExport(
            requestID: String,
            png: Bool,
            svg: Bool,
            mermaid: Bool,
            scale: Double,
            dark: Bool
        ) async throws {
            _ = try await invoke(
                "window.cmuxBlueprint.requestExport(requestId, opts)",
                arguments: [
                    "requestId": requestID,
                    "opts": ["png": png, "svg": svg, "mermaid": mermaid, "scale": scale, "dark": dark],
                ]
            )
        }

        func setTheme(isDark: Bool) async {
            _ = try? await invoke("window.cmuxBlueprint.setTheme(theme)", arguments: ["theme": isDark ? "dark" : "light"])
        }

        func zoomToFit() async {
            _ = try? await invoke("window.cmuxBlueprint.zoomToFit()")
        }

        func clearScene() async {
            _ = try? await invoke("window.cmuxBlueprint.clear()")
        }

        // MARK: Page invocation

        /// How long one page call may take (Mermaid parsing loads a 3 MB chunk on first use).
        private static let invocationTimeout: Duration = .seconds(30)

        private var pendingInvocations: [String: CheckedContinuation<Any?, any Error>] = [:]
        private var invocationTimeouts: [String: Task<Void, Never>] = [:]

        /// Runs `expression` in the page and returns its awaited value.
        ///
        /// The page's Content Security Policy has no `unsafe-eval`, which makes
        /// `callAsyncJavaScript` (function construction) drop its result. So the
        /// script is evaluated as ordinary page code and the value comes back
        /// through the `cmuxBlueprint` message handler, like exports do.
        /// `arguments` become `const` bindings visible to the expression.
        private func invoke(_ expression: String, arguments: [String: Any] = [:]) async throws -> Any? {
            guard let webView else { throw TerminalBlueprintError.webViewUnavailable }
            let requestID = UUID().uuidString
            var bindings: [String] = []
            for (name, value) in arguments {
                guard let literal = Self.jsLiteral(value) else {
                    throw TerminalBlueprintError.renderFailed("Argument \(name) is not JSON-encodable")
                }
                bindings.append("const \(name) = \(literal);")
            }
            let script = """
            (function () {
              \(bindings.joined(separator: "\n  "))
              const __post = (message) => window.webkit.messageHandlers.\(TerminalBlueprintWebRenderer.messageHandlerName).postMessage(message);
              Promise.resolve().then(() => (\(expression))).then(
                (value) => __post({ type: "invokeResult", requestId: \(Self.jsLiteral(requestID) ?? "\"\""), value: JSON.stringify(value === undefined ? null : value) }),
                (error) => __post({ type: "invokeFailed", requestId: \(Self.jsLiteral(requestID) ?? "\"\""), message: String((error && error.message) || error) })
              );
            })();
            """
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, any Error>) in
                pendingInvocations[requestID] = continuation
                invocationTimeouts[requestID] = Task { [weak self] in
                    try? await Task.sleep(for: Self.invocationTimeout)
                    guard !Task.isCancelled else { return }
                    self?.resolveInvocation(requestID, with: .failure(TerminalBlueprintError.renderFailed("The canvas did not answer in time")))
                }
                webView.evaluateJavaScript(script, in: nil, in: .page) { [weak self] result in
                    if case .failure(let error) = result {
                        self?.resolveInvocation(requestID, with: .failure(TerminalBlueprintError.renderFailed(TerminalBlueprintState.describeUnderlying(error))))
                    }
                }
            }
        }

        private func callObject(_ expression: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
            guard let object = try await invoke(expression, arguments: arguments) as? [String: Any] else {
                throw TerminalBlueprintError.renderFailed("The canvas returned no object for \(expression.prefix(60))")
            }
            return object
        }

        private func callValue(_ expression: String, arguments: [String: Any] = [:]) async throws -> Any? {
            try await invoke(expression, arguments: arguments)
        }

        /// Returns true when the message was an invocation reply.
        private func handleInvocationReply(_ body: Any) -> Bool {
            guard let object = body as? [String: Any],
                  let type = object["type"] as? String,
                  type == "invokeResult" || type == "invokeFailed",
                  let requestID = object["requestId"] as? String else {
                return false
            }
            if type == "invokeFailed" {
                let message = object["message"] as? String ?? "The canvas reported an error"
                resolveInvocation(requestID, with: .failure(TerminalBlueprintError.renderFailed(message)))
                return true
            }
            var value: Any?
            if let text = object["value"] as? String, let data = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                value = parsed is NSNull ? nil : parsed
            }
            resolveInvocation(requestID, with: .success(value))
            return true
        }

        private func resolveInvocation(_ requestID: String, with result: Result<Any?, any Error>) {
            invocationTimeouts.removeValue(forKey: requestID)?.cancel()
            guard let continuation = pendingInvocations.removeValue(forKey: requestID) else { return }
            continuation.resume(with: result)
        }

        private func failPendingInvocations(_ error: any Error) {
            for requestID in Array(pendingInvocations.keys) {
                resolveInvocation(requestID, with: .failure(error))
            }
        }

        /// A JavaScript literal for a JSON-encodable value (U+2028/2029 escaped).
        private static func jsLiteral(_ value: Any) -> String? {
            guard JSONSerialization.isValidJSONObject([value]),
                  let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]),
                  let wrapped = String(data: data, encoding: .utf8) else {
                return nil
            }
            // Strip the wrapping array used to allow scalar values.
            let inner = String(wrapped.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }

        private static func integer(_ value: Any?) -> Int? {
            if let int = value as? Int { return int }
            if let double = value as? Double, double.isFinite { return Int(double) }
            if let number = value as? NSNumber { return number.intValue }
            return nil
        }
    }
}
