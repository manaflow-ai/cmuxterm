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
    @ObservationIgnored private var jumpTask: Task<Void, Never>?

    deinit {
        jumpTask?.cancel()
    }

    func observe(
        panel: TerminalPanel,
        transcriptService: AgentChatTranscriptService?
    ) async {
        self.panel = panel
        self.transcriptService = transcriptService
        defer { cancelJump() }
        let changes = transcriptService?.sessionOutlineChanges(for: panel.id)
        await refresh()

        guard let changes else { return }
        for await _ in changes {
            guard !Task.isCancelled else { break }
            await refresh()
        }
    }

    @discardableResult
    func togglePresentation() -> Bool {
        guard transcriptService != nil, isAvailable else { return false }
        isPresented.toggle()
        if !isPresented {
            cancelJump()
        }
        return true
    }

    func dismissPresentation() {
        isPresented = false
        cancelJump()
    }

    func beginJump(to entry: ChatOutlineEntry) {
        jumpTask?.cancel()
        jumpTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.jump(to: entry)
        }
    }

    private func cancelJump() {
        jumpTask?.cancel()
        jumpTask = nil
    }

    @discardableResult
    func jump(to entry: ChatOutlineEntry) async -> Bool {
        guard let panel else {
            return false
        }
        let surfaceView = panel.hostedView.surfaceView
        guard let geometry = surfaceView.authoritativeScrollbarGeometry(),
              let history = panel.surface.readText(region: .screenRows) else {
            return false
        }
        let entries = entries
        let row = await Task.detached(priority: .userInitiated) {
            ChatOutlineAnchorResolver().row(
                for: entry,
                among: entries,
                in: history
            )
        }.value
        guard !Task.isCancelled, let row else {
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
        guard !Task.isCancelled else { return }
        guard let panel,
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
            dismissPresentation()
        }
    }
}
