import Bonsplit
import CmuxTerminal
import CmuxTerminalCore
import CmuxWorkspaces
import Foundation

extension DockSplitStore {
    func sessionAgentAlreadyActive(
        restorableAgent: SessionRestorableAgentSnapshot?,
        snapshotPanelId: UUID,
        shouldAutoResume: Bool,
        liveIndex: RestorableAgentSessionIndex?,
        restoreStartupBlocked: Bool,
        liveSessionOwner: LiveAgentSessionOwner?
    ) -> Bool {
        guard shouldAutoResume, let restorableAgent else { return false }
        if restoreStartupBlocked {
            // The off-main index refresh will resolve this staged panel.
            return true
        }
        guard let index = liveIndex else { return true }
        if liveSessionOwner != nil { return true }
        if index.hasCurrentAmbiguousPanel(
            snapshotPanelId,
            revalidateProcessEvidence: false
        ) {
            // Unknown ownership is safer than launching a duplicate agent against a
            // session that may still be live under another restored owner.
            return true
        }
        if index.hasCurrentLiveProcessForStablePanel(
            workspaceId: workspaceId,
            panelId: snapshotPanelId,
            expectedKind: restorableAgent.kind.rawValue,
            expectedSessionId: restorableAgent.sessionId,
            revalidateProcessEvidence: false
        ) {
            return true
        }
        return false
    }

    func restoreAgentIndex(
        for panels: [SessionPanelSnapshot]
    ) -> RestorableAgentSessionIndex? {
        // Load at most once for this restore pass; every panel reuses the same snapshot.
        guard AgentSessionAutoResumeSettings.isEnabled(
            defaults: agentSessionAutoResumeDefaults
        ), panels.contains(where: { panel in
            panel.terminal?.agent != nil || panel.terminal?.resumeBinding?.isAgentHookBinding == true
        }) else {
            return nil
        }
        // Ownership-sensitive restore decisions use the injected authoritative
        // index, or defer launch until the off-main refresh completes.
        return restorableAgentIndexProvider()
    }
}
