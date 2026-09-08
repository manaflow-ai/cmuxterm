import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// At relaunch the live-agent index is loaded off-main, so every agent restore
/// is deferred until it settles. On a Mac running several agents the hook
/// stores never stop changing, the settled refresh gives up, and the deferred
/// restores used to be cancelled into plain shells with retired bindings, which
/// is the "resumes once, never again" report in
/// https://github.com/manaflow-ai/cmux/issues/5473.
@MainActor
@Suite("Deferred agent resume without a settled index")
struct DeferredAgentResumeIndexFallbackTests {
    private func agentHookBinding(checkpoint: String) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "Antigravity",
            kind: "antigravity",
            command: "cd -- '/tmp' 2>/dev/null || [ ! -d '/tmp' ] && 'agy' '--conversation' '\(checkpoint)'",
            cwd: "/tmp",
            checkpointId: checkpoint,
            source: "agent-hook",
            environment: nil,
            launchCommand: nil,
            permissionMode: nil,
            autoResume: true,
            resumeEvidenceProvenance: nil,
            updatedAt: 1_788_868_000
        )
    }

    @Test("A refresh that could not settle resolves against the most recent completed load")
    func unsettledRefreshFallsBackToLastKnownIndex() {
        let lastKnown = RestorableAgentSessionIndex.empty
        #expect(Workspace.deferredResumeIndex(refreshed: nil, lastKnown: lastKnown) != nil)
        #expect(Workspace.deferredResumeIndex(refreshed: nil, lastKnown: nil) == nil)
        let refreshed = RestorableAgentSessionIndex.empty
        #expect(Workspace.deferredResumeIndex(refreshed: refreshed, lastKnown: nil) != nil)
    }

    @Test("Cancelling for index unavailability keeps the binding auto-resumable")
    func indexUnavailabilityDoesNotRetireBindings() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let binding = agentHookBinding(checkpoint: "6e8458c7-7970-41e0-8d3e-00beda48097b")
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.deferredAgentResumeRestoresByPanelId[panelId] = DeferredAgentResumeRestore(
            stablePanelID: panelId,
            restorableAgent: nil,
            resumeBinding: binding,
            restoresRemoteWorkspaceTerminalSnapshot: false,
            workingDirectory: "/tmp",
            resumeWorkingDirectory: "/tmp"
        )

        workspace.clearDeferredAgentResumeRestores(retireBindings: false)

        #expect(workspace.deferredAgentResumeRestoresByPanelId[panelId] == nil)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .manualResumeAvailable)
        // The next relaunch may still auto-resume this session.
        #expect(workspace.surfaceResumeBindingsByPanelId[panelId]?.autoResume == true)
    }

    @Test("A positive ownership decision still retires the binding")
    func ownershipCancelRetiresBinding() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let binding = agentHookBinding(checkpoint: "312c5284-0000-4000-8000-000000000001")
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.deferredAgentResumeRestoresByPanelId[panelId] = DeferredAgentResumeRestore(
            stablePanelID: panelId,
            restorableAgent: nil,
            resumeBinding: binding,
            restoresRemoteWorkspaceTerminalSnapshot: false,
            workingDirectory: "/tmp",
            resumeWorkingDirectory: "/tmp"
        )

        workspace.clearDeferredAgentResumeRestores()

        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .manualResumeAvailable)
        #expect(workspace.surfaceResumeBindingsByPanelId[panelId]?.autoResume == false)
    }
}
