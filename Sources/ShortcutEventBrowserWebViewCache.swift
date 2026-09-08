import AppKit
import ObjectiveC
import WebKit

/// Keeps the direct browser ownership result for one AppKit event while it
/// crosses the application, window, and web-view key-equivalent boundaries.
/// The cache is attached to the event itself, so it cannot grow with the
/// number of panes or keystrokes and needs no app-wide mutable registry.
final class ShortcutEventBrowserWebViewCache {
    fileprivate static var associationKey: UInt8 = 0

    /// Event associations must not keep a closed auxiliary window or WebView
    /// alive. Ownership is held by the window/panel graph; this cache only
    /// observes it while that graph remains live.
    weak var eventWindow: NSWindow?
    weak var firstResponder: NSResponder?
    weak var webView: CmuxWebView?
    let activeChordPrefix: ShortcutStroke?
    var captureDecision: Bool?
    private(set) var captureIsCommitted = false

    init(
        eventWindow: NSWindow,
        firstResponder: NSResponder,
        webView: CmuxWebView?,
        activeChordPrefix: ShortcutStroke?
    ) {
        self.eventWindow = eventWindow
        self.firstResponder = firstResponder
        self.webView = webView
        self.activeChordPrefix = activeChordPrefix
    }

    deinit {}

    /// Marks a positive capture decision as the owner of this AppKit event.
    ///
    /// The local application monitor can evaluate a chord suffix while its
    /// temporary active prefix is set, then clear that prefix before AppKit
    /// asks the window/web view to handle the same event. Once the monitor has
    /// yielded the event, ownership must survive that routing-state cleanup.
    func commitCapture() {
        guard captureDecision == true else { return }
        captureIsCommitted = true
    }

    func matches(
        window: NSWindow,
        responder: NSResponder,
        activeChordPrefix: ShortcutStroke?
    ) -> Bool {
        guard let eventWindow, let firstResponder else { return false }
        guard eventWindow === window,
              firstResponder === responder else {
            return false
        }
        // A committed capture decision owns the event beyond the temporary
        // chord-prefix scope used by the local monitor. Provisional matches
        // remain prefix-sensitive so a stale cache cannot cross chord state.
        return captureIsCommitted || self.activeChordPrefix == activeChordPrefix
    }
}

extension NSEvent {
    var cmuxBrowserWebViewCache: ShortcutEventBrowserWebViewCache? {
        get {
            objc_getAssociatedObject(self, &ShortcutEventBrowserWebViewCache.associationKey)
                as? ShortcutEventBrowserWebViewCache
        }
        set {
            objc_setAssociatedObject(
                self,
                &ShortcutEventBrowserWebViewCache.associationKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}
