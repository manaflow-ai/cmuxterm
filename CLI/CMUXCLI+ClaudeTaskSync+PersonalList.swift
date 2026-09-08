import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    func runClaudeTaskSyncPersonalList(
        _ operation: ClaudeTaskSyncOperation,
        previouslyBoundRecord: ClaudeHookTeamTaskBindingRecord?,
        automaticTeamResolution: ClaudeTeamTaskListResolution?
    ) throws {
        let client = operation.client
        let telemetry = operation.telemetry
        let parsedInput = operation.parsedInput
        let sessionStore = operation.sessionStore
        let socketPassword = operation.socketPassword
        let sessionID = operation.sessionID
        let resolvedTarget = operation.resolvedTarget
        let loader = operation.loader
        let taskStoreIdentity = operation.taskStoreIdentity
        let agentID = operation.agentID
        let taskIdentity = operation.taskIdentity
        let configuredTaskListID = operation.configuredTaskListID
        let hookDeadlineUptime = operation.hookDeadlineUptime
        let taskHookPID = operation.taskHookPID
        let currentRecord = operation.currentRecord
        let taskSyncIsLatest = operation.isLatest
        let retargetTaskSyncClaim = operation.retarget
        var cleanupTaskDirectoryName: String?
        var deferredAutomaticTeamCleanup: (
            binding: ClaudeTeamTaskListBinding,
            workspaceIDs: [String]
        )?
        // A superseded hook must not clear the live Feed projection
        // while it is preparing cleanup for an older automatic team.
        // Prove this hook still owns the visible mutation before any
        // empty cleanup snapshot is sent.
        guard shouldApplyClaudeHookVisibleMutation(
            sessionStore: sessionStore,
            parsedInput: parsedInput,
            workspaceId: resolvedTarget.workspaceId,
            surfaceId: resolvedTarget.isAuthoritative ? resolvedTarget.surfaceId : nil,
            telemetry: telemetry
        ) else {
            telemetry.breadcrumb("claude-hook.task-sync.stale")
            return
        }
        if let automaticTeamResolution {
            cleanupTaskDirectoryName = automaticTeamResolution.binding.taskListID
            let cleanupWorkspaceIDs: [String]
            if let recordedWorkspaceIDs = previouslyBoundRecord?.workspaceIDs,
               !recordedWorkspaceIDs.isEmpty {
                cleanupWorkspaceIDs = recordedWorkspaceIDs
            } else {
                cleanupWorkspaceIDs = [resolvedTarget.workspaceId]
            }
            if sendClaudeTaskFeedSnapshot(
                [],
                client: client,
                telemetry: telemetry,
                parsedInput: parsedInput,
                workspaceId: resolvedTarget.workspaceId,
                surfaceId: resolvedTarget.surfaceId,
                socketPassword: socketPassword,
                deadlineUptime: hookDeadlineUptime
            ) {
                let cleanupSucceeded = (try? clearRetainedClaudeTeamTaskOwner(
                    binding: automaticTeamResolution.binding,
                    workspaceIDs: cleanupWorkspaceIDs,
                    retirementTaskStoreIdentity: taskStoreIdentity,
                    sessionStore: sessionStore,
                    client: client,
                    telemetry: telemetry,
                    deadlineUptime: hookDeadlineUptime
                )) == true
                if !cleanupSucceeded {
                    deferredAutomaticTeamCleanup = (
                        automaticTeamResolution.binding,
                        cleanupWorkspaceIDs
                    )
                }
            } else {
                // A personal snapshot can supersede the rejected empty
                // Feed update. Defer checklist cleanup until that
                // authoritative replacement is acknowledged below.
                deferredAutomaticTeamCleanup = (
                    automaticTeamResolution.binding,
                    cleanupWorkspaceIDs
                )
            }
            // A retained team proof owns only the old cleanup delivery.
            // The same hook may already describe the leader's first new
            // personal task, so continue through session-owned resolution.
        }

        // An agent-qualified hook must prove automatic-team membership;
        // the leader session alone is intentionally not sufficient.
        guard agentID == nil else {
            telemetry.breadcrumb("claude-hook.task-sync.unproven-agent")
            return
        }
        let taskBindingSource = currentRecord?.claudeTaskBindingSource
        let taskBindingBelongsToCurrentGeneration = currentRecord.map { record in
            if let bindingStartedAt = record.claudeTaskBindingStartedAt {
                return bindingStartedAt == record.startedAt
            }
            // Stores written before generation fencing have no marker;
            // preserve their proven compatibility behavior until the
            // next authoritative SessionStart invalidates them.
            return record.claudeTaskBindingSource == nil
        } ?? false
        let taskBindingWasInvalidated = taskBindingSource == .invalidated
        let automaticTeamProofRejected = taskBindingSource == .automaticTeam
            && automaticTeamResolution == nil
        let configuredListProofRejected = taskBindingSource == .configuredList
            && configuredTaskListID == nil
        let canUseBoundTaskDirectory = !taskBindingWasInvalidated
            && !automaticTeamProofRejected
            && !configuredListProofRejected
            && taskBindingBelongsToCurrentGeneration
        var usedCompatibilityScan = false
        var sessionSnapshot = try loader.loadDirectSessionTaskList(
            sessionID: sessionID,
            taskIdentity: taskIdentity
        )
        if sessionSnapshot == nil {
            let boundDirectoryName = canUseBoundTaskDirectory
                && currentRecord?.claudeTaskStoreID == taskStoreIdentity.rawValue
                ? currentRecord?.claudeTaskDirectoryName
                : nil
            if let boundDirectoryName {
                sessionSnapshot = try loader.loadBoundTaskList(
                    directoryName: boundDirectoryName,
                    taskIdentity: taskIdentity
                )
            } else if let taskIdentity,
                      !taskBindingWasInvalidated,
                      !automaticTeamProofRejected,
                      !configuredListProofRejected {
                // Older Claude team metadata may not link the current
                // hook session to its task list. The issue contract's
                // compatibility proof is the exact id+subject emitted
                // by this hook; the bounded loader fails closed when
                // more than one directory contains that same tuple.
                sessionSnapshot = try loader.load(
                    sessionID: sessionID,
                    taskIdentity: taskIdentity
                )
                usedCompatibilityScan = sessionSnapshot != nil
            }
        }
        guard let sessionSnapshot,
              sessionSnapshot.directoryName != cleanupTaskDirectoryName else {
            telemetry.breadcrumb("claude-hook.task-sync.task-directory-unresolved")
            return
        }
        let personalBindingSource: ClaudeTaskBindingSource = usedCompatibilityScan
            ? .compatibilityScan
            : (automaticTeamResolution != nil
                ? .directSession
                : (taskBindingSource ?? .directSession))
        let personalTaskResolver = ClaudeTeamTaskListResolver(
            teamsRootURL: operation.teamsRootURL,
            taskStoreIdentity: taskStoreIdentity,
            deadlineUptime: hookDeadlineUptime
        )
        let matchingTeamRecord = try sessionStore.claudeTeamTaskBindingRecord(
            taskListID: sessionSnapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity
        )
        guard try canAdmitRetiredClaudeTaskList(
            taskListID: sessionSnapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity,
            currentRecord: currentRecord,
            sessionID: sessionID,
            agentID: agentID,
            matchingTeamRecord: matchingTeamRecord,
            sessionStore: sessionStore,
            teamTaskResolver: personalTaskResolver
        ) else {
            telemetry.breadcrumb("claude-hook.task-sync.retired-task-directory")
            return
        }
        guard try retargetTaskSyncClaim(sessionSnapshot.directoryName) else {
            telemetry.breadcrumb("claude-hook.task-sync.coalesce-transfer-failed")
            return
        }
        guard taskSyncIsLatest() else {
            telemetry.breadcrumb("claude-hook.task-sync.coalesced")
            return
        }
        let destinationTransition = try sessionStore
            .claudeTaskListDestinationTransition(
                taskListID: sessionSnapshot.directoryName,
                taskStoreIdentity: taskStoreIdentity,
                including: [resolvedTarget.workspaceId]
            )
        guard taskSyncIsLatest() else {
            telemetry.breadcrumb("claude-hook.task-sync.coalesced")
            return
        }
        guard try migrateLegacyClaudeTaskChecklistOwnerIfNeeded(
            currentRecord: currentRecord,
            sessionID: sessionID,
            taskDirectoryName: sessionSnapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity,
            sessionStore: sessionStore,
            client: client,
            telemetry: telemetry,
            workspaceIDs: [resolvedTarget.workspaceId],
            deadlineUptime: hookDeadlineUptime
        ) else { return }
        guard taskSyncIsLatest() else {
            telemetry.breadcrumb("claude-hook.task-sync.coalesced")
            return
        }
        let destinationWasRetired = try sessionStore.isClaudeTaskListRetired(
            taskListID: sessionSnapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity
        )
        let destinationRecordBeforePrepare = try sessionStore
            .claudeTaskListDestinationRecord(
                taskListID: sessionSnapshot.directoryName,
                taskStoreIdentity: taskStoreIdentity
            )
        guard try prepareClaudeTaskListDestination(
            taskDirectoryName: sessionSnapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity,
            workspaceIDs: destinationTransition.workspaceIDs,
            retiredRecords: destinationTransition.retiredRecords,
            sessionStore: sessionStore,
            client: client,
            telemetry: telemetry,
            deadlineUptime: hookDeadlineUptime
        ) else { return }
        let destinationRecordAfterPrepare = try sessionStore
            .claudeTaskListDestinationRecord(
                taskListID: sessionSnapshot.directoryName,
                taskStoreIdentity: taskStoreIdentity
            )
        guard let boundRecord = try sessionStore.bindClaudeTaskDirectory(
            sessionId: sessionID,
            directoryName: sessionSnapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity,
            workspaceId: resolvedTarget.workspaceId,
            surfaceId: resolvedTarget.surfaceId,
            pid: taskHookPID,
            expectedStartedAt: currentRecord?.startedAt,
            source: personalBindingSource
        ) else {
            telemetry.breadcrumb("claude-hook.task-sync.session-ended")
            if (try? sessionStore.isClaudeSessionEnded(sessionID)) == true {
                _ = clearClaudeTaskChecklistOwner(
                    taskDirectoryName: sessionSnapshot.directoryName,
                    taskStoreIdentity: taskStoreIdentity,
                    client: client,
                    telemetry: telemetry,
                    workspaceIDs: destinationTransition.workspaceIDs,
                    deadlineUptime: hookDeadlineUptime
                )
            }
            return
        }
        if operation.taskHookStartedAt == nil {
            operation.taskHookStartedAt = boundRecord.startedAt
        }
        guard taskSyncIsLatest() else {
            rollbackFirstSightingClaudeTaskSync(
                currentRecord: currentRecord,
                boundRecord: boundRecord,
                taskDirectoryName: sessionSnapshot.directoryName,
                taskStoreIdentity: taskStoreIdentity,
                bindingSource: personalBindingSource,
                destinationBefore: destinationRecordBeforePrepare,
                destinationAfter: destinationRecordAfterPrepare,
                destinationWasRetired: destinationWasRetired,
                sessionStore: sessionStore
            )
            telemetry.breadcrumb("claude-hook.task-sync.coalesced")
            return
        }
        guard let delivery = deliverClaudeTaskSnapshot(
            sessionSnapshot,
            taskStoreIdentity: taskStoreIdentity,
            client: client,
            telemetry: telemetry,
            parsedInput: parsedInput,
            workspaceId: resolvedTarget.workspaceId,
            surfaceId: resolvedTarget.surfaceId,
            reconciliationWorkspaceIDs: [resolvedTarget.workspaceId],
            socketPassword: socketPassword,
            deadlineUptime: hookDeadlineUptime
        ) else {
            rollbackFirstSightingClaudeTaskSync(
                currentRecord: currentRecord,
                boundRecord: boundRecord,
                taskDirectoryName: sessionSnapshot.directoryName,
                taskStoreIdentity: taskStoreIdentity,
                bindingSource: personalBindingSource,
                destinationBefore: destinationRecordBeforePrepare,
                destinationAfter: destinationRecordAfterPrepare,
                destinationWasRetired: destinationWasRetired,
                sessionStore: sessionStore
            )
            return
        }
        let retainedPersonalWorkspaceIDs = delivery.workspaceItemsAreEmpty
            && delivery.reconciliationSucceeded
            ? []
            : delivery.retainedWorkspaceIDs
        let normalizedWorkspaceID = resolvedTarget.workspaceId.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard delivery.reconciliationSucceeded,
              delivery.retainedWorkspaceIDs.contains(normalizedWorkspaceID) else {
            return
        }
        guard taskSyncIsLatest() else {
            telemetry.breadcrumb("claude-hook.task-sync.coalesced")
            return
        }
        guard clearSupersededPersonalClaudeTaskChecklistOwnerIfNeeded(
            currentRecord: currentRecord,
            taskDirectoryName: sessionSnapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity,
            currentWorkspaceID: resolvedTarget.workspaceId,
            recordedWorkspaceIDs: destinationTransition.workspaceIDs,
            client: client,
            telemetry: telemetry,
            deadlineUptime: hookDeadlineUptime
        ) else { return }
        guard taskSyncIsLatest() else {
            telemetry.breadcrumb("claude-hook.task-sync.coalesced")
            return
        }
        try persistClaudeTaskListDestinations(
            taskDirectoryName: sessionSnapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity,
            retainedWorkspaceIDs: retainedPersonalWorkspaceIDs,
            sessionStore: sessionStore
        )
        guard taskSyncIsLatest() else {
            telemetry.breadcrumb("claude-hook.task-sync.coalesced")
            return
        }
        guard try markLegacyClaudeTaskChecklistOwnerMigratedIfNeeded(
            currentRecord: currentRecord,
            sessionID: sessionID,
            taskStoreIdentity: taskStoreIdentity,
            sessionStore: sessionStore,
        ) else { return }
        if let deferredAutomaticTeamCleanup {
            guard taskSyncIsLatest() else {
                telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                return
            }
            // The personal replacement is durable before the
            // superseded team owner is retried. Keep the old proof
            // when cleanup fails so a later hook can retry without
            // stranding the accepted personal binding.
            let cleanupSucceeded = (try? clearRetainedClaudeTeamTaskOwner(
                binding: deferredAutomaticTeamCleanup.binding,
                workspaceIDs: deferredAutomaticTeamCleanup.workspaceIDs,
                retirementTaskStoreIdentity: taskStoreIdentity,
                sessionStore: sessionStore,
                client: client,
                telemetry: telemetry,
                deadlineUptime: hookDeadlineUptime
            )) == true
            if !cleanupSucceeded {
                telemetry.breadcrumb(
                    "claude-hook.task-sync.deferred-team-cleanup-failed"
                )
            }
        }
    }
}
