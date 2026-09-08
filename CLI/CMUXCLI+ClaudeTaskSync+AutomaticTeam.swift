import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    func runClaudeTaskSyncAutomaticTeam(
        _ operation: ClaudeTaskSyncOperation,
        automaticTeamResolution: ClaudeTeamTaskListResolution
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
        let hookDeadlineUptime = operation.hookDeadlineUptime
        let taskHookPID = operation.taskHookPID
        let currentRecord = operation.currentRecord
        let taskSyncIsLatest = operation.isLatest
        guard let snapshot = try loader.loadKnownTaskList(
            taskListID: automaticTeamResolution.binding.taskListID
        ) else {
            telemetry.breadcrumb("claude-hook.task-sync.task-directory-unresolved")
            return
        }
        let transition = try sessionStore.claudeTeamTaskBindingTransition(
            automaticTeamResolution.binding,
            workspaceId: resolvedTarget.workspaceId
        )
        for retiredRecord in transition.retiredRecords {
            let retiredWorkspaceIDs = retiredRecord.workspaceIDs.isEmpty
                ? [resolvedTarget.workspaceId]
                : retiredRecord.workspaceIDs
            guard clearClaudeTaskChecklistOwner(
                taskDirectoryName: retiredRecord.binding.taskListID,
                taskStoreIdentity: retiredRecord.binding.taskStoreIdentity,
                client: client,
                telemetry: telemetry,
                workspaceIDs: retiredWorkspaceIDs,
                deadlineUptime: hookDeadlineUptime
            ).succeeded else { return }
        }
        guard taskSyncIsLatest() else {
            telemetry.breadcrumb("claude-hook.task-sync.coalesced")
            return
        }
        let teamBindingBeforeCommit = try sessionStore.claudeTeamTaskBindingRecord(
            taskListID: snapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity
        )
        let teamWorkspaceIDs = try sessionStore.commitClaudeTeamTaskListBinding(
            automaticTeamResolution.binding,
            workspaceIDs: transition.workspaceIDs,
            retiredRecords: transition.retiredRecords
        )
        let teamBindingAfterCommit = try sessionStore.claudeTeamTaskBindingRecord(
            taskListID: snapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity
        )
        guard try migrateLegacyClaudeTaskChecklistOwnerIfNeeded(
            currentRecord: currentRecord,
            sessionID: sessionID,
            taskDirectoryName: snapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity,
            sessionStore: sessionStore,
            client: client,
            telemetry: telemetry,
            workspaceIDs: teamWorkspaceIDs,
            deadlineUptime: hookDeadlineUptime
        ) else { return }
        guard taskSyncIsLatest() else {
            telemetry.breadcrumb("claude-hook.task-sync.coalesced")
            return
        }
        guard let boundRecord = try sessionStore.bindClaudeTaskDirectory(
            sessionId: sessionID,
            directoryName: snapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity,
            workspaceId: resolvedTarget.workspaceId,
            surfaceId: resolvedTarget.surfaceId,
            pid: taskHookPID,
            expectedStartedAt: currentRecord?.startedAt,
            source: .automaticTeam
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
                bindingSource: .automaticTeam,
                destinationBefore: nil,
                destinationAfter: nil,
                teamBindingBefore: teamBindingBeforeCommit,
                teamBindingAfter: teamBindingAfterCommit,
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
            reconciliationWorkspaceIDs: teamWorkspaceIDs,
            socketPassword: socketPassword,
            deadlineUptime: hookDeadlineUptime
        ) else {
            rollbackFirstSightingClaudeTaskSync(
                currentRecord: currentRecord,
                boundRecord: boundRecord,
                taskDirectoryName: snapshot.directoryName,
                taskStoreIdentity: taskStoreIdentity,
                bindingSource: .automaticTeam,
                destinationBefore: nil,
                destinationAfter: nil,
                teamBindingBefore: teamBindingBeforeCommit,
                teamBindingAfter: teamBindingAfterCommit,
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
            // Team transition destinations are owned by the shared
            // team proof and are cleaned independently below. They
            // are not prior personal destinations.
            recordedWorkspaceIDs: [],
            client: client,
            telemetry: telemetry,
            deadlineUptime: hookDeadlineUptime
        ) {
            telemetry.breadcrumb("claude-hook.task-sync.personal-owner-cleanup-deferred")
        }
        try sessionStore.retainClaudeTeamTaskBindingWorkspaces(
            delivery.retainedWorkspaceIDs,
            for: automaticTeamResolution.binding
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
