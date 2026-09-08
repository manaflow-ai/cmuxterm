import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    func rollbackFirstSightingClaudeTaskSync(
        currentRecord: ClaudeHookSessionRecord?,
        boundRecord: ClaudeHookSessionRecord,
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        bindingSource: ClaudeTaskBindingSource,
        destinationBefore: ClaudeHookTaskListDestinationRecord?,
        destinationAfter: ClaudeHookTaskListDestinationRecord?,
        destinationWasRetired: Bool = false,
        teamBindingBefore: ClaudeHookTeamTaskBindingRecord? = nil,
        teamBindingAfter: ClaudeHookTeamTaskBindingRecord? = nil,
        sessionStore: ClaudeHookSessionStore
    ) {
        guard currentRecord == nil else { return }
        if let destinationAfter {
            _ = try? sessionStore.restoreClaudeTaskListDestinationRecord(
                before: destinationBefore,
                after: destinationAfter
            )
            if destinationWasRetired {
                try? sessionStore.retireClaudeTaskList(
                    taskListID: taskDirectoryName,
                    taskStoreIdentity: taskStoreIdentity
                )
            } else {
                try? sessionStore.unretireClaudeTaskList(
                    taskListID: taskDirectoryName,
                    taskStoreIdentity: taskStoreIdentity
                )
            }
        }
        if let teamBindingAfter {
            _ = try? sessionStore.restoreClaudeTeamTaskBinding(
                before: teamBindingBefore,
                after: teamBindingAfter
            )
        }
        _ = try? sessionStore.removeClaudeTaskSyncSessionIfMatching(
            sessionId: boundRecord.sessionId,
            expectedStartedAt: boundRecord.startedAt,
            directoryName: taskDirectoryName,
            taskStoreIdentity: taskStoreIdentity,
            source: bindingSource
        )
    }

    /// Clears every proven prior personal destination after its replacement succeeds.
    func clearSupersededPersonalClaudeTaskChecklistOwnerIfNeeded(
        currentRecord: ClaudeHookSessionRecord?,
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        currentWorkspaceID: String,
        recordedWorkspaceIDs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        deadlineUptime: TimeInterval
    ) -> Bool {
        let normalizedCurrentWorkspaceID = currentWorkspaceID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedCurrentWorkspaceID.isEmpty else { return false }
        var workspaceIDsByTaskDirectory: [String: Set<String>] = [:]
        for recordedWorkspaceID in recordedWorkspaceIDs {
            let normalizedWorkspaceID = recordedWorkspaceID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !normalizedWorkspaceID.isEmpty,
               normalizedWorkspaceID != normalizedCurrentWorkspaceID {
                workspaceIDsByTaskDirectory[taskDirectoryName, default: []]
                    .insert(normalizedWorkspaceID)
            }
        }
        let currentBindingIsPersonal: Bool
        switch currentRecord?.claudeTaskBindingSource {
        case .automaticTeam, .configuredList:
            currentBindingIsPersonal = false
        default:
            currentBindingIsPersonal = true
        }
        if currentBindingIsPersonal,
           let currentRecord,
           let previousTaskDirectoryName = currentRecord.claudeTaskDirectoryName,
           currentRecord.claudeTaskStoreID == taskStoreIdentity.rawValue {
            let previousWorkspaceID = currentRecord.workspaceId.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !previousWorkspaceID.isEmpty,
               previousTaskDirectoryName != taskDirectoryName
                || previousWorkspaceID != normalizedCurrentWorkspaceID {
                workspaceIDsByTaskDirectory[previousTaskDirectoryName, default: []]
                    .insert(previousWorkspaceID)
            }
        }
        for taskDirectory in workspaceIDsByTaskDirectory.keys.sorted() {
            guard let workspaceIDs = workspaceIDsByTaskDirectory[taskDirectory],
                  clearClaudeTaskChecklistOwner(
                    taskDirectoryName: taskDirectory,
                    taskStoreIdentity: taskStoreIdentity,
                    client: client,
                    telemetry: telemetry,
                    workspaceIDs: workspaceIDs.sorted(),
                    deadlineUptime: deadlineUptime
                  ).succeeded else { return false }
        }
        return true
    }

    /// Checks whether a retired list has a newer, authoritative owner.
    func canAdmitRetiredClaudeTaskList(
        taskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        currentRecord: ClaudeHookSessionRecord?,
        sessionID: String,
        agentID: String?,
        matchingTeamRecord: ClaudeHookTeamTaskBindingRecord?,
        sessionStore: ClaudeHookSessionStore,
        teamTaskResolver: ClaudeTeamTaskListResolver
    ) throws -> Bool {
        guard let retiredAt = try sessionStore.claudeTaskListRetiredAt(
            taskListID: taskListID,
            taskStoreIdentity: taskStoreIdentity
        ) else {
            return true
        }
        if let startedAt = currentRecord?.startedAt, startedAt > retiredAt {
            return true
        }
        if let matchingTeamRecord,
           matchingTeamRecord.updatedAt > retiredAt,
           let currentTeamBinding = try teamTaskResolver.currentTaskListBinding(
               forTaskListID: taskListID
           ),
           currentTeamBinding.matches(sessionID: sessionID, agentID: agentID) {
            return true
        }
        return false
    }

    /// Records a destination proof before any external owner mutation.
    func prepareClaudeTaskListDestination(
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        workspaceIDs: [String],
        retiredRecords: [ClaudeHookTaskListDestinationRecord],
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        deadlineUptime: TimeInterval
    ) throws -> Bool {
        guard try clearRetiredClaudeTaskListDestinations(
            retiredRecords,
            sessionStore: sessionStore,
            client: client,
            telemetry: telemetry,
            deadlineUptime: deadlineUptime
        ) else {
            return false
        }
        try persistClaudeTaskListDestinations(
            taskDirectoryName: taskDirectoryName,
            taskStoreIdentity: taskStoreIdentity,
            retainedWorkspaceIDs: workspaceIDs,
            sessionStore: sessionStore
        )
        return true
    }

    /// Clears bounded task-list proofs selected for durable-store retirement.
    func clearRetiredClaudeTaskListDestinations(
        _ retiredRecords: [ClaudeHookTaskListDestinationRecord],
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        deadlineUptime: TimeInterval
    ) throws -> Bool {
        for retiredRecord in retiredRecords {
            guard !retiredRecord.workspaceIDs.isEmpty else {
                try sessionStore.removeClaudeTaskListDestinationRecord(retiredRecord)
                continue
            }
            let cleanup = clearClaudeTaskChecklistOwner(
                taskDirectoryName: retiredRecord.taskListID,
                taskStoreIdentity: retiredRecord.taskStoreIdentity,
                client: client,
                telemetry: telemetry,
                workspaceIDs: retiredRecord.workspaceIDs,
                deadlineUptime: deadlineUptime
            )
            if cleanup.succeeded {
                try sessionStore.removeClaudeTaskListDestinationRecord(retiredRecord)
            } else {
                try sessionStore.retainClaudeTaskListDestinations(
                    cleanup.retainedWorkspaceIDs,
                    for: retiredRecord
                )
                return false
            }
        }
        return true
    }

    /// Persists only destinations that may still carry one task-list owner.
    func persistClaudeTaskListDestinations(
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        retainedWorkspaceIDs: [String],
        sessionStore: ClaudeHookSessionStore
    ) throws {
        if !retainedWorkspaceIDs.isEmpty {
            try sessionStore.commitClaudeTaskListDestinations(
                taskListID: taskDirectoryName,
                taskStoreIdentity: taskStoreIdentity,
                workspaceIDs: retainedWorkspaceIDs
            )
        } else if let destinationRecord = try sessionStore
            .claudeTaskListDestinationRecord(
                taskListID: taskDirectoryName,
                taskStoreIdentity: taskStoreIdentity
            ) {
            try sessionStore.removeClaudeTaskListDestinationRecord(destinationRecord)
        }
    }

    /// Retries one retained automatic-team owner and preserves failed destinations.
    func clearRetainedClaudeTeamTaskOwner(
        binding: ClaudeTeamTaskListBinding,
        workspaceIDs: [String],
        retirementTaskStoreIdentity: ClaudeTaskStoreIdentity,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        deadlineUptime: TimeInterval
    ) throws -> Bool {
        let cleanup = clearClaudeTaskChecklistOwner(
            taskDirectoryName: binding.taskListID,
            taskStoreIdentity: binding.taskStoreIdentity,
            client: client,
            telemetry: telemetry,
            workspaceIDs: workspaceIDs,
            deadlineUptime: deadlineUptime
        )
        let retryWorkspaceIDs: [String]
        if cleanup.succeeded {
            retryWorkspaceIDs = cleanup.retainedWorkspaceIDs
        } else if cleanup.retainedWorkspaceIDs.isEmpty {
            // A transport/protocol failure can occur before the response is
            // decoded. Keep the original destinations as the durable retry
            // proof instead of dropping the binding with an empty set.
            retryWorkspaceIDs = workspaceIDs
        } else {
            retryWorkspaceIDs = cleanup.retainedWorkspaceIDs
        }
        try sessionStore.retainClaudeTeamTaskBindingWorkspaces(
            retryWorkspaceIDs,
            for: binding
        )
        if !cleanup.succeeded {
            // Retired team records are the SessionEnd retry owner. Mark the
            // binding retired even when the first external cleanup attempt
            // fails; the binding itself remains until a retry succeeds.
            try sessionStore.retireClaudeTaskList(
                taskListID: binding.taskListID,
                taskStoreIdentity: retirementTaskStoreIdentity
            )
        }
        if cleanup.succeeded {
            try sessionStore.clearClaudeTaskDirectoryBindings(
                directoryName: binding.taskListID,
                taskStoreIdentity: binding.taskStoreIdentity
            )
            if binding.taskStoreIdentity == nil {
                try sessionStore.clearClaudeTaskDirectoryBindings(
                    directoryName: binding.taskListID,
                    taskStoreIdentity: nil
                )
            }
            try sessionStore.retireClaudeTaskList(
                taskListID: binding.taskListID,
                taskStoreIdentity: retirementTaskStoreIdentity
            )
            try sessionStore.removeClaudeTeamTaskListBinding(binding)
        }
        return cleanup.succeeded
    }

    /// Clears one pre-profile owner before namespaced reconciliation.
    func migrateLegacyClaudeTaskChecklistOwnerIfNeeded(
        currentRecord: ClaudeHookSessionRecord?,
        sessionID: String,
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        workspaceIDs: [String],
        deadlineUptime: TimeInterval
    ) throws -> Bool {
        var legacyDirectoryNames: Set<String> = [taskDirectoryName]
        let currentLegacyDirectoryName: String?
        if currentRecord?.claudeTaskStoreID == nil {
            currentLegacyDirectoryName = currentRecord?.claudeTaskDirectoryName
            if let currentLegacyDirectoryName {
                legacyDirectoryNames.insert(currentLegacyDirectoryName)
            }
        } else {
            currentLegacyDirectoryName = nil
        }
        for legacyDirectoryName in legacyDirectoryNames.sorted() {
            let cleared = try clearLegacyClaudeTaskChecklistOwnerIfNeeded(
                taskDirectoryName: legacyDirectoryName,
                sessionStore: sessionStore,
                client: client,
                telemetry: telemetry,
                workspaceIDs: workspaceIDs
                    + (currentRecord.map { [$0.workspaceId] } ?? []),
                deadlineUptime: deadlineUptime
            )
            if !cleared {
                telemetry.breadcrumb("claude-hook.task-sync.legacy-owner-cleanup-deferred")
                // Never bind the replacement owner while the old owner may
                // still have rows. The durable continuation will be retried
                // by the next matching task/SessionEnd hook.
                return false
            }
            let remainingWorkspaceIDs = try sessionStore.legacyClaudeTaskOwnerWorkspaceIDs(
                directoryName: legacyDirectoryName,
                including: [],
                includeFallbackDestinations: false
            )
            guard remainingWorkspaceIDs.isEmpty else {
                telemetry.breadcrumb(
                    "claude-hook.task-sync.legacy-owner-cleanup-deferred"
                )
                return false
            }
        }
        return true
    }

    /// Stamps the current session after its replacement reconciliation succeeds.
    func markLegacyClaudeTaskChecklistOwnerMigratedIfNeeded(
        currentRecord: ClaudeHookSessionRecord?,
        sessionID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        sessionStore: ClaudeHookSessionStore
    ) throws -> Bool {
        guard currentRecord?.claudeTaskStoreID == nil,
              let legacyDirectoryName = currentRecord?.claudeTaskDirectoryName else {
            return true
        }
        let marked = try sessionStore.markLegacyClaudeTaskDirectoryMigrated(
            sessionId: sessionID,
            directoryName: legacyDirectoryName,
            taskStoreIdentity: taskStoreIdentity,
            expectedStartedAt: currentRecord?.startedAt
        )
        if marked { return true }
        // Binding may have replaced the legacy directory with a newly
        // resolved owner before this post-commit stamp. Treat that durable
        // namespaced record as an already-completed migration.
        guard let refreshedRecord = try sessionStore.lookup(sessionId: sessionID),
              refreshedRecord.startedAt == currentRecord?.startedAt else {
            return false
        }
        return refreshedRecord.claudeTaskStoreID == taskStoreIdentity.rawValue
    }

    /// Clears one legacy owner from every recorded destination in bounded batches.
}
