import AppKit
import WebKit

/// The blueprint canvas web view. Reports pointer focus and window attachment
/// to its owner; everything else is stock WebKit so Excalidraw keeps its own
/// keyboard handling (the page routes Escape back to the terminal itself).
final class TerminalBlueprintWebView: WKWebView {
    var onPointerDown: (() -> Void)?
    var onAttachToWindow: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onPointerDown?()
        super.rightMouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onAttachToWindow?()
        }
    }
}
