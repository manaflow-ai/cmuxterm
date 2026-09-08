import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    func runClaudeTaskSyncConfiguredList(
        _ operation: ClaudeTaskSyncOperation
    ) throws {
        let client = operation.client
        let telemetry = operation.telemetry
        let parsedInput = operation.parsedInput
        let sessionStore = operation.sessionStore
        let socketPassword = operation.socketPassword
        let sessionID = operation.sessionID
        let resolvedTarget = operation.resolvedTarget
        let loader = operation.loader
        let teamsRootURL = operation.teamsRootURL
        let taskStoreIdentity = operation.taskStoreIdentity
        let agentID = operation.agentID
        let configuredTaskDirectoryName = operation.configuredTaskDirectoryName
        let hookDeadlineUptime = operation.hookDeadlineUptime
        let taskHookPID = operation.taskHookPID
        let currentRecord = operation.currentRecord
        let taskSyncIsLatest = operation.isLatest
        let retargetTaskSyncClaim = operation.retarget
        guard let configuredTaskListID = operation.configuredTaskListID else { return }
        guard let configuredTaskDirectoryName else {
            telemetry.breadcrumb("claude-hook.task-sync.task-directory-unresolved")
            return
        }
        let matchingTeamRecord = try sessionStore.claudeTeamTaskBindingRecord(
            taskListID: configuredTaskDirectoryName,
            taskStoreIdentity: taskStoreIdentity
        )
        let configuredTaskResolver = ClaudeTeamTaskListResolver(
            teamsRootURL: teamsRootURL,
            taskStoreIdentity: taskStoreIdentity,
            deadlineUptime: hookDeadlineUptime
        )
        guard try canAdmitRetiredClaudeTaskList(
            taskListID: configuredTaskDirectoryName,
            taskStoreIdentity: taskStoreIdentity,
            currentRecord: currentRecord,
            sessionID: sessionID,
            agentID: agentID,
            matchingTeamRecord: matchingTeamRecord,
            sessionStore: sessionStore,
            teamTaskResolver: configuredTaskResolver
        ) else {
            telemetry.breadcrumb("claude-hook.task-sync.retired-task-directory")
            return
        }
        guard let snapshot = try loader.loadKnownTaskList(
            taskListID: configuredTaskListID
        ) else {
            telemetry.breadcrumb("claude-hook.task-sync.task-directory-unresolved")
            return
        }
        let destinationTransition = try sessionStore
            .claudeTaskListDestinationTransition(
                taskListID: snapshot.directoryName,
                taskStoreIdentity: taskStoreIdentity,
                including: (matchingTeamRecord?.workspaceIDs ?? [])
                    + [resolvedTarget.workspaceId]
        )
        let destinationWorkspaceIDs = destinationTransition.workspaceIDs
        guard try retargetTaskSyncClaim(snapshot.directoryName) else {
            telemetry.breadcrumb("claude-hook.task-sync.coalesce-transfer-failed")
            return
        }
        guard taskSyncIsLatest() else {
            telemetry.breadcrumb("claude-hook.task-sync.coalesced")
            return
        }
        guard try migrateLegacyClaudeTaskChecklistOwnerIfNeeded(
            currentRecord: currentRecord,
            sessionID: sessionID,
            taskDirectoryName: snapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity,
            sessionStore: sessionStore,
            client: client,
            telemetry: telemetry,
            workspaceIDs: destinationWorkspaceIDs,
            deadlineUptime: hookDeadlineUptime
        ) else { return }
        guard taskSyncIsLatest() else {
            telemetry.breadcrumb("claude-hook.task-sync.coalesced")
            return
        }
        let destinationWasRetired = try sessionStore.isClaudeTaskListRetired(
            taskListID: snapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity
        )
        let destinationRecordBeforePrepare = try sessionStore
            .claudeTaskListDestinationRecord(
                taskListID: snapshot.directoryName,
                taskStoreIdentity: taskStoreIdentity
            )
        guard try prepareClaudeTaskListDestination(
            taskDirectoryName: snapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity,
            workspaceIDs: destinationWorkspaceIDs,
            retiredRecords: destinationTransition.retiredRecords,
            sessionStore: sessionStore,
            client: client,
            telemetry: telemetry,
            deadlineUptime: hookDeadlineUptime
        ) else { return }
        let destinationRecordAfterPrepare = try sessionStore
            .claudeTaskListDestinationRecord(
                taskListID: snapshot.directoryName,
                taskStoreIdentity: taskStoreIdentity
            )
        guard let boundRecord = try sessionStore.bindClaudeTaskDirectory(
            sessionId: sessionID,
            directoryName: snapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity,
            workspaceId: resolvedTarget.workspaceId,
            surfaceId: resolvedTarget.surfaceId,
            pid: taskHookPID,
            expectedStartedAt: currentRecord?.startedAt,
            source: .configuredList
        ) else {
            telemetry.breadcrumb("claude-hook.task-sync.session-ended")
            return
        }
        if operation.taskHookStartedAt == nil {
            operation.taskHookStartedAt = boundRecord.startedAt
        }
        guard taskSyncIsLatest() else {
            rollbackFirstSightingClaudeTaskSync(
                currentRecord: currentRecord,
                boundRecord: boundRecord,
                taskDirectoryName: snapshot.directoryName,
                taskStoreIdentity: taskStoreIdentity,
                bindingSource: .configuredList,
                destinationBefore: destinationRecordBeforePrepare,
                destinationAfter: destinationRecordAfterPrepare,
                destinationWasRetired: destinationWasRetired,
                sessionStore: sessionStore
            )
            telemetry.breadcrumb("claude-hook.task-sync.coalesced")
            return
        }
        guard let delivery = deliverClaudeTaskSnapshot(
            snapshot,
            taskStoreIdentity: taskStoreIdentity,
            client: client,
            telemetry: telemetry,
            parsedInput: parsedInput,
            workspaceId: resolvedTarget.workspaceId,
            surfaceId: resolvedTarget.surfaceId,
            reconciliationWorkspaceIDs: destinationWorkspaceIDs,
            socketPassword: socketPassword,
            deadlineUptime: hookDeadlineUptime
        ) else {
            rollbackFirstSightingClaudeTaskSync(
                currentRecord: currentRecord,
                boundRecord: boundRecord,
                taskDirectoryName: snapshot.directoryName,
                taskStoreIdentity: taskStoreIdentity,
                bindingSource: .configuredList,
                destinationBefore: destinationRecordBeforePrepare,
                destinationAfter: destinationRecordAfterPrepare,
                destinationWasRetired: destinationWasRetired,
                sessionStore: sessionStore
            )
            return
        }
        guard taskSyncIsLatest() else {
            telemetry.breadcrumb("claude-hook.task-sync.coalesced")
            return
        }
        // Publish the replacement before clearing a prior personal owner. If
        // the replacement delivery fails, the old checklist remains visible
        // and its durable proof can be retried by a later hook.
        if !clearSupersededPersonalClaudeTaskChecklistOwnerIfNeeded(
            currentRecord: currentRecord,
            taskDirectoryName: snapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity,
            currentWorkspaceID: resolvedTarget.workspaceId,
            recordedWorkspaceIDs: [],
            client: client,
            telemetry: telemetry,
            deadlineUptime: hookDeadlineUptime
        ) {
            telemetry.breadcrumb("claude-hook.task-sync.personal-owner-cleanup-deferred")
        }
        try persistClaudeTaskListDestinations(
            taskDirectoryName: snapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity,
            retainedWorkspaceIDs: delivery.retainedWorkspaceIDs,
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
        return
    }
}
