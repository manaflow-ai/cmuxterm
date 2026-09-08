import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    func runClaudeTaskSyncTeamDelete(
        _ operation: ClaudeTaskSyncOperation
    ) throws {
        let client = operation.client
        let telemetry = operation.telemetry
        let parsedInput = operation.parsedInput
        let sessionStore = operation.sessionStore
        let socketPassword = operation.socketPassword
        let sessionID = operation.sessionID
        let resolvedTarget = operation.resolvedTarget
        let teamsRootURL = operation.teamsRootURL
        let taskStoreIdentity = operation.taskStoreIdentity
        let agentID = operation.agentID
        let configuredTaskDirectoryName = operation.configuredTaskDirectoryName
        let deletedTeamTaskDirectoryName = operation.deletedTeamTaskDirectoryName
        let hookDeadlineUptime = operation.hookDeadlineUptime
        let taskSyncIsLatest = operation.isLatest
        let retargetTaskSyncClaim = operation.retarget
        if let deletionTaskDirectoryName = deletedTeamTaskDirectoryName
            ?? configuredTaskDirectoryName {
            let matchingRecord = try sessionStore.claudeTeamTaskBindingRecord(
                taskListID: deletionTaskDirectoryName,
                taskStoreIdentity: taskStoreIdentity
            )
            let destinationRecord = try sessionStore.claudeTaskListDestinationRecord(
                taskListID: deletionTaskDirectoryName,
                taskStoreIdentity: taskStoreIdentity
            )
            let teamTaskResolver = ClaudeTeamTaskListResolver(
                teamsRootURL: teamsRootURL,
                taskStoreIdentity: taskStoreIdentity,
                deadlineUptime: hookDeadlineUptime
            )
            let currentTeamBinding: ClaudeTeamTaskListBinding?
            if matchingRecord != nil
                || destinationRecord?.taskStoreIdentity != nil {
                currentTeamBinding = try teamTaskResolver.currentTaskListBinding(
                    forTaskListID: deletionTaskDirectoryName
                )
            } else {
                currentTeamBinding = nil
            }
            if let matchingRecord,
               matchingRecord.binding.taskStoreIdentity != nil,
               let currentTeamBinding,
               !matchingRecord.binding.matches(
                   sessionID: sessionID,
                   agentID: agentID
               ),
               !currentTeamBinding.matches(
                   sessionID: sessionID,
                   agentID: agentID
               ) {
                // TeamDelete identifies the owner that was deleted,
                // while the durable task-list key may already hold
                // a replacement team. Legacy proofs intentionally
                // allow a replacement caller during migration;
                // namespaced proofs must retain their owner proof.
                telemetry.breadcrumb("claude-hook.task-sync.team-delete-reused")
                return
            }
            if matchingRecord == nil,
               destinationRecord?.taskStoreIdentity != nil,
               currentTeamBinding != nil {
                telemetry.breadcrumb("claude-hook.task-sync.team-delete-reused")
                return
            }
            if let matchingRecord,
               matchingRecord.binding.taskStoreIdentity != nil,
               let currentTeamBinding,
               teamTaskResolver.taskListBindingWasReused(
                   matchingRecord.binding,
                   capturedCurrentBinding: currentTeamBinding
               ) {
                telemetry.breadcrumb("claude-hook.task-sync.team-delete-reused")
                return
            }
            let cleanupTaskDirectoryName = matchingRecord?.binding.taskListID
                ?? destinationRecord?.taskListID
                ?? deletionTaskDirectoryName
            let cleanupWorkspaceIDs = Set(
                (matchingRecord?.workspaceIDs ?? [])
                    + (destinationRecord?.workspaceIDs ?? [])
                    + [resolvedTarget.workspaceId]
            ).sorted()
            let teamDeleteCleanupDeadline = hookDeadlineUptime
                - Self.claudeTaskSyncPersistenceMarginSeconds
            let feedDelivered = sendClaudeTaskFeedSnapshot(
                [],
                client: client,
                telemetry: telemetry,
                parsedInput: parsedInput,
                workspaceId: resolvedTarget.workspaceId,
                surfaceId: resolvedTarget.surfaceId,
                socketPassword: socketPassword,
                deadlineUptime: hookDeadlineUptime
            )
            if !feedDelivered {
                // TeamDelete cleanup is independent of the Feed
                // projection. A transient Feed failure must not
                // strand the deleted team's checklist rows or
                // skip the durable retry proof below.
                telemetry.breadcrumb(
                    "claude-hook.task-sync.team-delete-feed-deferred"
                )
            }
            let legacyCleanupCompleted = (try? drainLegacyClaudeTaskChecklistOwner(
                taskDirectoryName: cleanupTaskDirectoryName,
                sessionStore: sessionStore,
                client: client,
                telemetry: telemetry,
                workspaceIDs: cleanupWorkspaceIDs,
                includeFallbackDestinations: true,
                deadlineUptime: teamDeleteCleanupDeadline
            )) == true
            if !legacyCleanupCompleted {
                telemetry.breadcrumb(
                    "claude-hook.task-sync.legacy-owner-cleanup-deferred"
                )
            }
            var cleanupTaskStoreIdentities = Set<ClaudeTaskStoreIdentity?>()
            if let matchingRecord {
                cleanupTaskStoreIdentities.insert(
                    matchingRecord.binding.taskStoreIdentity
                )
            }
            if let destinationRecord {
                cleanupTaskStoreIdentities.insert(
                    destinationRecord.taskStoreIdentity
                )
            }
            if cleanupTaskStoreIdentities.isEmpty {
                cleanupTaskStoreIdentities.insert(taskStoreIdentity)
            }
            // Legacy proofs have no namespace of their own. Keep
            // their historical cleanup path unchanged, but always
            // retain a tombstone under the identity observed by
            // this hook so delayed compatibility scans cannot
            // re-admit the deleted list.
            var retirementTaskStoreIdentities = cleanupTaskStoreIdentities
            retirementTaskStoreIdentities.insert(taskStoreIdentity)
            // TeamDelete is commonly terminal, so drain every
            // bounded page that fits its deadline before deferring.
            var namespacedCleanupCompleted = true
            for cleanupTaskStoreIdentity in cleanupTaskStoreIdentities
                .compactMap({ $0 })
                .sorted(by: {
                $0.rawValue < $1.rawValue
                }) {
                let cleanup = drainClaudeTaskChecklistOwner(
                    taskDirectoryName: cleanupTaskDirectoryName,
                    taskStoreIdentity: cleanupTaskStoreIdentity,
                    client: client,
                    telemetry: telemetry,
                    workspaceIDs: cleanupWorkspaceIDs,
                    deadlineUptime: teamDeleteCleanupDeadline
                )
                guard cleanup.succeeded, cleanup.completed else {
                    namespacedCleanupCompleted = false
                    break
                }
            }
            let legacyCleanupRemainingWorkspaceIDs = try sessionStore
                .legacyClaudeTaskOwnerWorkspaceIDs(
                    directoryName: cleanupTaskDirectoryName,
                    including: [],
                    includeFallbackDestinations: false
                )
            let allDestinationsCleared = legacyCleanupCompleted
                && namespacedCleanupCompleted
                && legacyCleanupRemainingWorkspaceIDs.isEmpty
            let deferredWorkspaceIDs: [String]
            if allDestinationsCleared {
                deferredWorkspaceIDs = []
            } else if !legacyCleanupCompleted || !namespacedCleanupCompleted {
                deferredWorkspaceIDs = cleanupWorkspaceIDs
            } else {
                deferredWorkspaceIDs = legacyCleanupRemainingWorkspaceIDs
            }
            guard taskSyncIsLatest() else {
                telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                return
            }
            if legacyCleanupCompleted {
                if let matchingRecord,
                   matchingRecord.binding.taskStoreIdentity == nil {
                    try sessionStore.removeClaudeTeamTaskListBinding(
                        matchingRecord.binding
                    )
                }
                if let destinationRecord,
                   destinationRecord.taskStoreIdentity == nil {
                    try sessionStore.removeClaudeTaskListDestinationRecord(
                        destinationRecord
                    )
                }
            } else if !allDestinationsCleared,
                      !namespacedCleanupCompleted,
                      matchingRecord == nil,
                      destinationRecord == nil {
                // Preserve a workspace-bearing namespaced proof even
                // when the transition record was lost before the
                // first cleanup attempt. Retirement alone is not a
                // retry destination.
                let deferredPage = Array(
                    deferredWorkspaceIDs.prefix(
                        ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount
                    )
                )
                for cleanupTaskStoreIdentity in cleanupTaskStoreIdentities
                    .compactMap({ $0 }) {
                    try sessionStore.commitClaudeTaskListDestinations(
                        taskListID: cleanupTaskDirectoryName,
                        taskStoreIdentity: cleanupTaskStoreIdentity,
                        workspaceIDs: deferredPage
                    )
                }
            }
            if allDestinationsCleared {
                for cleanupTaskStoreIdentity in cleanupTaskStoreIdentities {
                    try sessionStore.clearClaudeTaskDirectoryBindings(
                        directoryName: cleanupTaskDirectoryName,
                        taskStoreIdentity: cleanupTaskStoreIdentity
                    )
                }
            }
            if let matchingRecord {
                if allDestinationsCleared {
                    try sessionStore.removeClaudeTeamTaskListBinding(
                        matchingRecord.binding
                    )
                }
            }
            if let destinationRecord {
                if allDestinationsCleared {
                    try sessionStore.removeClaudeTaskListDestinationRecord(
                        destinationRecord
                    )
                }
            }
            for cleanupTaskStoreIdentity in retirementTaskStoreIdentities.compactMap({ $0 }) {
                try sessionStore.retireClaudeTaskList(
                    taskListID: cleanupTaskDirectoryName,
                    taskStoreIdentity: cleanupTaskStoreIdentity
                )
            }
            if !allDestinationsCleared {
                telemetry.breadcrumb(
                    "claude-hook.task-sync.team-delete-cleanup-deferred"
                )
            }
        } else if let previouslyBoundRecord = try sessionStore
            .claudeTeamTaskBindingRecord(
                sessionId: sessionID,
                agentId: agentID,
                taskStoreIdentity: taskStoreIdentity
            ) {
            let cleanupWorkspaceIDs = previouslyBoundRecord.workspaceIDs.isEmpty
                ? [resolvedTarget.workspaceId]
                : previouslyBoundRecord.workspaceIDs
            guard try retargetTaskSyncClaim(
                previouslyBoundRecord.binding.taskListID
            ) else {
                telemetry.breadcrumb("claude-hook.task-sync.coalesce-transfer-failed")
                return
            }
            guard taskSyncIsLatest() else {
                telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                return
            }
            let feedDelivered = sendClaudeTaskFeedSnapshot(
                [],
                client: client,
                telemetry: telemetry,
                parsedInput: parsedInput,
                workspaceId: resolvedTarget.workspaceId,
                surfaceId: resolvedTarget.surfaceId,
                socketPassword: socketPassword,
                deadlineUptime: hookDeadlineUptime
            )
            if !feedDelivered {
                // Fallback TeamDelete cleanup is independent of the
                // Feed projection. Keep retiring the bound list so
                // SessionEnd has a durable retry fence after a
                // transient Feed failure.
                telemetry.breadcrumb(
                    "claude-hook.task-sync.team-delete-feed-deferred"
                )
            }
            let cleanup = clearClaudeTaskChecklistOwner(
                taskDirectoryName: previouslyBoundRecord.binding.taskListID,
                taskStoreIdentity: previouslyBoundRecord.binding.taskStoreIdentity,
                client: client,
                telemetry: telemetry,
                workspaceIDs: cleanupWorkspaceIDs,
                deadlineUptime: hookDeadlineUptime
            )
            guard taskSyncIsLatest() else {
                telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                return
            }
            try sessionStore.retainClaudeTeamTaskBindingWorkspaces(
                cleanup.retainedWorkspaceIDs,
                for: previouslyBoundRecord.binding
            )
            if cleanup.succeeded {
                guard taskSyncIsLatest() else {
                    telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                    return
                }
                try sessionStore.retireClaudeTaskList(
                    taskListID: previouslyBoundRecord.binding.taskListID,
                    taskStoreIdentity: taskStoreIdentity
                )
                if let bindingTaskStoreIdentity = previouslyBoundRecord.binding.taskStoreIdentity,
                   bindingTaskStoreIdentity != taskStoreIdentity {
                    guard taskSyncIsLatest() else {
                        telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                        return
                    }
                    try sessionStore.retireClaudeTaskList(
                        taskListID: previouslyBoundRecord.binding.taskListID,
                        taskStoreIdentity: bindingTaskStoreIdentity
                    )
                }
                guard taskSyncIsLatest() else {
                    telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                    return
                }
                try sessionStore.clearClaudeTaskDirectoryBindings(
                    directoryName: previouslyBoundRecord.binding.taskListID,
                    taskStoreIdentity: previouslyBoundRecord.binding.taskStoreIdentity
                )
                guard taskSyncIsLatest() else {
                    telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                    return
                }
                try sessionStore.removeClaudeTeamTaskListBinding(
                    previouslyBoundRecord.binding
                )
            }
        }
        return
    }
}
