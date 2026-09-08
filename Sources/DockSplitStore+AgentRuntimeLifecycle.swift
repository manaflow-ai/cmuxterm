import CmuxNotifications
import CmuxSidebar
import CmuxWorkspaces
import Darwin
import Foundation

extension DockSplitStore {
    func agentRuntimeStatusEntry(key: String, panelId: UUID) -> SidebarStatusEntry? {
        agentRuntimeByPanelId[panelId]?.statusEntries[key]
    }

    func agentRuntimeLifecycleState(
        key: String,
        panelId: UUID
    ) -> AgentHibernationLifecycleState? {
        agentRuntimeByPanelId[panelId]?.agentLifecycleStates[key]
    }

    func setAgentRuntimeStatusEntry(
        _ entry: SidebarStatusEntry,
        key: String,
        panelId: UUID
    ) {
        mutateAgentRuntime(panelId: panelId) { $0.statusEntries[key] = entry }
    }

    func clearAgentRuntimeStatusEntry(key: String, panelId: UUID) {
        mutateAgentRuntime(panelId: panelId) { $0.statusEntries.removeValue(forKey: key) }
    }
    func hasLiveAgentProcess(
        statusKey: String,
        panelId: UUID,
        matching requiredGeneration: AgentPIDProcessIdentity? = nil
    ) -> Bool {
        guard let runtime = agentRuntimeByPanelId[panelId] else { return false }
        return runtime.agentPIDKeys.contains { pidKey in
            guard Self.agentStatusKey(forAgentPIDKey: pidKey, runtime: runtime) == statusKey,
                  let pid = runtime.agentPIDs[pidKey],
                  let recordedIdentity = runtime.agentPIDProcessIdentities[pidKey],
                  recordedIdentity.pid == pid,
                  requiredGeneration == nil || recordedIdentity == requiredGeneration else {
                return false
            }
            return Workspace.agentPIDProcessIdentity(pid: pid) == recordedIdentity
        }
    }

    func agentHibernationLifecycleState(
        panelId: UUID,
        fallback: AgentHibernationLifecycleState?
    ) -> AgentHibernationLifecycleState {
        AgentHibernationLifecycleState.aggregate(
            statusKeyedStates: agentRuntimeByPanelId[panelId]?.agentLifecycleStates ?? [:],
            fallback: fallback
        )
    }

    func agentLifecycleStateForTextBoxEscape(panelId: UUID) -> AgentHibernationLifecycleState {
        AgentHibernationLifecycleState.aggregateForTextBoxEscape(
            statusKeyedStates: agentRuntimeByPanelId[panelId]?.agentLifecycleStates ?? [:]
        )
    }

    @discardableResult
    func recordAgentPID(
        key: String,
        pid: pid_t,
        panelId: UUID,
        processIdentity providedProcessIdentity: AgentPIDProcessIdentity? = nil,
        observeProcessExit: Bool = true
    ) -> Bool {
        recordAgentPIDResult(
            key: key,
            pid: pid,
            panelId: panelId,
            processIdentity: providedProcessIdentity,
            observeProcessExit: observeProcessExit
        ).replacedOtherRuntime
    }

    /// Admits an exact process generation before replacing any Dock runtime.
    func recordAgentPIDResult(
        key: String,
        pid: pid_t,
        panelId: UUID,
        processIdentity providedProcessIdentity: AgentPIDProcessIdentity? = nil,
        observeProcessExit: Bool = true
    ) -> (accepted: Bool, replacedOtherRuntime: Bool) {
        var didReplaceRuntime = false
        var didReplaceProcessGeneration = false
        var accepted = false
        let processIdentity = providedProcessIdentity ?? Workspace.agentPIDProcessIdentity(pid: pid)
        if let processIdentity,
           let runtime = agentRuntimeByPanelId[panelId],
           runtime.agentPIDs[key] == pid,
           runtime.agentPIDProcessIdentities[key] == processIdentity,
           runtime.agentPIDKeys.contains(key) {
            return (accepted: true, replacedOtherRuntime: false)
        }
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) { runtime in
            let statusKey = Self.agentStatusKey(forAgentPIDKey: key, runtime: runtime)
            if let processIdentity {
                if let previousGeneration = runtime.agentPIDProcessIdentities[key],
                   processIdentity < previousGeneration {
                    return
                }
                guard runtime.agentLifecycleReconciliationState.recordProcessGeneration(
                    key: statusKey,
                    panelId: panelId,
                    generation: processIdentity,
                    isBuiltIn: AgentHibernationLifecycleStatusKeys(rawValue: statusKey).isAllowed
                ) else {
                    return
                }
            }
            accepted = true
            if let previousGeneration = runtime.agentPIDProcessIdentities[key],
               previousGeneration != processIdentity {
                didReplaceProcessGeneration = true
                _ = runtime.agentLifecycleReconciliationState.recordProcessExit(
                    key: statusKey,
                    panelId: panelId,
                    generation: previousGeneration
                )
                let hasOtherRuntime = runtime.agentPIDKeys.contains {
                    $0 != key && Self.agentStatusKey(forAgentPIDKey: $0, runtime: runtime) == statusKey
                }
                if !hasOtherRuntime { runtime.statusEntries.removeValue(forKey: statusKey) }
            }
            if Self.isStructuredAgentHookPIDKey(key, runtime: runtime) {
                let staleKeys = runtime.agentPIDKeys.filter {
                    guard $0 != key, Self.isStructuredAgentHookPIDKey($0, runtime: runtime) else {
                        return false
                    }
                    return Self.agentStatusKey(forAgentPIDKey: $0, runtime: runtime) != statusKey
                        || processIdentity == nil
                        || runtime.agentPIDProcessIdentities[$0] != processIdentity
                }
                for staleKey in staleKeys {
                    agentProcessExitMonitor.cancel(
                        key: Self.agentProcessObservationKey(key: staleKey, panelId: panelId)
                    )
                    Self.clearAgentPID(
                        key: staleKey,
                        clearStatus: true,
                        definitiveProcessExit: false,
                        runtime: &runtime
                    )
                }
                didReplaceRuntime = !staleKeys.isEmpty
            }
            runtime.agentPIDs[key] = pid
            if let processIdentity {
                runtime.agentPIDProcessIdentities[key] = processIdentity
            } else {
                runtime.agentPIDProcessIdentities.removeValue(forKey: key)
            }
            runtime.agentPIDKeys.insert(key)
        }
        guard accepted else { return (accepted: false, replacedOtherRuntime: false) }
        if !observeProcessExit {
            agentProcessExitMonitor.cancel(
                key: Self.agentProcessObservationKey(key: key, panelId: panelId)
            )
        }
        if observeProcessExit {
            agentProcessExitMonitor.cancel(
                key: Self.agentProcessObservationKey(key: key, panelId: panelId)
            )
            if let generation = agentRuntimeByPanelId[panelId]?.agentPIDProcessIdentities[key] {
                observeAgentProcessExit(key: key, panelId: panelId, generation: generation)
            }
        }
        if didReplaceProcessGeneration {
            TerminalNotificationStore.shared.clearNotifications(
                forTabId: workspaceId,
                surfaceId: panelId
            )
        }
        return (accepted: true, replacedOtherRuntime: didReplaceRuntime)
    }

    @discardableResult
    func setAgentLifecycle(
        key: String,
        panelId: UUID,
        lifecycle: AgentHibernationLifecycleState,
        processGeneration: AgentPIDProcessIdentity? = nil
    ) -> Bool {
        var accepted = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            accepted = $0.agentLifecycleReconciliationState.setHookLifecycle(
                key: key,
                panelId: panelId,
                lifecycle: lifecycle,
                isBuiltIn: AgentHibernationLifecycleStatusKeys(rawValue: key).isAllowed,
                processGeneration: processGeneration
            )
        }
        return accepted
    }

    @discardableResult
    func clearAgentLifecycle(key: String, panelId: UUID) -> Bool {
        var removed = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            removed = $0.agentLifecycleReconciliationState.removeHook(key: key, panelId: panelId)
        }
        if removed, !AgentHibernationLifecycleStatusKeys(rawValue: key).isManual {
            AgentHibernationController.shared.recordAgentLifecycleChange(
                workspaceId: workspaceId,
                panelId: panelId
            )
        }
        return removed
    }

    func beginAgentFeedAttention(
        key: String,
        panelId: UUID,
        processGeneration: AgentPIDProcessIdentity? = nil
    ) -> AgentFeedAttentionToken? {
        var token: AgentFeedAttentionToken?
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            token = $0.agentLifecycleReconciliationState.beginFeedAttention(
                key: key,
                panelId: panelId,
                isBuiltIn: AgentHibernationLifecycleStatusKeys(rawValue: key).isAllowed,
                processGeneration: processGeneration
            )
        }
        return token
    }

    @discardableResult
    func endAgentFeedAttention(
        key: String,
        panelId: UUID,
        token: AgentFeedAttentionToken
    ) -> Bool {
        var ended = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            ended = $0.agentLifecycleReconciliationState.endFeedAttention(
                key: key,
                panelId: panelId,
                token: token
            )
        }
        return ended
    }

    @discardableResult
    func recordUnidentifiedAgentProcessExit(key: String, panelId: UUID) -> Bool {
        var recorded = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            recorded = $0.agentLifecycleReconciliationState.recordUnidentifiedProcessExit(
                key: key,
                panelId: panelId,
                isBuiltIn: AgentHibernationLifecycleStatusKeys(rawValue: key).isAllowed
            )
        }
        return recorded
    }

    @discardableResult
    func recordAgentProcessExit(
        key: String,
        panelId: UUID,
        generation: AgentPIDProcessIdentity
    ) -> Bool {
        var recorded = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            recorded = $0.agentLifecycleReconciliationState.recordProcessExit(
                key: key,
                panelId: panelId,
                generation: generation
            )
        }
        return recorded
    }

    @discardableResult
    func clearAgentPID(
        key: String,
        panelId: UUID,
        clearStatus: Bool,
        requireOwnedKey: Bool = false,
        definitiveProcessExit: Bool = false
    ) -> Bool {
        if requireOwnedKey,
           agentRuntimeByPanelId[panelId]?.agentPIDKeys.contains(key) != true {
            return false
        }
        agentProcessExitMonitor.cancel(
            key: Self.agentProcessObservationKey(key: key, panelId: panelId)
        )
        var didChange = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            didChange = Self.clearAgentPID(
                key: key,
                clearStatus: clearStatus,
                definitiveProcessExit: definitiveProcessExit,
                runtime: &$0
            )
        }
        return didChange
    }

    private func mutateAgentRuntime(
        panelId: UUID,
        updatesAgentAttention: Bool = false,
        mutation: (inout Workspace.DetachedAgentRuntimeState) -> Void
    ) {
        guard panels[panelId] != nil else { return }
        var runtime = agentRuntimeByPanelId[panelId] ?? Workspace.DetachedAgentRuntimeState(
            panelId: panelId,
            statusEntries: [:],
            agentPIDs: [:],
            agentPIDProcessIdentities: [:],
            agentPIDKeys: []
        )
        Self.seedAgentLifecycleReconciliationIfNeeded(runtime: &runtime, panelId: panelId)
        mutation(&runtime)
        runtime.agentLifecycleStates =
            runtime.agentLifecycleReconciliationState.resolvedStatesByPanelId[panelId] ?? [:]
        let shouldKeep = !runtime.statusEntries.isEmpty
            || !runtime.agentPIDs.isEmpty
            || !runtime.agentPIDKeys.isEmpty
            || !runtime.agentLifecycleStates.isEmpty
            || runtime.agentLifecycleReconciliationState.hasEvidence
        if shouldKeep {
            agentRuntimeByPanelId[panelId] = runtime
        } else {
            agentRuntimeByPanelId.removeValue(forKey: panelId)
        }
        if var transfer = detachedSurfaceTransfersByPanelId[panelId] {
            transfer.agentRuntime = shouldKeep ? runtime : nil
            detachedSurfaceTransfersByPanelId[panelId] = transfer
        }
        if updatesAgentAttention {
            syncAgentNeedsInputAttention(panelId: panelId, runtime: shouldKeep ? runtime : nil)
        }
    }

    private func syncAgentNeedsInputAttention(
        panelId: UUID,
        runtime: Workspace.DetachedAgentRuntimeState?
    ) {
        let needsInput = runtime?.agentLifecycleStates.values.contains(.needsInput) == true
        agentNeedsInputAttention.setAttention(needsInput, forSurfaceId: panelId)
    }

    @discardableResult
    private static func clearAgentPID(
        key: String,
        clearStatus: Bool,
        definitiveProcessExit: Bool,
        runtime: inout Workspace.DetachedAgentRuntimeState
    ) -> Bool {
        let statusKey = agentStatusKey(forAgentPIDKey: key, runtime: runtime)
        let generation = runtime.agentPIDProcessIdentities[key]
        let hadFeedAttention = runtime.agentLifecycleReconciliationState.hasFeedAttention(
            key: statusKey,
            panelId: runtime.panelId
        )
        var didChange = false
        if runtime.agentPIDs.removeValue(forKey: key) != nil { didChange = true }
        if runtime.agentPIDProcessIdentities.removeValue(forKey: key) != nil { didChange = true }
        if runtime.agentPIDKeys.remove(key) != nil { didChange = true }
        let hasRemainingStatusRuntime = runtime.agentPIDKeys.contains {
            agentStatusKey(forAgentPIDKey: $0, runtime: runtime) == statusKey
        }
        let hasRemainingGenerationOwner = generation.map { retainedGeneration in
            runtime.agentPIDKeys.contains {
                agentStatusKey(forAgentPIDKey: $0, runtime: runtime) == statusKey
                    && runtime.agentPIDProcessIdentities[$0] == retainedGeneration
            }
        } ?? false
        let didClearLifecycle: Bool
        if definitiveProcessExit, let generation, !hasRemainingGenerationOwner {
            didClearLifecycle = runtime.agentLifecycleReconciliationState.recordProcessExit(
                key: statusKey,
                panelId: runtime.panelId,
                generation: generation
            )
        } else if definitiveProcessExit,
                  AgentHibernationLifecycleStatusKeys(rawValue: statusKey).isAllowed,
                  !hasRemainingStatusRuntime {
            didClearLifecycle = runtime.agentLifecycleReconciliationState.recordUnidentifiedProcessExit(
                key: statusKey,
                panelId: runtime.panelId,
                isBuiltIn: true
            )
        } else if !hasRemainingStatusRuntime {
            didClearLifecycle = runtime.agentLifecycleReconciliationState.removeKey(
                key: statusKey,
                panelId: runtime.panelId
            )
        } else {
            didClearLifecycle = false
        }
        if didClearLifecycle { didChange = true }
        if clearStatus, runtime.statusEntries[statusKey] != nil {
            let feedAttentionStillVisible = runtime.agentLifecycleReconciliationState.hasFeedAttention(
                key: statusKey,
                panelId: runtime.panelId
            )
            if !hasRemainingStatusRuntime || (hadFeedAttention && !feedAttentionStillVisible) {
                runtime.statusEntries.removeValue(forKey: statusKey)
                didChange = true
            }
        }
        return didChange
    }

    private static func seedAgentLifecycleReconciliationIfNeeded(
        runtime: inout Workspace.DetachedAgentRuntimeState,
        panelId: UUID
    ) {
        guard !runtime.agentLifecycleReconciliationState.hasEvidence else { return }
        for (pidKey, generation) in runtime.agentPIDProcessIdentities {
            let statusKey = agentStatusKey(forAgentPIDKey: pidKey, runtime: runtime)
            runtime.agentLifecycleReconciliationState.recordProcessGeneration(
                key: statusKey,
                panelId: panelId,
                generation: generation,
                isBuiltIn: AgentHibernationLifecycleStatusKeys(rawValue: statusKey).isAllowed
            )
        }
        for (key, lifecycle) in runtime.agentLifecycleStates {
            _ = runtime.agentLifecycleReconciliationState.setHookLifecycle(
                key: key,
                panelId: panelId,
                lifecycle: lifecycle,
                isBuiltIn: AgentHibernationLifecycleStatusKeys(rawValue: key).isAllowed
            )
        }
    }

    private func handleObservedAgentProcessExit(
        key: String,
        panelId: UUID,
        generation: AgentPIDProcessIdentity
    ) {
        guard agentRuntimeByPanelId[panelId]?.agentPIDs[key] == generation.pid,
              agentRuntimeByPanelId[panelId]?.agentPIDProcessIdentities[key] == generation,
              clearAgentPID(
                  key: key,
                  panelId: panelId,
                  clearStatus: true,
                  definitiveProcessExit: true
              ) else {
            return
        }
        TerminalNotificationStore.shared.clearNotifications(
            forTabId: workspaceId,
            surfaceId: panelId
        )
    }

    private func observeAgentProcessExit(
        key: String,
        panelId: UUID,
        generation: AgentPIDProcessIdentity
    ) {
        agentProcessExitMonitor.observe(
            key: Self.agentProcessObservationKey(key: key, panelId: panelId),
            generation: generation
        ) { [weak self] _, generation in
            self?.handleObservedAgentProcessExit(
                key: key,
                panelId: panelId,
                generation: generation
            )
        }
    }

    private static func agentProcessObservationKey(key: String, panelId: UUID) -> String {
        "\(panelId.uuidString.lowercased()):\(key)"
    }

    private static func isStructuredAgentHookPIDKey(
        _ key: String,
        runtime: Workspace.DetachedAgentRuntimeState
    ) -> Bool {
        AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(
            agentStatusKey(forAgentPIDKey: key, runtime: runtime)
        )
    }

    private static func agentStatusKey(
        forAgentPIDKey key: String,
        runtime: Workspace.DetachedAgentRuntimeState
    ) -> String {
        if runtime.statusEntries[key] != nil { return key }
        guard let dotIndex = key.firstIndex(of: ".") else { return key }
        return String(key[..<dotIndex])
    }
}
