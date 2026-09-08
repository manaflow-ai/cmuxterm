#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

extension WorkspaceDetailView {
    var workspaceChangesChip: MobileWorkspaceChangesChip? {
        store.workspaceChangeChipsByWorkspaceID[workspace.rpcWorkspaceID.rawValue]
    }

    /// Matches detail chrome's workspace-scoped connected state and the host capability gate.
    var workspaceChangesAreAvailable: Bool {
        store.workspaceChangesCapable && connectionStatus == .connected
    }

    /// Dirty terminal-title entry point. Browser headers keep their
    /// existing labels and chrome unchanged.
    var workspaceTitleChangesChip: MobileWorkspaceChangesChip? {
        guard activeBrowser == nil,
              workspaceChangesAreAvailable,
              let chip = workspaceChangesChip,
              chip.filesChanged > 0 else { return nil }
        return chip
    }

    /// Restarts hint eligibility only when its authoritative inputs change.
    var workspaceChangesHintEligibilityKey: String {
        let capability = store.workspaceChangesCapable ? 1 : 0
        let connected = connectionStatus == .connected ? 1 : 0
        let filesChanged = workspaceChangesChip?.filesChanged ?? 0
        return "\(workspace.rpcWorkspaceID.rawValue)#\(capability)#\(connected)#\(filesChanged)"
    }

    /// The single presentation path shared by the toolbar, title pill, and hint banner.
    func openWorkspaceChanges() {
        guard workspaceChangesAreAvailable else { return }
        let workspaceID = workspace.rpcWorkspaceID.rawValue
        workspaceChangesPresentation.present {
            dismissTerminalKeyboardForChrome()
            store.dismissWorkspaceChangesHint(workspaceID: workspaceID)
            workspaceChangesHint = nil
            Task {
                await store.fetchWorkspaceChangesSummaries(
                    workspaceIDs: [workspaceID],
                    force: true
                )
            }
        }
    }

    func dismissWorkspaceChangesHint() {
        let workspaceID = workspace.rpcWorkspaceID.rawValue
        store.dismissWorkspaceChangesHint(workspaceID: workspaceID)
        workspaceChangesHint = nil
    }

    func refreshWorkspaceChangesHint() {
        guard !UITestConfig.hideWorkspaceChangesHintForScreenshots else {
            workspaceChangesHint = nil
            return
        }
        // A transient reconnect toggles both capability and connection gates.
        // Keep the already-presented hint in local view state across that
        // transport churn; the banner itself is hidden while unavailable and
        // reuses this same state after the handshake. A dismissed hint is nil
        // and remains suppressed by the store-backed eligibility check.
        guard workspaceChangesAreAvailable,
              workspaceChangesHint == nil else { return }
        workspaceChangesHint = store.workspaceChangesHint(
            workspaceID: workspace.rpcWorkspaceID.rawValue
        )
    }
}
#endif
