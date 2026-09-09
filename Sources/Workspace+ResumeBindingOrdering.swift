import Foundation
import CmuxRemoteSession


extension Workspace {
    /// Hook publications use ``setSurfaceResumeBinding`` directly, while
    /// reconciliation and transfer paths historically wrote the dictionary
    /// inline. Those paths must share the same claim gate so no writer can
    /// replace the generation after the CLI has been authorized to exec it.
    @discardableResult
    func surfaceResumeBindingMutationAllowed(
        _ incoming: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) -> Bool {
        guard let claim = surfaceResumeRestoreClaim(for: panelId) else {
            recordSurfaceResumeBindingMutation(panelId: panelId, eventTime: incoming.updatedAt)
            return true
        }
        guard claim.binding.acceptsRestoreBindingClaim(from: incoming) else {
            return false
        }
        // Preserve the lease when a same-session writer refreshes metadata,
        // otherwise the current-generation check would discard the claim.
        surfaceResumeRestoreClaimsByPanelId[panelId] = (
            binding: incoming,
            claimedAt: claim.claimedAt
        )
        recordSurfaceResumeBindingMutation(panelId: panelId, eventTime: incoming.updatedAt)
        return true
    }

    /// Returns false while a claimed generation is still active.
    @discardableResult
    func surfaceResumeBindingRemovalAllowed(panelId: UUID) -> Bool {
        surfaceResumeRestoreClaim(for: panelId) == nil
    }

    /// Returns whether an ordered hook mutation is newer than this panel's
    /// retained resume-binding watermark.
    func acceptsSurfaceResumeBindingMutation(
        panelId: UUID,
        agentEventTime: TimeInterval?,
        requiresAgentEventTime: Bool = false
    ) -> Bool {
        let currentBindingTime = surfaceResumeBindingsByPanelId[panelId]?.updatedAt
        let orderingWatermark = [
            surfaceResumeBindingEventTimesByPanelId[panelId],
            currentBindingTime,
        ].compactMap { $0 }.max()
        if requiresAgentEventTime, agentEventTime == nil {
            return false
        }
        guard let orderingWatermark else { return true }
        guard let agentEventTime else { return !requiresAgentEventTime }
        return agentEventTime >= orderingWatermark
    }

    /// Advances the retained resume-binding watermark without replacing the binding.
    func recordSurfaceResumeBindingMutation(panelId: UUID, eventTime: TimeInterval) {
        guard eventTime.isFinite else { return }
        if let current = surfaceResumeBindingEventTimesByPanelId[panelId], current >= eventTime {
            return
        }
        surfaceResumeBindingEventTimesByPanelId[panelId] = eventTime
    }

    func surfaceResumeRestoreClaim(
        for panelId: UUID
    ) -> (binding: SurfaceResumeBindingSnapshot, claimedAt: Date)? {
        guard let claim = surfaceResumeRestoreClaimsByPanelId[panelId] else {
            return nil
        }
        guard let currentBinding = surfaceResumeBindingsByPanelId[panelId],
              currentBinding.checkpointId == claim.binding.checkpointId,
              currentBinding.source == claim.binding.source,
              currentBinding.updatedAt == claim.binding.updatedAt else {
            // A direct lifecycle mutation replaced the claimed generation
            // without going through the hook setter. Do not let that old claim
            // block a later, legitimate binding.
            surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
            return nil
        }
        guard Date.now.timeIntervalSince(claim.claimedAt) < SurfaceResumeBindingSnapshot.restoreClaimTTL else {
            surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
            return nil
        }
        return claim
    }

    @discardableResult
    func clearSurfaceResumeBinding(
        panelId: UUID,
        agentSessionEnded: Bool = false,
        eventTime: TimeInterval? = nil,
        requiresAgentEventTime: Bool = false
    ) -> Bool {
        guard acceptsSurfaceResumeBindingMutation(
            panelId: panelId,
            agentEventTime: eventTime,
            requiresAgentEventTime: requiresAgentEventTime
        ) else {
            return false
        }
        let removedBinding = surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
        if let removedBinding,
           agentSessionEnded,
           removedBinding.isAgentHookBinding,
           let checkpointID = Self.normalizedResumeBindingValue(removedBinding.checkpointId),
           let restoredAgent = restoredAgentSnapshotsByPanelId[panelId],
           ManagedAgentSessionIdentity.sessionIDsMatch(
               kind: restoredAgent.kind.rawValue,
               lhs: checkpointID,
               rhs: restoredAgent.sessionId
           ),
           Self.restorableAgentForSessionRestore(restoredAgent, resumeBinding: removedBinding) != nil {
            // A restore-time rejection is an authoritative end of the stale checkpoint.
            markRestoredAgentCompleted(panelId: panelId, snapshot: restoredAgent)
        }
        pendingPlainSSHRestorePanelIds.remove(panelId)
        observedPlainSSHPanelIds.remove(panelId)
        plainSSHDetectionMissesByPanelId.removeValue(forKey: panelId)
        if removedBinding != nil {
            recordSurfaceResumeBindingMutation(
                panelId: panelId,
                eventTime: eventTime ?? Date.now.timeIntervalSince1970
            )
        }
        return removedBinding != nil
    }
}
