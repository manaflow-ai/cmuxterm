import Bonsplit
import CmuxSettings
import CmuxCore
import Darwin
import Foundation
import CmuxSidebar

extension Workspace {
    static let structuredAgentHookStatusKeys = AgentHibernationLifecycleStatusKeys.allowedStatusKeys
    static let managedSubagentEnvironmentKey = "CMUX_AGENT_MANAGED_SUBAGENT"
    static let truthyStartupEnvironmentValues: Set<String> = ["1", "true", "yes", "on", "enabled"]

    var agentPIDs: [String: pid_t] {
        get { sidebarAgentRuntimeObservation.agentPIDs }
        set { sidebarAgentRuntimeObservation.setAgentPIDs(newValue) }
    }

    var agentPIDProcessIdentitiesByKey: [String: AgentPIDProcessIdentity] {
        get { sidebarAgentRuntimeObservation.agentPIDProcessIdentitiesByKey }
        set { sidebarAgentRuntimeObservation.setAgentPIDProcessIdentitiesByKey(newValue) }
    }

    var agentPIDPanelIdsByKey: [String: UUID] {
        get { sidebarAgentRuntimeObservation.agentPIDPanelIdsByKey }
        set { sidebarAgentRuntimeObservation.setAgentPIDPanelIdsByKey(newValue) }
    }

    var agentPIDKeysByPanelId: [UUID: Set<String>] {
        get { sidebarAgentRuntimeObservation.agentPIDKeysByPanelId }
        set { sidebarAgentRuntimeObservation.setAgentPIDKeysByPanelId(newValue) }
    }

    var agentLifecycleStatesByPanelId: [UUID: [String: AgentHibernationLifecycleState]] {
        sidebarAgentRuntimeObservation.agentLifecycleStatesByPanelId
    }

    func agentRuntimeState(forPanelId panelId: UUID) -> DetachedAgentRuntimeState? {
        let pidKeys = agentPIDKeysByPanelId[panelId] ?? []
        let lifecycleStates = (agentLifecycleStatesByPanelId[panelId] ?? [:]).filter {
            !AgentHibernationLifecycleStatusKeys(rawValue: $0.key).isManual
        }
        let reconciliationState =
            sidebarAgentRuntimeObservation
                .transferableAgentLifecycleReconciliationSnapshot(
                    for: panelId
                )

        var agentPIDsForPanel: [String: pid_t] = [:]
        var agentPIDIdentitiesForPanel: [String: AgentPIDProcessIdentity] = [:]
        var statusEntriesForPanel: [String: SidebarStatusEntry] = [:]
        for key in pidKeys {
            if let pid = agentPIDs[key] {
                agentPIDsForPanel[key] = pid
                agentPIDIdentitiesForPanel[key] = agentPIDProcessIdentitiesByKey[key]
            }
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            if let statusEntry = statusEntries[statusKey] {
                statusEntriesForPanel[statusKey] = statusEntry
            }
        }
        for statusKey in lifecycleStates.keys {
            if let statusEntry = statusEntries[statusKey] {
                statusEntriesForPanel[statusKey] = statusEntry
            }
        }
        guard !statusEntriesForPanel.isEmpty
                || !agentPIDsForPanel.isEmpty
                || !pidKeys.isEmpty
                || !lifecycleStates.isEmpty
                || reconciliationState.hasEvidence else {
            return nil
        }
        return DetachedAgentRuntimeState(
            panelId: panelId,
            statusEntries: statusEntriesForPanel,
            agentPIDs: agentPIDsForPanel,
            agentPIDProcessIdentities: agentPIDIdentitiesForPanel,
            agentPIDKeys: pidKeys,
            agentLifecycleStates: lifecycleStates,
            agentLifecycleReconciliationState: reconciliationState
        )
    }

    func agentStatusKey(forAgentPIDKey key: String) -> String {
        if statusEntries[key] != nil {
            return key
        }
        guard let dotIndex = key.firstIndex(of: ".") else {
            return key
        }
        return String(key[..<dotIndex])
    }

    /// Built-in lifecycle socket evidence is accepted only while at least one
    /// exact process generation for that status key still owns this panel.
    /// This prevents a standalone or delayed `set_agent_lifecycle` command
    /// from manufacturing a pill after its emitting process has exited.
    func hasLiveAgentProcess(
        statusKey: String,
        panelId: UUID,
        matching requiredGeneration: AgentPIDProcessIdentity? = nil
    ) -> Bool {
        (agentPIDKeysByPanelId[panelId] ?? []).contains { pidKey in
            guard agentStatusKey(forAgentPIDKey: pidKey) == statusKey,
                  let pid = agentPIDs[pidKey],
                  let recordedIdentity =
                    agentPIDProcessIdentitiesByKey[pidKey],
                  recordedIdentity.pid == pid,
                  requiredGeneration == nil
                    || recordedIdentity == requiredGeneration else {
                return false
            }
            return Self.agentPIDProcessIdentity(pid: pid)
                == recordedIdentity
        }
    }

    /// Checks a workspace-scoped PID registration that intentionally has no
    /// panel association. This is the companion to the panel-scoped query
    /// above; lifecycle commands that omit `--panel` must still be able to
    /// validate their exact process generation.
    func hasLiveWorkspaceAgentProcess(
        statusKey: String,
        matching requiredGeneration: AgentPIDProcessIdentity? = nil
    ) -> Bool {
        agentPIDs.contains { key, pid in
            guard agentPIDPanelIdsByKey[key] == nil,
                  agentStatusKey(forAgentPIDKey: key) == statusKey,
                  let recordedIdentity = agentPIDProcessIdentitiesByKey[key],
                  recordedIdentity.pid == pid,
                  requiredGeneration == nil
                    || recordedIdentity == requiredGeneration else {
                return false
            }
            return Self.agentPIDProcessIdentity(pid: pid)
                == recordedIdentity
        }
    }

    func hasAgentRuntime(
        forStatusKey statusKey: String,
        excluding excludedKey: String? = nil
    ) -> Bool {
        for key in agentPIDs.keys
        where key != excludedKey
            && agentStatusKey(forAgentPIDKey: key) == statusKey {
            return true
        }
        for key in agentPIDPanelIdsByKey.keys
        where key != excludedKey
            && agentStatusKey(forAgentPIDKey: key) == statusKey {
            return true
        }
        if agentLifecycleStatesByPanelId.values.contains(where: {
            $0[statusKey] == .needsInput
        }) {
            return true
        }
        return false
    }

    func removeAgentPIDOwnership(key: String) {
        if let previousPanelId = agentPIDPanelIdsByKey[key] {
            agentPIDKeysByPanelId[previousPanelId]?.remove(key)
            if agentPIDKeysByPanelId[previousPanelId]?.isEmpty == true {
                agentPIDKeysByPanelId.removeValue(forKey: previousPanelId)
            }
            agentPIDPanelIdsByKey.removeValue(forKey: key)
        }
    }

    func recordAgentPIDOwnership(key: String, panelId: UUID) {
        if let previousPanelId = agentPIDPanelIdsByKey[key], previousPanelId != panelId {
            removeAgentPIDOwnership(key: key)
        }
        if isStructuredAgentHookPIDKey(key) {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            let stalePanelKeys = agentPIDKeysByPanelId[panelId]?.filter {
                $0 != key &&
                isStructuredAgentHookPIDKey($0) &&
                agentStatusKey(forAgentPIDKey: $0) != statusKey
            } ?? []
            for staleKey in stalePanelKeys {
                _ = clearAgentPID(key: staleKey, panelId: panelId, clearStatus: true, refreshPorts: false)
            }
        }
        agentPIDPanelIdsByKey[key] = panelId
        agentPIDKeysByPanelId[panelId, default: []].insert(key)
    }

    @discardableResult
    private func clearOtherStructuredAgentRuntimes(
        onPanel panelId: UUID,
        keeping retainedKey: String,
        processGeneration retainedGeneration: AgentPIDProcessIdentity?
    ) -> Bool {
        guard isStructuredAgentHookPIDKey(retainedKey) else { return false }
        let retainedStatusKey = agentStatusKey(forAgentPIDKey: retainedKey)
        let staleKeys = agentPIDKeysByPanelId[panelId] ?? []
        var didChange = false
        for staleKey in staleKeys where staleKey != retainedKey && isStructuredAgentHookPIDKey(staleKey) {
            if agentStatusKey(forAgentPIDKey: staleKey) == retainedStatusKey,
               let retainedGeneration,
               agentPIDProcessIdentitiesByKey[staleKey]
                    == retainedGeneration {
                continue
            }
            if clearAgentPID(key: staleKey, panelId: panelId, clearStatus: true, refreshPorts: false) {
                didChange = true
            }
        }
        return didChange
    }
    @discardableResult
    func recordAgentPID(
        key: String,
        pid: pid_t,
        panelId: UUID?,
        processIdentity providedProcessIdentity:
            AgentPIDProcessIdentity? = nil,
        refreshPorts: Bool = true,
        observeProcessExit: Bool = true
    ) -> Bool {
        recordAgentPIDResult(
            key: key,
            pid: pid,
            panelId: panelId,
            processIdentity: providedProcessIdentity,
            refreshPorts: refreshPorts,
            observeProcessExit: observeProcessExit
        ).replacedOtherRuntime
    }

    /// Admits an exact process generation before replacing any runtime owner.
    func recordAgentPIDResult(
        key: String,
        pid: pid_t,
        panelId: UUID?,
        processIdentity providedProcessIdentity:
            AgentPIDProcessIdentity? = nil,
        refreshPorts: Bool = true,
        observeProcessExit: Bool = true
    ) -> (accepted: Bool, replacedOtherRuntime: Bool) {
        let previous = (
            panelId: agentPIDPanelIdsByKey[key],
            pid: agentPIDs[key],
            identity: agentPIDProcessIdentitiesByKey[key]
        )
        let processIdentity =
            providedProcessIdentity
                ?? Self.agentPIDProcessIdentity(pid: pid)
        if let processIdentity,
           previous.panelId == panelId,
           previous.pid == pid,
           previous.identity == processIdentity {
            return (accepted: true, replacedOtherRuntime: false)
        }
        if let processIdentity,
           let previousIdentity = previous.identity,
           processIdentity < previousIdentity {
            return (accepted: false, replacedOtherRuntime: false)
        }
        if let panelId, let processIdentity {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard sidebarAgentRuntimeObservation.recordAgentProcessGeneration(
                key: statusKey,
                panelId: panelId,
                generation: processIdentity,
                isBuiltIn: AgentHibernationLifecycleStatusKeys(
                    rawValue: statusKey
                ).isAllowed
            ) else {
                return (accepted: false, replacedOtherRuntime: false)
            }
        }
        let replacesProcessGeneration =
            previous.identity != nil
                && previous.identity != processIdentity
        if let previousPanelId = previous.panelId,
           let previousIdentity = previous.identity,
           previousPanelId != panelId || replacesProcessGeneration {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            if sidebarAgentRuntimeObservation.recordAgentProcessExit(
                key: statusKey,
                panelId: previousPanelId,
                generation: previousIdentity
            ) {
                AgentHibernationController.shared.recordAgentLifecycleChange(
                    workspaceId: id,
                    panelId: previousPanelId
                )
            }
        }
        if replacesProcessGeneration {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            if !hasAgentRuntime(
                forStatusKey: statusKey,
                excluding: key
            ) {
                statusEntries.removeValue(forKey: statusKey)
            }
            if let previousPanelId = previous.panelId {
                AppDelegate.shared?.notificationStore?.clearNotifications(
                    forTabId: id,
                    surfaceId: previousPanelId
                )
            }
        }
        var didClearOtherStructuredAgentRuntime = false
        if let panelId {
            didClearOtherStructuredAgentRuntime =
                clearOtherStructuredAgentRuntimes(
                    onPanel: panelId,
                    keeping: key,
                    processGeneration: processIdentity
                )
        }
        agentPIDs[key] = pid
        if let processIdentity {
            agentPIDProcessIdentitiesByKey[key] = processIdentity
        } else {
            agentPIDProcessIdentitiesByKey.removeValue(forKey: key)
        }
        if let panelId { recordAgentPIDOwnership(key: key, panelId: panelId) } else { removeAgentPIDOwnership(key: key) }
        sidebarAgentRuntimeObservation.cancelAgentProcessExitObservation(key: key)
        if observeProcessExit, panelId != nil, let processIdentity {
            sidebarAgentRuntimeObservation.observeAgentProcessExit(
                key: key,
                generation: processIdentity
            ) { [weak self] key, generation in
                self?.handleObservedAgentProcessExit(
                    key: key,
                    generation: generation
                )
            }
        }
        if previous.pid != pid || previous.panelId != panelId || previous.identity != processIdentity {
            for changedPanelId in (previous.panelId == panelId ? [panelId] : [previous.panelId, panelId]).compactMap({ $0 }) {
                AgentHibernationController.shared.recordAgentProcessChange(workspaceId: id, panelId: changedPanelId)
            }
        }
        if refreshPorts { refreshTrackedAgentPorts() }
        return (
            accepted: true,
            replacedOtherRuntime: didClearOtherStructuredAgentRuntime
        )
    }

    @discardableResult
    func clearStaleAgentPIDs(refreshPorts: Bool = true) -> Bool {
        var didChange = false
        for (key, pid) in agentPIDs where !isRecordedAgentPIDLive(key: key, pid: pid) {
            if clearAgentPID(
                key: key,
                clearStatus: true,
                refreshPorts: false,
                definitiveProcessExit: true
            ) {
                didChange = true
            }
        }
        if didChange {
            if refreshPorts { refreshTrackedAgentPorts() }
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id)
        }
        return didChange
    }

    @discardableResult
    func clearStaleAgentPIDs(panelId: UUID, refreshPorts: Bool = true) -> Bool {
        let keys = agentPIDKeysByPanelId[panelId] ?? []
        var didChange = false
        for key in keys {
            guard let pid = agentPIDs[key] else {
                if clearAgentPID(
                    key: key,
                    panelId: panelId,
                    clearStatus: true,
                    refreshPorts: false,
                    definitiveProcessExit: true
                ) {
                    didChange = true
                }
                continue
            }
            if !isRecordedAgentPIDLive(key: key, pid: pid),
               clearAgentPID(
                   key: key,
                   panelId: panelId,
                   clearStatus: true,
                   refreshPorts: false,
                   definitiveProcessExit: true
               ) {
                didChange = true
            }
        }
        if didChange {
            if refreshPorts { refreshTrackedAgentPorts() }
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id, surfaceId: panelId)
        }
        return didChange
    }

    func clearAllAgentPIDs(refreshPorts: Bool = true) {
        sidebarAgentRuntimeObservation.cancelAllAgentProcessExitObservations()
        agentPIDs.removeAll()
        agentPIDProcessIdentitiesByKey.removeAll()
        agentPIDPanelIdsByKey.removeAll()
        agentPIDKeysByPanelId.removeAll()
        if refreshPorts {
            refreshTrackedAgentPorts()
        } else {
            agentListeningPorts.removeAll()
            recomputeListeningPorts()
            PortScanner.shared.unregisterAgentWorkspace(workspaceId: id)
        }
    }

    private func isRecordedAgentPIDLive(key: String, pid: pid_t) -> Bool {
        guard pid > 0,
              let recordedIdentity = agentPIDProcessIdentitiesByKey[key],
              let currentIdentity = Self.agentPIDProcessIdentity(pid: pid) else {
            return false
        }
        return currentIdentity == recordedIdentity
    }

    private func handleObservedAgentProcessExit(
        key: String,
        generation: AgentPIDProcessIdentity
    ) {
        guard agentPIDs[key] == generation.pid,
              agentPIDProcessIdentitiesByKey[key] == generation else {
            return
        }
        let panelId = agentPIDPanelIdsByKey[key]
        guard clearAgentPID(
            key: key,
            panelId: panelId,
            clearStatus: true,
            refreshPorts: true,
            definitiveProcessExit: true
        ) else {
            return
        }
        guard let panelId else { return }
        AppDelegate.shared?.notificationStore?.clearNotifications(
            forTabId: id,
            surfaceId: panelId
        )
    }

    /// Reads the identity the port scanner and session restore compare against.
    ///
    /// Delegates rather than reading the process table itself: a second reader
    /// with different privilege behavior would record `nil` identities for
    /// agents running under another euid, which `PortScanner.validateAgentRoots`
    /// treats as permanently incomplete evidence.
    static func agentPIDProcessIdentity(pid: pid_t) -> AgentPIDProcessIdentity? {
        AgentPIDProcessIdentity(pid: pid)
    }

}
