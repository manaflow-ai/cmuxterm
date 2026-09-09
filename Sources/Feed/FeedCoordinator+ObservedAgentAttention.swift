import AppKit
import Bonsplit
import CmuxSidebar
import Foundation

struct ObservedFeedAttentionSurface: Sendable {
    let target: FeedAttentionTarget
    let token: AgentFeedAttentionToken
    let previousStatusEntry: SidebarStatusEntry?
    let statusEntry: SidebarStatusEntry
    let ownerId: UUID
}

extension FeedCoordinator {
    /// Begins status-only attention from a trustworthy native approval
    /// observer. Native prompts use the agent's lifecycle key so a later
    /// lifecycle hook can reconcile the prompt without inventing a Feed card.
    @MainActor
    func beginObservedAgentAttention(
        source: String,
        sessionId: String,
        observationId: String,
        scopeId: String,
        workspaceId: UUID,
        surfaceId: UUID?,
        processGeneration: AgentPIDProcessIdentity,
        observationEpoch: UInt64? = nil
    ) -> Bool {
        guard let integration = BuiltInAgentIntegration(feedSourceName: source),
              integration.approvalDetectionMechanism == .nativePostPolicyObserver else {
            return false
        }
        let key = AgentObservedAttentionKey(
            source: source,
            sessionId: sessionId,
            observationId: observationId,
            processGeneration: processGeneration
        )
        guard !observedAttentionConclusions.contains(
            source: source,
            sessionId: sessionId,
            observationId: observationId,
            scopeId: scopeId,
            processGeneration: processGeneration,
            observationEpoch: observationEpoch
        ) else {
            return false
        }
        if observedAttentionRegistry.record(for: key) != nil { return true }

        let appDelegate = AppDelegate.shared
        let tab = appDelegate?.tabManagerFor(tabId: workspaceId)?.tabs.first {
            $0.id == workspaceId
        }
        let directOwner = surfaceId.flatMap {
            TerminalController.shared.controlSidebarResolvePanelOwner(
                target: .workspace(workspaceId),
                panelID: $0
            )
        }
        let panelId: UUID?
        let owner: ControlSidebarPanelOwner
        if let directOwner {
            panelId = surfaceId
            owner = directOwner
        } else if let dock = appDelegate?.existingWindowDock(forWindowId: workspaceId) {
            guard let candidate = surfaceId ?? dock.focusedPanelId,
                  dock.containsPanel(candidate) else { return false }
            panelId = candidate
            owner = .dock(dock)
        } else if let tab {
            if let surfaceId {
                panelId = Self.resolveAgentPanelId(surfaceId: surfaceId, tab: tab)
            } else {
                panelId = tab.focusedPanelId
            }
            guard surfaceId == nil || panelId != nil else { return false }
            owner = panelId.flatMap {
                TerminalController.shared.controlSidebarResolvePanelOwner(
                    target: .workspace(workspaceId),
                    panelID: $0
                )
            } ?? .workspace(tab)
        } else {
            // A panel-scoped observation must never invent a workspace owner
            // when the addressed workspace is no longer live.
            return false
        }
        guard surfaceId == nil || panelId != nil else { return false }
        let usesRemoteProcessNamespace = owner.usesRemoteAgentProcessNamespace(panelId: panelId)
        if let panelId, !usesRemoteProcessNamespace,
           AgentPIDProcessIdentity(pid: processGeneration.pid) != processGeneration {
            return false
        }

        let statusKey = Self.lifecycleStatusKey(forSource: source)
        let token: AgentFeedAttentionToken
        if let panelId {
            guard let panelToken = owner.beginAgentFeedAttention(
                key: statusKey,
                panelId: panelId,
                processGeneration: usesRemoteProcessNamespace ? nil : processGeneration
            ) else {
                return false
            }
            token = panelToken
        } else {
            guard case .workspace = owner else { return false }
            token = AgentFeedAttentionToken(processGeneration: processGeneration)
        }
        let target: FeedAttentionTarget = if let panelId {
            .panel(id: panelId, statusKey: statusKey)
        } else {
            .workspace(id: owner.id, statusKey: statusKey)
        }
        let previousStatusEntry: SidebarStatusEntry?
        if let existing = observedAttentionRegistry.first(where: {
            $0.target.target == target
        }) {
            // All overlapping observations restore the baseline captured by
            // the first observer, never the Needs Input entry written by an
            // earlier observer in the same stack.
            previousStatusEntry = existing.target.previousStatusEntry
        } else {
            previousStatusEntry = owner.statusEntry(key: statusKey, panelId: panelId)
        }
        let statusEntry = SidebarStatusEntry(
            key: statusKey,
            value: Self.needsInputStatusValue,
            icon: "bell.fill",
            color: "#4C8DFF",
            timestamp: Date()
        )
        owner.setStatusEntry(statusEntry, key: statusKey, panelId: panelId)
        let surface = ObservedFeedAttentionSurface(
            target: target,
            token: token,
            previousStatusEntry: previousStatusEntry,
            statusEntry: statusEntry,
            ownerId: owner.id
        )
        let record = AgentObservedAttentionRecord(
            key: key,
            scopeId: scopeId,
            target: surface
        )
        guard let evicted = observedAttentionRegistry.insert(record) else {
            concludeObservedAttention(surface, processExitGeneration: nil)
            return true
        }
        retireObservedAgentAttentionRecords(evicted, recordConclusions: true)

        if !usesRemoteProcessNamespace {
            let monitorKey = Self.observedAttentionProcessMonitorKey(
                source: source,
                generation: processGeneration
            )
            attentionExitMonitor.observe(
                key: monitorKey,
                generation: processGeneration
            ) { [weak self] _, generation in
                _ = self?.endObservedAgentAttention(
                    source: source,
                    sessionId: nil,
                    observationId: nil,
                    scopeId: nil,
                    processGeneration: generation,
                    boundaryEpoch: nil,
                    processDidExit: true
                )
            }
        }
        return true
    }

    @MainActor
    @discardableResult
    func endObservedAgentAttention(
        source: String,
        sessionId: String,
        observationId: String?,
        scopeId: String?,
        processGeneration: AgentPIDProcessIdentity,
        boundaryEpoch: UInt64? = nil
    ) -> Int {
        endObservedAgentAttention(
            source: source,
            sessionId: sessionId,
            observationId: observationId,
            scopeId: scopeId,
            processGeneration: processGeneration,
            boundaryEpoch: boundaryEpoch,
            processDidExit: false
        )
    }

    @MainActor
    @discardableResult
    private func endObservedAgentAttention(
        source: String,
        sessionId: String?,
        observationId: String?,
        scopeId: String?,
        processGeneration: AgentPIDProcessIdentity,
        boundaryEpoch: UInt64?,
        processDidExit: Bool
    ) -> Int {
        if !processDidExit {
            observedAttentionConclusions.record(
                source: source,
                sessionId: sessionId,
                observationId: observationId,
                scopeId: scopeId,
                processGeneration: processGeneration,
                boundaryEpoch: boundaryEpoch
            )
        }
        let records = observedAttentionRegistry.remove { record in
            let key = record.key
            return key.source == source
                && key.processGeneration == processGeneration
                && (processDidExit || key.sessionId == sessionId)
                && (observationId == nil || key.observationId == observationId)
                && (scopeId == nil || record.scopeId == scopeId)
        }
        retireObservedAgentAttentionRecords(
            records,
            recordConclusions: false,
            processExitGeneration: processDidExit ? processGeneration : nil
        )
        return records.count
    }

    /// Reconciles an accepted lifecycle hook with native approval observations.
    @MainActor
    func reconcileObservedAgentAttention(
        workspaceId: UUID,
        panelId: UUID,
        statusKey: String,
        lifecycle: AgentHibernationLifecycleState,
        processGeneration: AgentPIDProcessIdentity?
    ) {
        guard let processGeneration else { return }
        let records = observedAttentionRegistry.remove { record in
            record.target.target.panelId == panelId
                && record.target.target.statusKey == statusKey
                && record.target.ownerId == workspaceId
                && (record.key.processGeneration < processGeneration
                    || (lifecycle == .idle
                        && record.key.processGeneration == processGeneration))
        }
        retireObservedAgentAttentionRecords(records, recordConclusions: true)
    }

    /// Retires attention owned by a panel that is being destroyed. Transfers
    /// call `retargetAgentAttention` instead, allowing their tokens to follow.
    @MainActor
    func retireAgentAttention(workspaceId: UUID, panelId: UUID) {
        let observed = observedAttentionRegistry.remove {
            $0.target.target.panelId == panelId
        }
        retireObservedAgentAttentionRecords(observed, recordConclusions: true)
        let pending = pendingAttentionStates.keys.filter { target in
            target.panelId == panelId
                && pendingAttentionStates[target]?.fallbackOwner.id == workspaceId
        }
        for target in pending { concludeBlockingDecisionAttention(target) }
    }

    @MainActor
    func retargetAgentAttention(
        panelId: UUID,
        to owner: ControlSidebarPanelOwner
    ) {
        for target in pendingAttentionStates.keys where target.panelId == panelId {
            pendingAttentionStates[target]?.fallbackOwner = owner
        }
        observedAttentionRegistry.update(
            where: { $0.target.target.panelId == panelId },
            transform: { record in
                let surface = record.target
                return AgentObservedAttentionRecord(
                    key: record.key,
                    scopeId: record.scopeId,
                    target: ObservedFeedAttentionSurface(
                        target: surface.target,
                        token: surface.token,
                        previousStatusEntry: surface.previousStatusEntry,
                        statusEntry: surface.statusEntry,
                        ownerId: owner.id
                    )
                )
            }
        )
    }

    /// Retires native attention after reconciliation accepted an exact exit.
    @MainActor
    func retireObservedAgentAttentionForProcessExit(
        workspaceId: UUID,
        panelId: UUID,
        statusKey: String,
        processGeneration: AgentPIDProcessIdentity
    ) {
        let records = observedAttentionRegistry.remove { record in
            record.target.target.panelId == panelId
                && record.target.target.statusKey == statusKey
                && record.key.processGeneration == processGeneration
        }
        retireObservedAgentAttentionRecords(records, recordConclusions: true)
    }

    @MainActor
    private func retireObservedAgentAttentionRecords(
        _ records: [AgentObservedAttentionRecord<ObservedFeedAttentionSurface>],
        recordConclusions: Bool,
        processExitGeneration: AgentPIDProcessIdentity? = nil
    ) {
        for record in records {
            if recordConclusions {
                observedAttentionConclusions.record(
                    source: record.key.source,
                    sessionId: record.key.sessionId,
                    observationId: record.key.observationId,
                    scopeId: record.scopeId,
                    processGeneration: record.key.processGeneration
                )
            }
            concludeObservedAttention(
                record.target,
                processExitGeneration: processExitGeneration
            )
        }
        for record in records where !observedAttentionRegistry.contains(where: {
            $0.key.source == record.key.source
                && $0.key.processGeneration == record.key.processGeneration
        }) {
            attentionExitMonitor.cancel(
                key: Self.observedAttentionProcessMonitorKey(
                    source: record.key.source,
                    generation: record.key.processGeneration
                )
            )
        }
    }

    @MainActor
    private func concludeObservedAttention(
        _ surface: ObservedFeedAttentionSurface,
        processExitGeneration: AgentPIDProcessIdentity?
    ) {
        let target = surface.target
        let owner: ControlSidebarPanelOwner? = {
            guard let panelId = target.panelId else {
                return AppDelegate.shared?.tabManagerFor(tabId: surface.ownerId)?
                    .tabs.first(where: { $0.id == surface.ownerId })
                    .map(ControlSidebarPanelOwner.workspace)
            }
            return TerminalController.shared.controlSidebarResolvePanelOwner(
                target: .workspace(surface.ownerId),
                panelID: panelId
            )
        }()
        if let owner, let panelId = target.panelId {
            if let processExitGeneration {
                _ = owner.recordAgentProcessExit(
                    key: target.statusKey,
                    panelId: panelId,
                    generation: processExitGeneration
                )
            } else {
                _ = owner.endAgentFeedAttention(
                    key: target.statusKey,
                    panelId: panelId,
                    token: surface.token
                )
            }
        }

        let stillObserved = observedAttentionRegistry.contains { record in
            record.target.target == target
        }
        guard !stillObserved else { return }
        guard let owner else { return }
        if let panelId = target.panelId,
           owner.agentLifecycleState(key: target.statusKey, panelId: panelId) == .needsInput {
            return
        }
        guard owner.statusEntry(key: target.statusKey, panelId: target.panelId)
                == surface.statusEntry else {
            return
        }
        if let previousStatusEntry = surface.previousStatusEntry {
            owner.setStatusEntry(
                previousStatusEntry,
                key: target.statusKey,
                panelId: target.panelId
            )
        } else {
            owner.clearStatusEntry(key: target.statusKey, panelId: target.panelId)
        }
    }

    private static func observedAttentionProcessMonitorKey(
        source: String,
        generation: AgentPIDProcessIdentity
    ) -> String {
        [
            source,
            String(generation.pid),
            String(generation.startSeconds),
            String(generation.startMicroseconds),
        ].joined(separator: ":")
    }

    @MainActor
    private static func resolveAgentPanelId(surfaceId: UUID, tab: Workspace) -> UUID? {
        if tab.panels[surfaceId] != nil { return surfaceId }
        return tab.panelIdFromSurfaceId(TabID(uuid: surfaceId))
    }
}
