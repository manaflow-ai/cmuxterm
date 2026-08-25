import AppKit
import CmuxFoundation
import CmuxVoice
import WebKit

/// Pins the focused input target when dictation starts and types finalized
/// segments into it for the rest of the session.
///
/// Route priority (see `DictationInsertionRouteResolver`): a native text
/// responder wins, then editable web content in the key `WKWebView` (agent
/// composer, browser pane), then the focused terminal surface via the
/// typed-input PTY path. The target is pinned per session on purpose:
/// moving focus mid-dictation never scatters text across panes, and if the
/// pinned target goes away the session ends.
@MainActor
final class VoiceDictationInsertionRouter: DictationTextInserting {
    /// Resolves the focused terminal panel of the active workspace across
    /// window contexts; injected from the composition root.
    private let focusedTerminalPanel: () -> TerminalPanel?
    private let resolver = DictationInsertionRouteResolver()

    private weak var pinnedTextView: NSTextView?
    private weak var pinnedWebView: WKWebView?
    private weak var pinnedTerminalPanel: TerminalPanel?
    private var activeRoute: DictationInsertionRoute?
    private var webViewInsertionBroken = false

    private static let webEditableFocusScript = """
    (() => {
      let active = document.activeElement;
      while (active?.shadowRoot?.activeElement) {
        active = active.shadowRoot.activeElement;
      }
      if (!active || active.disabled || active.readOnly) return false;
      const tag = (active.tagName || "").toLowerCase();
      if (tag === "textarea") return true;
      if (tag === "input") return active.type !== "hidden";
      if (active.isContentEditable) return true;
      return !!active.closest?.('[contenteditable]:not([contenteditable="false"])');
    })()
    """

    init(focusedTerminalPanel: @escaping () -> TerminalPanel?) {
        self.focusedTerminalPanel = focusedTerminalPanel
    }

    func beginSession() async -> Bool {
        let responder = NSApp.keyWindow?.firstResponder
        let textView = responder as? NSTextView
        let webView = (responder as? NSView).flatMap(Self.enclosingWebView(of:))
        let terminalPanel = focusedTerminalPanel()
        let nativeTextInputIsEditable = textView?.isEditable == true
        let webViewIsEditable = if let webView {
            await Self.webViewHasEditableFocus(webView)
        } else {
            false
        }

        guard let route = resolver.route(
            firstResponderIsTextInput: nativeTextInputIsEditable,
            firstResponderIsWebView: webViewIsEditable,
            hasFocusedTerminalSurface: terminalPanel != nil
        ) else { return false }

        activeRoute = route
        switch route {
        case .nativeTextResponder:
            pinnedTextView = textView
        case .webViewEditable:
            pinnedWebView = webView
        case .terminalSurface:
            pinnedTerminalPanel = terminalPanel
        }
        return true
    }

    func insertFinalizedText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        switch activeRoute {
        case .nativeTextResponder:
            guard let textView = pinnedTextView, textView.window != nil else { return false }
            textView.insertText(text, replacementRange: textView.selectedRange())
            return true
        case .webViewEditable:
            guard let webView = pinnedWebView, webView.window != nil,
                  !webViewInsertionBroken,
                  let literal = text.javaScriptStringLiteral else { return false }
            // evaluateJavaScript reports failure asynchronously; a failed
            // insert (page navigated, editable lost focus) marks the route
            // broken so the next segment ends the session instead of
            // silently dropping text.
            webView.evaluateJavaScript(
                "document.execCommand('insertText', false, \(literal));"
            ) { [weak self] result, error in
                if error != nil || (result as? Bool) == false {
                    self?.webViewInsertionBroken = true
                }
            }
            return true
        case .terminalSurface:
            guard let panel = pinnedTerminalPanel else { return false }
            return panel.sendInputResult(text).accepted
        case nil:
            return false
        }
    }

    func endSession() {
        pinnedTextView = nil
        pinnedWebView = nil
        pinnedTerminalPanel = nil
        activeRoute = nil
        webViewInsertionBroken = false
    }

    private static func webViewHasEditableFocus(_ webView: WKWebView) async -> Bool {
        guard webView.window != nil else { return false }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(Self.webEditableFocusScript) { result, error in
                guard error == nil else {
                    continuation.resume(returning: false)
                    return
                }
                if let value = result as? Bool {
                    continuation.resume(returning: value)
                } else if let value = result as? NSNumber {
                    continuation.resume(returning: value.boolValue)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private static func enclosingWebView(of view: NSView) -> WKWebView? {
        var current: NSView? = view
        while let candidate = current {
            if let webView = candidate as? WKWebView { return webView }
            current = candidate.superview
        }
        return nil
    }
}
