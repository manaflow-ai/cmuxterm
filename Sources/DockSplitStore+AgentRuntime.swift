import CmuxNotifications
import CmuxSidebar
import CmuxWorkspaces
import Darwin
import AppKit
import Foundation

extension DockSplitStore {
    /// Looks up the pane-owned sidebar row without changing its runtime state.
    func agentRuntimeStatusEntry(key: String, panelId: UUID) -> SidebarStatusEntry? {
        agentRuntimeByPanelId[panelId]?.statusEntries[key]
    }

    func setAgentRuntimeStatusEntry(
        _ entry: SidebarStatusEntry,
        key: String,
        panelId: UUID
    ) {
        mutateAgentRuntime(panelId: panelId) { runtime in
            runtime.statusEntries[key] = entry
        }
    }

    @discardableResult
    func upsertAgentRuntimeStatusEntry(
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: SidebarMetadataFormat,
        panelId: UUID,
        pid: pid_t?,
        agentEventTime: TimeInterval?,
        enforceAgentEventOrdering: Bool = true
    ) -> SidebarStatusEntryReplacementDecision {
        var replacementDecision: SidebarStatusEntryReplacementDecision = .stale
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) { runtime in
            let hasLifecycleWatermark = runtime.agentLifecycleEventTimes[key] != nil
            let effectiveAgentEventTime = agentEventTime
                ?? (enforceAgentEventOrdering ? nil : runtime.statusEntries[key]?.agentEventTime)
            guard Self.acceptAgentRuntimeMutation(
                statusKey: key,
                agentEventTime: agentEventTime,
                enforceOrdering: enforceAgentEventOrdering
                    && (agentEventTime != nil || hasLifecycleWatermark),
                runtime: &runtime
            ) else {
                return
            }
            replacementDecision = SidebarStatusEntry.replacementDecision(
                current: runtime.statusEntries[key],
                key: key, value: value, icon: icon, color: color, url: url,
                priority: priority, format: format,
                agentEventTime: effectiveAgentEventTime,
                agentOwnerPanelID: panelId
            )
            if replacementDecision == .replace {
                runtime.statusEntries[key] = SidebarStatusEntry(
                    key: key, value: value, icon: icon, color: color, url: url,
                    priority: priority, format: format, timestamp: .now,
                    agentEventTime: effectiveAgentEventTime,
                    agentOwnerPanelID: panelId
                )
            }
        }
        if replacementDecision != .stale, let pid {
            _ = recordAgentPID(
                key: key, pid: pid, panelId: panelId,
                agentEventTime: agentEventTime,
                enforceAgentEventOrdering: enforceAgentEventOrdering && agentEventTime != nil
            )
        }
        return replacementDecision
    }

    func clearAgentRuntimeStatusEntry(key: String, panelId: UUID) {
        mutateAgentRuntime(panelId: panelId) {
            $0.statusEntries.removeValue(forKey: key)
        }
    }

    @discardableResult
    func recordAgentPID(
        key: String,
        pid: pid_t,
        panelId: UUID,
        agentEventTime: TimeInterval? = nil,
        enforceAgentEventOrdering: Bool = false
    ) -> Bool {
        var didReplaceRuntime = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) { runtime in
            let statusKey = Self.agentStatusKey(forAgentPIDKey: key, runtime: runtime)
            guard Self.acceptAgentRuntimeMutation(
                statusKey: statusKey,
                agentEventTime: agentEventTime,
                enforceOrdering: enforceAgentEventOrdering,
                runtime: &runtime
            ) else {
                return
            }
            if Self.isStructuredAgentHookPIDKey(key, runtime: runtime) {
                let staleKeys = runtime.agentPIDKeys.filter {
                    $0 != key && Self.isStructuredAgentHookPIDKey($0, runtime: runtime)
                }
                for staleKey in staleKeys {
                    Self.clearAgentPID(key: staleKey, clearStatus: true, runtime: &runtime)
                }
                didReplaceRuntime = !staleKeys.isEmpty
            }
            runtime.agentPIDs[key] = pid
            if let identity = Workspace.agentPIDProcessIdentity(pid: pid) {
                runtime.agentPIDProcessIdentities[key] = identity
            } else {
                runtime.agentPIDProcessIdentities.removeValue(forKey: key)
            }
            runtime.agentPIDKeys.insert(key)
        }
        return didReplaceRuntime
    }

    @discardableResult
    func setAgentLifecycle(
        key: String,
        panelId: UUID,
        lifecycle: AgentHibernationLifecycleState,
        agentEventTime: TimeInterval? = nil,
        enforceAgentEventOrdering: Bool = false
    ) -> Bool {
        var didSet = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) { runtime in
            guard Self.acceptAgentRuntimeMutation(
                statusKey: key,
                agentEventTime: agentEventTime,
                enforceOrdering: enforceAgentEventOrdering || agentEventTime != nil,
                isLifecycleMutation: true,
                runtime: &runtime
            ) else {
                return
            }
            runtime.agentLifecycleStates[key] = lifecycle
            if let agentEventTime {
                runtime.agentLifecycleEventTimes[key] = agentEventTime
            }
            didSet = true
        }
        return didSet
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
    func clearAgentLifecycle(key: String, panelId: UUID) -> Bool {
        var didClear = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            didClear = $0.agentLifecycleStates.removeValue(forKey: key) != nil
        }
        return didClear
    }

    @discardableResult
    func clearAgentPID(
        key: String,
        panelId: UUID,
        clearStatus: Bool,
        requireOwnedKey: Bool = false,
        agentEventTime: TimeInterval? = nil,
        enforceAgentEventOrdering: Bool = false
    ) -> Bool {
        if requireOwnedKey,
           agentRuntimeByPanelId[panelId]?.agentPIDKeys.contains(key) != true {
            return false
        }
        var didChange = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) { runtime in
            let statusKey = Self.agentStatusKey(forAgentPIDKey: key, runtime: runtime)
            guard Self.acceptAgentRuntimeMutation(
                statusKey: statusKey,
                agentEventTime: agentEventTime,
                enforceOrdering: enforceAgentEventOrdering,
                runtime: &runtime
            ) else {
                return
            }
            didChange = Self.clearAgentPID(
                key: key,
                clearStatus: clearStatus,
                runtime: &runtime
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
        mutation(&runtime)
        let shouldKeep = !runtime.statusEntries.isEmpty
            || !runtime.agentPIDs.isEmpty
            || !runtime.agentPIDKeys.isEmpty
            || !runtime.agentLifecycleStates.isEmpty
            || !runtime.agentLifecycleEventTimes.isEmpty
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
            syncAgentNeedsInputAttention(
                panelId: panelId,
                runtime: shouldKeep ? runtime : nil
            )
        }
    }

    func syncAgentNeedsInputAttention(
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
        runtime: inout Workspace.DetachedAgentRuntimeState
    ) -> Bool {
        let statusKey = agentStatusKey(forAgentPIDKey: key, runtime: runtime)
        var didChange = false
        if runtime.agentPIDs.removeValue(forKey: key) != nil { didChange = true }
        if runtime.agentPIDProcessIdentities.removeValue(forKey: key) != nil { didChange = true }
        if runtime.agentPIDKeys.remove(key) != nil { didChange = true }
        if runtime.agentLifecycleStates.removeValue(forKey: statusKey) != nil {
            didChange = true
        }
        if clearStatus,
           !runtime.agentPIDKeys.contains(where: {
               agentStatusKey(forAgentPIDKey: $0, runtime: runtime) == statusKey
           }),
           runtime.statusEntries.removeValue(forKey: statusKey) != nil {
            didChange = true
        }
        return didChange
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
        if runtime.statusEntries[key] != nil {
            return key
        }
        guard let dotIndex = key.firstIndex(of: ".") else {
            return key
        }
        return String(key[..<dotIndex])
    }

    @discardableResult
    func acceptAgentRuntimeMutation(
        statusKey: String,
        panelId: UUID,
        agentEventTime: TimeInterval?,
        enforceOrdering: Bool,
        isLifecycleMutation: Bool = false
    ) -> Bool {
        var isAccepted = false
        mutateAgentRuntime(panelId: panelId) { runtime in
            isAccepted = Self.acceptAgentRuntimeMutation(
                statusKey: statusKey,
                agentEventTime: agentEventTime,
                enforceOrdering: enforceOrdering,
                isLifecycleMutation: isLifecycleMutation,
                runtime: &runtime
            )
        }
        return isAccepted
    }

    private static func acceptAgentRuntimeMutation(
        statusKey: String,
        agentEventTime: TimeInterval?,
        enforceOrdering: Bool,
        isLifecycleMutation: Bool = false,
        runtime: inout Workspace.DetachedAgentRuntimeState
    ) -> Bool {
        let replacementWatermark: TimeInterval?
        if AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey) {
            let lifecycleWatermarks = runtime.agentLifecycleEventTimes.compactMap { entry in
                entry.key != statusKey && AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(entry.key)
                    ? entry.value : nil
            }
            let statusWatermarks = runtime.statusEntries.compactMap { entry -> TimeInterval? in
                entry.key != statusKey && AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(entry.key)
                    ? entry.value.agentEventTime : nil
            }
            replacementWatermark = (lifecycleWatermarks + statusWatermarks).max()
        } else {
            replacementWatermark = nil
        }
        let decision = AgentRuntimeMutationOrdering.decision(
            statusKey: statusKey,
            lifecycleEventTime: runtime.agentLifecycleEventTimes[statusKey],
            statusEventTime: runtime.statusEntries[statusKey]?.agentEventTime,
            replacementWatermark: replacementWatermark,
            hasLifecycleState: runtime.agentLifecycleStates[statusKey] != nil,
            agentEventTime: agentEventTime,
            enforceOrdering: enforceOrdering,
            isLifecycleMutation: isLifecycleMutation
        )
        guard decision.isAccepted else { return false }
        if let retainedEventTime = decision.retainedEventTime,
           retainedEventTime > (runtime.agentLifecycleEventTimes[statusKey] ?? -Double.infinity) {
            runtime.agentLifecycleEventTimes[statusKey] = retainedEventTime
        }
        return true
    }
}
