import Foundation


extension Workspace {
    @discardableResult
    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState,
        agentEventTime: TimeInterval? = nil,
        enforceAgentEventOrdering: Bool = false
    ) -> Bool {
        let targetPanelId = panelId ?? focusedPanelId
        guard let targetPanelId, panels[targetPanelId] != nil else { return false }
        guard acceptAgentRuntimeMutation(
            statusKey: key,
            panelId: targetPanelId,
            agentEventTime: agentEventTime,
            enforceOrdering: enforceAgentEventOrdering || agentEventTime != nil,
            isLifecycleMutation: true
        ) else { return false }
        agentLifecycleStatesByPanelId[targetPanelId, default: [:]][key] = lifecycle
        if let agentEventTime {
            agentLifecycleEventTimesByPanelId[targetPanelId, default: [:]][key] = agentEventTime
        }
        if !AgentHibernationLifecycleStatusKeys.isManualKey(key) {
            recordAgentLifecycleChange(panelId: targetPanelId)
        }
        return true
    }

    @discardableResult
    func clearAgentLifecycle(key: String, panelId: UUID? = nil) -> Bool {
        var didClear = false
        let recordsHibernationActivity = !AgentHibernationLifecycleStatusKeys.isManualKey(key)
        let panelIds = panelId.map { [$0] } ?? Array(agentLifecycleStatesByPanelId.keys)
        for panelId in panelIds {
            guard agentLifecycleStatesByPanelId[panelId]?[key] != nil else { continue }
            agentLifecycleStatesByPanelId[panelId]?.removeValue(forKey: key)
            if agentLifecycleStatesByPanelId[panelId]?.isEmpty == true {
                agentLifecycleStatesByPanelId.removeValue(forKey: panelId)
            }
            didClear = true
            if recordsHibernationActivity {
                recordAgentLifecycleChange(panelId: panelId)
            }
        }
        return didClear
    }

    func hasRunningAgentLifecycle(key: String, panelId: UUID? = nil) -> Bool {
        if let panelId {
            return agentLifecycleStatesByPanelId[panelId]?[key] == .running
        }
        return agentLifecycleStatesByPanelId.values.contains { $0[key] == .running }
    }

    func clearAgentLifecycleStates(panelId: UUID) {
        let removedEventTimes = agentLifecycleEventTimesByPanelId.removeValue(forKey: panelId) ?? [:]
        guard let removed = agentLifecycleStatesByPanelId.removeValue(forKey: panelId) else { return }
        let manualStates = removed.filter { AgentHibernationLifecycleStatusKeys.isManualKey($0.key) }
        if !manualStates.isEmpty {
            let host: UUID? = if panels[panelId] != nil {
                panelId
            } else if let focused = focusedPanelId, focused != panelId, panels[focused] != nil {
                focused
            } else {
                panels.keys.first(where: { $0 != panelId })
            }
            if let host {
                for (key, lifecycle) in manualStates {
                    agentLifecycleStatesByPanelId[host, default: [:]][key] = lifecycle
                    if let eventTime = removedEventTimes[key] {
                        agentLifecycleEventTimesByPanelId[host, default: [:]][key] = eventTime
                    }
                }
            }
        }
        recordAgentLifecycleChange(panelId: panelId)
    }

    func clearAllAgentLifecycleStates() {
        let panelIds = Set(agentLifecycleStatesByPanelId.keys).union(agentLifecycleEventTimesByPanelId.keys)
        guard !panelIds.isEmpty else { return }
        agentLifecycleStatesByPanelId.removeAll()
        agentLifecycleEventTimesByPanelId.removeAll()
        for panelId in panelIds {
            recordAgentLifecycleChange(panelId: panelId)
        }
    }

    func recordAgentLifecycleChange(panelId: UUID) {

        AgentHibernationController.shared.recordAgentLifecycleChange(
            workspaceId: id,
            panelId: panelId
        )
    }
}
