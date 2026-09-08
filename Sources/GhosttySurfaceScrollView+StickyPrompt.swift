import AppKit
import CmuxTerminal
import CmuxTerminalCore

@MainActor
extension GhosttySurfaceScrollView {
    func installStickyPromptHeader(above scrollView: NSView) {
        addSubview(stickyPromptHeaderOverlayView, positioned: .above, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            stickyPromptHeaderOverlayView.topAnchor.constraint(equalTo: topAnchor),
            stickyPromptHeaderOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stickyPromptHeaderOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stickyPromptHeaderOverlayView.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @discardableResult
    func recordSubmittedPrompt(_ preview: String, surface: TerminalSurface) -> TerminalPromptAnchor? {
        guard surfaceView.terminalSurface === surface else { return nil }
        let anchor = stickyPromptHeaderController.record(preview, surface: surface)
        updateStickyPromptHeader()
        return anchor
    }

    func updateStickyPromptHeader() {
        guard let surface = surfaceView.terminalSurface else {
            stickyPromptHeaderController.reset()
            stickyPromptHeaderOverlayView.setEntry(nil)
            return
        }
        stickyPromptHeaderController.bind(surface)
        guard stickyPromptHeaderController.hasPrompt,
              let geometry = surfaceView.authoritativeScrollbarGeometry() else {
            stickyPromptHeaderOverlayView.setEntry(nil)
            return
        }
        stickyPromptHeaderOverlayView.setEntry(
            stickyPromptHeaderController.selectedEntry(geometry: geometry)
        )
    }
}
