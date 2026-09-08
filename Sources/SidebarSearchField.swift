import AppKit
import CmuxFoundation

/// Native search control shared by Find and Vault.
@MainActor
class SidebarSearchField: NSSearchField {
    var onCommandSubmit: (() -> Void)?

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
