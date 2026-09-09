import Bonsplit
import CmuxWorkspaces
import Darwin
import Foundation

extension DockSplitStore {
    func effectiveSessionResumeBinding(
        panelId: UUID,
        detected: SurfaceResumeBindingSnapshot?,
        downgradeStoredProcessDetectedResumeBindingWhenDetectionUnavailable: Bool,
        detectedIsAmbiguous: Bool
    ) -> SurfaceResumeBindingSnapshot? {
        let stored = surfaceResumeBindingsByPanelId[panelId]
        if let stored,
           stored.hasCompleteManagedSessionIdentity,
           managedAgentResumeBindingsByPanelId[panelId] == nil {
            managedAgentResumeBindingsByPanelId[panelId] = stored
        }
        let effective: SurfaceResumeBindingSnapshot?
        if let stored, let detected {
            effective = stored.shouldYieldToDetectedSurfaceResumeBinding(detected) ? detected : stored
        } else if let detected {
            effective = detected
        } else if var stored,
                  stored.isProcessDetected,
                  downgradeStoredProcessDetectedResumeBindingWhenDetectionUnavailable {
            // Recovery cannot synchronously scan processes before its owner is
            // torn down. Retain the command for explicit recovery, but never
            // treat the unverified cached binding as safe to auto-run.
            stored.autoResume = false
            stored.approvalPolicy = .manual
            stored.approvalRecordId = nil
            effective = stored
        } else if stored?.isProcessDetected == true {
            effective = detectedIsAmbiguous
                ? stored?.disablingAutomaticResume()
                : nil
        } else {
            effective = stored
        }
        if let effective {
            guard surfaceResumeBindingMutationAllowed(effective, panelId: panelId) else {
                return stored
            }
            surfaceResumeBindingsByPanelId[panelId] = effective
            recordSurfaceResumeBindingMutation(
                panelId: panelId,
                eventTime: effective.updatedAt
            )
        } else {
            guard surfaceResumeBindingRemovalAllowed(panelId: panelId) else {
                return stored
            }
            surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        }
        return effective
    }

    func effectiveSessionRestorableAgent(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry?,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        managedResumeBinding: SurfaceResumeBindingSnapshot?,
        terminal: TerminalPanel,
        transfer: Workspace.DetachedSurfaceTransfer?
    ) -> SessionRestorableAgentSnapshot? {
        if let observation {
            _ = restoredAgentLifecycle.reconcileCompletedAgent(
                panelId: panelId,
                observation: observation,
                currentProcessIdentity: Workspace.agentPIDProcessIdentity(pid:)
            )
        }
        let coordinated = restoredAgentLifecycle.continuationSnapshot(
            panelId: panelId,
            observation: observation,
            currentProcessIdentity: Workspace.agentPIDProcessIdentity(pid:)
        )
        let observed = restoredAgentLifecycle.resumeStatesByPanelId[panelId] == .completedAgentExit
            ? nil
            : observation?.snapshot
        let requiresCurrentManagedSession =
            invalidatedCachedTransferAgentSessionPanelIds.contains(panelId)
        let agentCompatibilityBinding = managedResumeBinding ?? resumeBinding
        let cachedTransferAgent: SessionRestorableAgentSnapshot? = {
            guard let candidate = transfer?.restorableAgent else { return nil }
            if let cachedBinding = transfer?.resumeBinding,
               cachedBinding.isAgentHookBinding {
                if let managedResumeBinding,
                   !cachedBinding.isSameManagedSession(as: managedResumeBinding) {
                    return nil
                }
            }
            return candidate
        }()
        let compatibleCandidate = [
            terminal.agentHibernationState?.agent,
            observed,
            coordinated,
            cachedTransferAgent,
        ].compactMap { candidate -> SessionRestorableAgentSnapshot? in
            if requiresCurrentManagedSession,
               managedResumeBinding?.hasCompleteManagedSessionIdentity != true {
                return nil
            }
            return Workspace.restorableAgentForSessionRestore(
                candidate,
                resumeBinding: agentCompatibilityBinding
            )
        }.first
        let compatible = restoredAgentLifecycle.reconcileSnapshotWithQueuedRestoreIntent(
            panelId: panelId,
            proposedSnapshot: compatibleCandidate
        )
        if let compatible {
            restoredAgentLifecycle.setSnapshot(compatible, panelId: panelId)
        }
        return compatible
    }

    func sessionAgentWasRunning(
        restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        managedResumeBinding: SurfaceResumeBindingSnapshot?,
        terminal: TerminalPanel,
        transfer: Workspace.DetachedSurfaceTransfer?,
        observation: RestorableAgentSessionIndex.Entry?,
        currentAgentProcessIdentity: (Int) -> AgentPIDProcessIdentity?,
        agentProcessPresence: (Int) -> PIDPresence
    ) -> Bool? {
        let managedBinding = managedResumeBinding
            ?? resumeBinding.flatMap { $0.isAgentHookBinding ? $0 : nil }
        guard restorableAgent != nil || managedBinding != nil else { return nil }
        if restoredAgentLifecycle.hasQueuedRestoreIntent(
            panelId: terminal.id,
            matching: restorableAgent
        ) {
            return true
        }
        let expectedKind = managedBinding != nil
            ? managedBinding?.kind.flatMap {
                RestorableAgentKind(
                    persistedRawValue: $0,
                    registration: restorableAgent?.registration ?? observation?.snapshot.registration
                )
            }
            : restorableAgent?.kind
        let expectedSessionId = managedBinding != nil
            ? managedBinding?.checkpointId
            : restorableAgent?.sessionId
        let relevantObservation: RestorableAgentSessionIndex.Entry?
        if let expectedKind, let expectedSessionId {
            relevantObservation = observation?.matchingAgentSession(
                kind: expectedKind.rawValue,
                sessionId: expectedSessionId
            )
        } else {
            relevantObservation = nil
        }
        let confirmedRuntimeIdentities: Set<AgentPIDProcessIdentity> = {
            guard let expectedKind, expectedKind != .claude,
                  let expectedSessionId,
                  let runtime = agentRuntimeByPanelId[terminal.id] ?? transfer?.agentRuntime else {
                return []
            }
            let key = "\(expectedKind.rawValue).\(expectedSessionId)"
            guard let recordedIdentity = runtime.agentPIDProcessIdentities[key],
                  currentAgentProcessIdentity(Int(recordedIdentity.pid)) == recordedIdentity else {
                return []
            }
            return [recordedIdentity]
        }()
        if managedBinding != nil,
           relevantObservation == nil,
           confirmedRuntimeIdentities.isEmpty {
            return false
        }
        return (relevantObservation?.processLiveness ?? .unknown).wasRunning(
            fallingBackTo: terminal.shellActivity.state,
            recordedProcessIdentities: relevantObservation?.agentProcessIdentities ?? [:],
            confirmedRuntimeProcessIdentities: confirmedRuntimeIdentities,
            currentProcessIdentity: currentAgentProcessIdentity,
            processPresence: agentProcessPresence
        ) ?? false
    }
}
