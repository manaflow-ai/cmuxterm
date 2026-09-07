import CmuxAgentChat
import CmuxTerminal
import Foundation
import Observation

@MainActor
@Observable
final class SessionOutlineModel {
    private(set) var entries: [ChatOutlineEntry] = []
    private(set) var isAvailable = false
    var isPresented = false

    @ObservationIgnored private weak var panel: TerminalPanel?
    @ObservationIgnored private weak var transcriptService: AgentChatTranscriptService?

    func observe(
        panel: TerminalPanel,
        transcriptService: AgentChatTranscriptService?
    ) async {
        self.panel = panel
        self.transcriptService = transcriptService
        let changes = transcriptService?.sessionOutlineChanges()
        await refresh()

        guard let changes else { return }
        for await surfaceID in changes {
            guard !Task.isCancelled, surfaceID == panel.id.uuidString else { continue }
            await refresh()
        }
    }

    @discardableResult
    func togglePresentation() -> Bool {
        guard transcriptService != nil else { return false }
        isPresented.toggle()
        return true
    }

    @discardableResult
    func jump(to entry: ChatOutlineEntry) -> Bool {
        guard let panel,
              let history = panel.surface.readText(region: .history) else {
            return false
        }
        guard let row = ChatOutlineAnchorResolver().row(
            for: entry,
            among: entries,
            in: history
        ) else {
            return false
        }
        let surfaceView = panel.hostedView.surfaceView
        guard let geometry = surfaceView.authoritativeScrollbarGeometry() else {
            return false
        }

        let lastTopRow = Int(clamping: geometry.scrollbar.total - min(
            geometry.scrollbar.total,
            geometry.scrollbar.len
        ))
        let targetRow = min(max(row, 0), lastTopRow)
        let previousIntent = surfaceView.prepareExplicitViewportRestore(
            isAtBottom: targetRow >= lastTopRow
        )
        guard surfaceView.scrollToRow(
            targetRow,
            ifRowSpaceRevisionMatches: geometry.rowSpaceRevision
        ) != nil else {
            surfaceView.rollbackExplicitViewportRestore(to: previousIntent)
            return false
        }
        return true
    }

    private func refresh() async {
        guard !Task.isCancelled,
              let panel,
              let transcriptService else {
            entries = []
            isAvailable = false
            isPresented = false
            return
        }
        let nextEntries = await transcriptService.sessionOutline(for: panel.surface.id) ?? []
        guard !Task.isCancelled else { return }
        entries = nextEntries
        isAvailable = !nextEntries.isEmpty
        if !isAvailable {
            isPresented = false
        }
    }
}
