import AppKit
import CmuxFoundation

/// Native search control shared by Find and Vault.
@MainActor
class SidebarSearchField: NSSearchField {
    static let leadingPadding: CGFloat = 4
    static let topPadding: CGFloat = 0

    var onCommandSubmit: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override class var cellClass: AnyClass? {
        get { SidebarSearchFieldCell.self }
        set { super.cellClass = newValue }
    }

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

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEnabled, isEditable else { return }
        addCursorRect(searchTextBounds, cursor: .iBeam)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeAlways, .cursorUpdate, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) { updateHoverCursor(with: event) }
    override func mouseEntered(with event: NSEvent) { updateHoverCursor(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHoverCursor(with: event) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    private func updateHoverCursor(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let cursor: NSCursor = isEnabled && isEditable && searchTextBounds.contains(point) ? .iBeam : .arrow
        cursor.set()
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
        focusRingType = .none
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.lineBreakMode = .byClipping
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyFontScale()
    }
}
