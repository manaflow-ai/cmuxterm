import Bonsplit
import CmuxSettings
import CmuxCore
import Darwin
import Foundation
import CmuxSidebar

extension Workspace {
    /// Returns exact-session runtime identities that still match their recorded process generation.
    func confirmedRuntimeAgentProcessIdentities(
        for agent: SessionRestorableAgentSnapshot,
        panelId: UUID,
        currentProcessIdentity: (Int) -> AgentPIDProcessIdentity?
    ) -> Set<AgentPIDProcessIdentity> {
        confirmedRuntimeAgentProcessIdentities(
            kind: agent.kind,
            sessionId: agent.sessionId,
            panelId: panelId,
            currentProcessIdentity: currentProcessIdentity
        )
    }

    /// Returns exact-session runtime identities that still match their recorded process generation.
    func confirmedRuntimeAgentProcessIdentities(
        kind: RestorableAgentKind,
        sessionId: String,
        panelId: UUID,
        currentProcessIdentity: (Int) -> AgentPIDProcessIdentity?
    ) -> Set<AgentPIDProcessIdentity> {
        // A shared-process key identifies the integration on this panel, not
        // one session, so it cannot supersede an exact cached session generation.
        guard BuiltInAgentIntegration(feedSourceName: kind.rawValue)?
            .lifecycleProcessOwnershipScope != .sharedProcess else {
            return []
        }
        let key = "\(kind.rawValue).\(sessionId)"
        guard agentPIDKeysByPanelId[panelId]?.contains(key) == true,
              let pid = agentPIDs[key],
              pid > 0,
              let recordedIdentity = agentPIDProcessIdentitiesByKey[key],
              recordedIdentity.pid == pid,
              currentProcessIdentity(Int(pid)) == recordedIdentity else {
            return []
        }
        return [recordedIdentity]
    }

    func suppressesRawTerminalNotification(panelId: UUID?) -> Bool {
        guard let panelId else {
            return false
        }

        if AgentIntegrationSettingsStore(defaults: .standard).suppressesSubagentNotifications,
           terminalPanelHasManagedSubagentStartupEnvironment(panelId: panelId) {
            return true
        }

        let panelKeys = agentPIDKeysByPanelId[panelId] ?? []
        return panelKeys.contains { isStructuredAgentHookPIDKey($0) }
    }

    private func terminalPanelHasManagedSubagentStartupEnvironment(panelId: UUID) -> Bool {
        guard let rawValue = terminalPanel(for: panelId)?
            .surface
            .startupEnvironmentValue(Self.managedSubagentEnvironmentKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return Self.truthyStartupEnvironmentValues.contains(rawValue)
    }

    func isStructuredAgentHookPIDKey(_ key: String) -> Bool {
        Self.structuredAgentHookStatusKeys.contains(agentStatusKey(forAgentPIDKey: key))
    }

    @discardableResult
    func clearAgentPID(
        key: String,
        panelId: UUID? = nil,
        clearStatus: Bool = false,
        requireOwnedKey: Bool = false,
        refreshPorts: Bool = true,
        definitiveProcessExit: Bool = false
    ) -> Bool {
        let ownedPanelId = agentPIDPanelIdsByKey[key]
        if requireOwnedKey, ownedPanelId == nil {
            return false
        }
        if let panelId, let ownedPanelId, ownedPanelId != panelId {
            return false
        }
        let lifecyclePanelId = ownedPanelId ?? panelId
        let statusKeyToClear =
            clearStatus ? agentStatusKey(forAgentPIDKey: key) : nil
        let hadFeedAttention: Bool
        if let statusKeyToClear, let lifecyclePanelId {
            hadFeedAttention = sidebarAgentRuntimeObservation
                .hasAgentFeedAttention(
                    key: statusKeyToClear,
                    panelId: lifecyclePanelId
                )
        } else {
            hadFeedAttention = false
        }
        let recordedProcessIdentity = agentPIDProcessIdentitiesByKey[key]
        sidebarAgentRuntimeObservation.cancelAgentProcessExitObservation(key: key)

        var didChange = false
        if agentPIDs.removeValue(forKey: key) != nil {
            didChange = true
        }
        if agentPIDProcessIdentitiesByKey.removeValue(forKey: key) != nil {
            didChange = true
        }
        if ownedPanelId != nil {
            removeAgentPIDOwnership(key: key)
            didChange = true
        }
        if let changedPanelId = lifecyclePanelId, didChange { AgentHibernationController.shared.recordAgentProcessChange(workspaceId: id, panelId: changedPanelId) }
        if let lifecyclePanelId {
            let lifecycleStatusKey = agentStatusKey(forAgentPIDKey: key)
            let remainingKeys = agentPIDKeysByPanelId[lifecyclePanelId] ?? []
            let hasRemainingStatusRuntime = remainingKeys.contains {
                agentStatusKey(forAgentPIDKey: $0) == lifecycleStatusKey
            }
            let hasRemainingGenerationOwner = recordedProcessIdentity.map {
                generation in
                remainingKeys.contains {
                    agentStatusKey(forAgentPIDKey: $0)
                        == lifecycleStatusKey
                        && agentPIDProcessIdentitiesByKey[$0]
                            == generation
                }
            } ?? false
            let didClearLifecycle: Bool
            if definitiveProcessExit,
               let recordedProcessIdentity,
               !hasRemainingGenerationOwner {
                didClearLifecycle = sidebarAgentRuntimeObservation.recordAgentProcessExit(
                    key: lifecycleStatusKey,
                    panelId: lifecyclePanelId,
                    generation: recordedProcessIdentity
                )
            } else if definitiveProcessExit,
                      AgentHibernationLifecycleStatusKeys(
                          rawValue: lifecycleStatusKey
                      ).isAllowed,
                      !hasRemainingStatusRuntime {
                didClearLifecycle = sidebarAgentRuntimeObservation
                    .recordUnidentifiedAgentProcessExit(
                        key: lifecycleStatusKey,
                        panelId: lifecyclePanelId,
                        isBuiltIn: true
                    )
            } else if !hasRemainingStatusRuntime {
                didClearLifecycle = sidebarAgentRuntimeObservation.removeAgentLifecycleKey(
                    key: lifecycleStatusKey,
                    panelId: lifecyclePanelId
                )
            } else {
                didClearLifecycle = false
            }
            if didClearLifecycle {
                didChange = true
                if !AgentHibernationLifecycleStatusKeys(
                    rawValue: lifecycleStatusKey
                ).isManual {
                    AgentHibernationController.shared.recordAgentLifecycleChange(
                        workspaceId: id,
                        panelId: lifecyclePanelId
                    )
                }
            }
        }
        if let statusKeyToClear,
           statusEntries[statusKeyToClear] != nil {
            let feedAttentionStillVisible =
                lifecyclePanelId.map {
                    sidebarAgentRuntimeObservation.hasAgentFeedAttention(
                        key: statusKeyToClear,
                        panelId: $0
                    )
                } ?? false
            if !hasAgentRuntime(forStatusKey: statusKeyToClear)
                || (hadFeedAttention && !feedAttentionStillVisible) {
                statusEntries.removeValue(forKey: statusKeyToClear)
                didChange = true
            }
        }
        if didChange, refreshPorts {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    /// Clears a panel's restored agent snapshot and resume metadata.
    func clearRestoredAgentSnapshot(panelId: UUID) {
        restoredAgentLifecycle.clearSessionRestore(panelId: panelId)
    }

    func refreshTrackedAgentPorts() {
        // Preserve the published snapshot until PortScanner reconciles the new
        // process tree; eagerly clearing here made every PID refresh flicker.
        let remainingAgentRoots = Set(agentPIDs.compactMap { key, pid -> AgentPortRootIdentity? in
            guard pid > 0 else { return nil }
            return AgentPortRootIdentity(
                pid: Int(pid),
                processIdentity: agentPIDProcessIdentitiesByKey[key]
            )
        })
        PortScanner.shared.refreshAgentPorts(workspaceId: id, agentRoots: remainingAgentRoots)
    }

    func recomputeListeningPorts() {
        let unique = Set(surfaceListeningPorts.values.flatMap { $0 })
            .union(agentListeningPorts)
            .union(remoteDetectedPorts)
            .union(remoteForwardedPorts)
        let next = unique.sorted()
        if listeningPorts != next {
            listeningPorts = next
        }
    }

    @discardableResult
    func discardAgentRuntimeState(_ runtimeState: DetachedAgentRuntimeState?) -> Bool {
        guard let runtimeState else { return false }
        var didChange = false
        for key in runtimeState.agentPIDKeys {
            if clearAgentPID(key: key, panelId: runtimeState.panelId, clearStatus: true, refreshPorts: false) {
                didChange = true
            }
        }
        for (statusKey, capturedStatusEntry) in runtimeState.statusEntries
            where !hasAgentRuntime(forStatusKey: statusKey)
                && statusEntries[statusKey] == capturedStatusEntry {
            statusEntries.removeValue(forKey: statusKey)
            didChange = true
        }
        if didChange {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    func adoptDetachedAgentRuntimeState(
        _ runtimeState: DetachedAgentRuntimeState?,
        isRemoteTerminal: Bool = false
    ) {
        guard let runtimeState else { return }
        for (statusKey, statusEntry) in runtimeState.statusEntries {
            statusEntries[statusKey] = statusEntry
        }
        let hasReconciliationEvidence =
            runtimeState.agentLifecycleReconciliationState.hasEvidence
        if hasReconciliationEvidence {
            sidebarAgentRuntimeObservation
                .adoptAgentLifecycleReconciliationSnapshot(
                    runtimeState.agentLifecycleReconciliationState,
                    panelId: runtimeState.panelId
                )
        }
        var didAdoptAgentPID = false
        var rejectedStatusKeys: Set<String> = []
        for (key, pid) in runtimeState.agentPIDs {
            let recordedIdentity =
                runtimeState.agentPIDProcessIdentities[key]
            if let recordedIdentity,
               !isRemoteTerminal,
               Self.agentPIDProcessIdentity(pid: pid) != recordedIdentity {
                let statusKey = agentStatusKey(forAgentPIDKey: key)
                rejectedStatusKeys.insert(statusKey)
                _ = sidebarAgentRuntimeObservation.recordAgentProcessExit(
                    key: statusKey,
                    panelId: runtimeState.panelId,
                    generation: recordedIdentity
                )
                statusEntries.removeValue(forKey: statusKey)
                continue
            }
            recordAgentPID(
                key: key,
                pid: pid,
                panelId: runtimeState.panelId,
                processIdentity: recordedIdentity,
                refreshPorts: false,
                observeProcessExit: !isRemoteTerminal
            )
            didAdoptAgentPID = true
        }
        for key in runtimeState.agentPIDKeys where runtimeState.agentPIDs[key] == nil {
            recordAgentPIDOwnership(key: key, panelId: runtimeState.panelId)
        }
        if !hasReconciliationEvidence {
            for (key, lifecycle) in runtimeState.agentLifecycleStates
            where !rejectedStatusKeys.contains(key) {
                setAgentLifecycle(
                    key: key,
                    panelId: runtimeState.panelId,
                    lifecycle: lifecycle
                )
            }
        }
        if didAdoptAgentPID {
            refreshTrackedAgentPorts()
        }
    }

    /// Discard every Workspace-owned contribution for a surface whose tab,
    /// pane, or workspace has already been accepted for closure.
    @discardableResult
}
