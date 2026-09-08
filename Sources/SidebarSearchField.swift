import AppKit
import CmuxFoundation

/// Native search control shared by Find and Vault.
@MainActor
class SidebarSearchField: NSSearchField {
    var onCommandSubmit: (() -> Void)?

    static var visibleHeight: CGFloat {
        max(22, RightSidebarChromeMetrics.controlHeight + 2)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func applyFontScale() {
        font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .regular)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Match Vault's borderless fill while AppKit retains ownership of
        // the editor, cursor rectangles, selection, and search buttons.
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        super.draw(dirtyRect)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleCommandSubmit(event) || super.performKeyEquivalent(with: event)
    }

    func handleCommandSubmit(_ event: NSEvent) -> Bool {
        guard let onCommandSubmit,
              let editor = currentEditor() as? NSTextView,
              window?.firstResponder === editor,
              !editor.hasMarkedText(),
              event.type == .keyDown,
              event.keyCode == 36 || event.keyCode == 76,
              event.modifierFlags.contains(.command) else { return false }
        onCommandSubmit()
        return true
    }

    private func configure() {
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.lineBreakMode = .byClipping
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyFontScale()
    }
}
