import AppKit
import CmuxTerminalCore

@MainActor
final class StickyPromptHeaderOverlayView: NSView {
    private let backgroundView = NSVisualEffectView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private(set) var currentEntry: TerminalPromptHistoryEntry?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 5

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .active
        backgroundView.alphaValue = 0.94
        addSubview(backgroundView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        backgroundView.addSubview(label)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
        ])
        setAccessibilityIdentifier("terminalStickyPromptHeader")
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setEntry(_ entry: TerminalPromptHistoryEntry?) {
        guard currentEntry != entry else { return }
        currentEntry = entry
        label.stringValue = entry?.preview ?? ""
        isHidden = entry == nil
        setAccessibilityLabel(entry?.preview)
    }
}
