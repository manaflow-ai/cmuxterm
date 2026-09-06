import AppKit
import CmuxTerminal
import Foundation

struct StickyPromptHeaderEntry: Equatable, Identifiable {
    let id: String
    let row: Int
    let preview: String
}

enum StickyPromptHeaderSelection {
    static func entry(
        for viewportTopRow: Int,
        in entries: [StickyPromptHeaderEntry]
    ) -> StickyPromptHeaderEntry? {
        guard !entries.isEmpty else { return nil }
        return entries.last(where: { $0.row <= viewportTopRow }) ?? entries[0]
    }
}

@MainActor
final class StickyPromptHeaderStore {
    static let shared = StickyPromptHeaderStore()
    static let didChangeNotification = Notification.Name("stickyPromptHeaderDidChange")

    private var entriesBySurfaceID: [UUID: [StickyPromptHeaderEntry]] = [:]

    @discardableResult
    func recordPrompt(
        surface: TerminalSurface,
        preview: String
    ) -> StickyPromptHeaderEntry? {
        guard let anchor = surface.stickyPromptAnchor() else { return nil }
        let entry = StickyPromptHeaderEntry(
            id: "\(surface.id.uuidString):\(anchor.row):\(anchor.rowSpaceRevision)",
            row: anchor.row,
            preview: preview
        )
        var entries = entriesBySurfaceID[surface.id, default: []]
        if let last = entries.last,
           last.row == entry.row,
           last.preview == entry.preview {
            return last
        }
        entries.append(entry)
        entries.sort { $0.row < $1.row }
        entriesBySurfaceID[surface.id] = entries
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: surface.id
        )
        return entry
    }

    func entries(for surfaceID: UUID) -> [StickyPromptHeaderEntry] {
        entriesBySurfaceID[surfaceID, default: []]
    }

    func selectedEntry(
        for surfaceID: UUID,
        viewportTopRow: Int,
        isAtBottom: Bool
    ) -> StickyPromptHeaderEntry? {
        let entries = entries(for: surfaceID)
        guard !entries.isEmpty else { return nil }
        if isAtBottom { return entries.last }
        return StickyPromptHeaderSelection.entry(for: viewportTopRow, in: entries)
    }
}

final class StickyPromptHeaderOverlayView: NSView {
    private let backgroundView = NSVisualEffectView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private var currentEntry: StickyPromptHeaderEntry?

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
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setEntry(_ entry: StickyPromptHeaderEntry?) {
        guard currentEntry != entry else { return }
        currentEntry = entry
        label.stringValue = entry?.preview ?? ""
        isHidden = entry == nil
        accessibilityLabel = entry?.preview
        needsDisplay = true
    }
}
