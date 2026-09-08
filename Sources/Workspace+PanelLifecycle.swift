import Bonsplit
import CmuxSettings
import CmuxCore
import Darwin
import Foundation
import CmuxSidebar

extension Workspace {
    func discardClosedPanelLifecycleState(
        panelId: UUID,
        tabId: TabID? = nil,
        paneId: PaneID?,
        panel: (any Panel)?,
        origin: String,
        closePanel: Bool,
        publishSurfaceClosedEvent: Bool,
        clearSurfaceNotifications: Bool,
        requestTransferredRemoteCleanup: Bool,
        discardAgentHibernationTracking: Bool = true,
        cleanupControllerSurfaceState: Bool = false,
        preservesTerminalForTransfer: Bool = false
    ) -> WorkspaceRemoteConfiguration? {
        appLinkHandoffCoordinator.cancel(sourcePanelID: panelId)
        if !preservesTerminalForTransfer {
            FeedCoordinator.shared.retireAgentAttention(
                workspaceId: id,
                panelId: panelId
            )
        }
        if publishSurfaceClosedEvent {
            publishCmuxSurfaceClosed(panelId, paneId: paneId, panel: panel, origin: origin)
        }

        let closedAgentRuntimeState = agentRuntimeState(forPanelId: panelId)
        removePendingTerminalInputObservers(forPanelId: panelId)
        let transferredRemoteCleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)?.cancel()
        (panel as? FilePreviewPanel)?.unbindTabMetadata()
        discardAgentSessionPanelSubscription(panelId: panelId, panel: panel)
        discardBrowserPanelSubscription(panelId: panelId, panel: panel)
        removeBrowserOpenTabSuggestionIfNeeded(panel: panel, panelId: panelId)
        if cleanupControllerSurfaceState {
            TerminalController.shared.cleanupSurfaceState(
                surfaceIds: [panelId, tabId?.uuid].compactMap { $0 }
            )
        }
        if !preservesTerminalForTransfer {
            terminalStartupRestoreCoordinator.discardPendingRestoreForPanelTeardown(
                panelID: panelId
            )
        }
        if closePanel {
            panel?.close()
        }

        let shouldPreserveRemoteDisconnectOnClose =
            origin == "tab_close" ||
            origin == "pane_close"
        if shouldPreserveRemoteDisconnectOnClose,
           panel is TerminalPanel {
            markRemoteTerminalSessionClosingIfLast(surfaceId: panelId)
        }
        let shouldRefreshRemoteDisconnectPlaceholder =
            shouldPreserveRemoteDisconnectOnClose &&
            remoteDisconnectPlaceholderPanelIds.remove(panelId) != nil &&
            panels.count == 1
        cancelPendingRemoteDisconnectReplacement(surfaceId: panelId)
        if shouldRefreshRemoteDisconnectPlaceholder,
           let remoteConfiguration {
            rememberPendingRemoteDisconnectReplacement(
                surfaceId: panelId,
                configuration: remoteConfiguration
            )
        }

        let removedPanel = panels.removeValue(forKey: panelId)
        if discardAgentHibernationTracking {
            AgentHibernationController.shared.discardTrackingStateForClosedPanel(
                workspaceId: id,
                panelId: panelId
            )
        }
        if let terminalPanel =
                (removedPanel ?? panel) as? TerminalPanel {
            terminalFontSizeChangeCoordinator?
                .terminalDidLeaveWorkspace(
                    terminalPanel,
                    workspace: self,
                    preservingTransfer:
                        preservesTerminalForTransfer
                )
        }
        untrackRemoteTerminalSurface(panelId)
        if closePanel {
            endedRemoteTerminalLifecycleIDsBySurfaceId.removeValue(forKey: panelId)
        }
        discardRemoteDirectoryTrustState(panelId: panelId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
        removeSurfaceMappings(forPanelId: panelId)

        panelDirectories.removeValue(forKey: panelId)
        panelDirectoryDisplayLabels.removeValue(forKey: panelId)
        panelGitBranches.removeValue(forKey: panelId)
        panelPullRequests.removeValue(forKey: panelId)
        panelTitles.removeValue(forKey: panelId)
        panelCustomTitles.removeValue(forKey: panelId)
        panelCustomTitleSources.removeValue(forKey: panelId)
        pinnedPanelIds.remove(panelId)
        pinMutationTokensByPanelId.removeValue(forKey: panelId)
        manualUnreadPanelIds.remove(panelId)
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        panelShellActivityStates.removeValue(forKey: panelId)
        restoredPanelTitleBoundariesByPanelId.removeValue(forKey: panelId)
        clearAgentLifecycleStates(panelId: panelId)
        surfaceTTYNames.removeValue(forKey: panelId)
        discardRemotePTYSessionID(panelId: panelId)
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        pendingPlainSSHRestorePanelIds.remove(panelId)
        observedPlainSSHPanelIds.remove(panelId)
        plainSSHDetectionMissesByPanelId.removeValue(forKey: panelId)
        surfaceListeningPorts.removeValue(forKey: panelId)
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
#if DEBUG
        debugSessionSnapshotScrollbackFallbackPanelIds.remove(panelId)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeValue(forKey: panelId)
#endif
        discardAgentRuntimeState(closedAgentRuntimeState)
        clearRestoredAgentSnapshot(panelId: panelId)
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
        removeTerminalConfigInheritanceSource(panelId: panelId)
        if clearSurfaceNotifications {
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id, surfaceId: panelId)
        }

        if requestTransferredRemoteCleanup, let transferredRemoteCleanupConfiguration {
            requestSSHControlMasterCleanupIfNeeded(configuration: transferredRemoteCleanupConfiguration)
        }
        return transferredRemoteCleanupConfiguration
    }
}
