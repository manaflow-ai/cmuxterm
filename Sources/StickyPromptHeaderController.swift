import CmuxTerminal
import CmuxTerminalCore

@MainActor
final class StickyPromptHeaderController {
    private weak var surface: TerminalSurface?
    private var runtimeGeneration: UInt64?
    private var history = TerminalPromptHistory()

    var hasPrompt: Bool { history.latest != nil }

    func reset() {
        surface = nil
        runtimeGeneration = nil
        history = TerminalPromptHistory()
    }

    func bind(_ surface: TerminalSurface) {
        guard self.surface !== surface || runtimeGeneration != surface.runtimeSurfaceGeneration else { return }
        reset()
        self.surface = surface
        runtimeGeneration = surface.runtimeSurfaceGeneration
    }

    func record(_ preview: String, surface: TerminalSurface) -> TerminalPromptAnchor? {
        bind(surface)
        let anchor = surface.stickyPromptAnchor()
        history.record(preview: preview, anchor: anchor)
        return anchor
    }

    func selectedEntry(geometry: NotificationScrollRestoreGeometry) -> TerminalPromptHistoryEntry? {
        history.reconcile(rowSpaceRevision: geometry.rowSpaceRevision)
        return history.selectedEntry(
            viewportTopRow: Int(clamping: geometry.scrollbar.offset),
            isAtBottom: geometry.scrollbar.isAtBottom,
            rowSpaceRevision: geometry.rowSpaceRevision
        )
    }
}
