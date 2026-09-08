import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    func clearLegacyClaudeTaskChecklistOwnerIfNeeded(
        taskDirectoryName: String,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        workspaceIDs: [String],
        includeFallbackDestinations: Bool = false,
        ignoreRetrySchedule: Bool = false,
        deadlineUptime: TimeInterval
    ) throws -> Bool {
        if !ignoreRetrySchedule {
            guard try sessionStore.isLegacyClaudeTaskOwnerCleanupEligible(
                directoryName: taskDirectoryName
            ) else {
                telemetry.breadcrumb("claude-hook.task-sync.legacy-owner-cleanup-backoff")
                return false
            }
        }
        let recordedWorkspaceIDs = try sessionStore.legacyClaudeTaskOwnerWorkspaceIDs(
            directoryName: taskDirectoryName,
            including: workspaceIDs,
            includeFallbackDestinations: includeFallbackDestinations
        )
        guard !recordedWorkspaceIDs.isEmpty else {
            _ = try sessionStore.setLegacyClaudeTaskOwnerCleanupPending(
                directoryName: taskDirectoryName,
                pending: false
            )
            return true
        }
        guard try sessionStore.setLegacyClaudeTaskOwnerCleanupPending(
            directoryName: taskDirectoryName,
            workspaceIDs: recordedWorkspaceIDs,
            pending: true
        ) else {
            telemetry.breadcrumb("claude-hook.task-sync.legacy-owner-cleanup-capacity")
            return false
        }
        let batchSize = ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount
        let batchWorkspaceIDs = Array(recordedWorkspaceIDs.prefix(batchSize))
        let remainingWorkspaceIDs = Array(recordedWorkspaceIDs.dropFirst(batchSize))
        let cleanup = clearClaudeTaskChecklistOwner(
            taskDirectoryName: taskDirectoryName,
            taskStoreIdentity: nil,
            client: client,
            telemetry: telemetry,
            workspaceIDs: batchWorkspaceIDs,
            deadlineUptime: deadlineUptime
        )
        // A successful empty-owner reconciliation removes the rows but the
        // shared helper deliberately reports those destinations as retained
        // proofs for its other callers. Only an all-successful page is safe to
        // advance; on a partial failure retry the whole page conservatively.
        if cleanup.succeeded {
            try sessionStore.markLegacyClaudeTaskOwnerCleared(
                directoryName: taskDirectoryName,
                workspaceIDs: batchWorkspaceIDs
            )
            try sessionStore.markLegacyClaudeTaskOwnerDestinationProofsCleared(
                directoryName: taskDirectoryName,
                workspaceIDs: batchWorkspaceIDs
            )
        }
        let retryWorkspaceIDs: [String]
        if cleanup.succeeded {
            retryWorkspaceIDs = remainingWorkspaceIDs
        } else {
            let failedBatchWorkspaceIDs = cleanup.retainedWorkspaceIDs.isEmpty
                ? batchWorkspaceIDs
                : cleanup.retainedWorkspaceIDs
            retryWorkspaceIDs = Array(
                Set(failedBatchWorkspaceIDs + remainingWorkspaceIDs)
            ).sorted()
        }
        guard try sessionStore.setLegacyClaudeTaskOwnerCleanupPending(
            directoryName: taskDirectoryName,
            workspaceIDs: retryWorkspaceIDs,
            pending: !retryWorkspaceIDs.isEmpty,
            retry: !cleanup.succeeded,
            replaceWorkspaceIDs: cleanup.succeeded
        ) else {
            telemetry.breadcrumb("claude-hook.task-sync.legacy-owner-cleanup-capacity")
            return false
        }
        if cleanup.succeeded, retryWorkspaceIDs.isEmpty {
            try sessionStore.removeLegacyClaudeTaskOwnerDestinationProofs(
                directoryName: taskDirectoryName
            )
        }
        if !retryWorkspaceIDs.isEmpty {
            telemetry.breadcrumb("claude-hook.task-sync.legacy-owner-cleanup-continued")
        }
        // One bounded page is enough for this hook. The exact remaining IDs are
        // durable even if all corresponding session records are rebound before
        // the next task event.
        return cleanup.succeeded
    }

    /// Drains legacy cleanup pages while the terminal TeamDelete hook still
    /// owns its deadline. A normal task event uses one page; deletion gets the
    /// bounded continuation opportunity so a list with many destinations does
    /// not depend on a future task mutation that may never arrive.
    func drainLegacyClaudeTaskChecklistOwner(
        taskDirectoryName: String,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        workspaceIDs: [String],
        includeFallbackDestinations: Bool = false,
        deadlineUptime: TimeInterval
    ) throws -> Bool {
        var initialWorkspaceIDs = workspaceIDs
        while true {
            guard try clearLegacyClaudeTaskChecklistOwnerIfNeeded(
                taskDirectoryName: taskDirectoryName,
                sessionStore: sessionStore,
                client: client,
                telemetry: telemetry,
                workspaceIDs: initialWorkspaceIDs,
                includeFallbackDestinations: includeFallbackDestinations,
                ignoreRetrySchedule: true,
                deadlineUptime: deadlineUptime
            ) else {
                return false
            }
            let remainingWorkspaceIDs = try sessionStore.legacyClaudeTaskOwnerWorkspaceIDs(
                directoryName: taskDirectoryName,
                including: [],
                includeFallbackDestinations: false
            )
            guard !remainingWorkspaceIDs.isEmpty else { return true }
            guard ProcessInfo.processInfo.systemUptime < deadlineUptime else {
                telemetry.breadcrumb("claude-hook.task-sync.legacy-owner-cleanup-deferred")
                return false
            }
            // The first pass prioritizes the current deletion destinations;
            // subsequent pages come solely from the durable cursor.
            initialWorkspaceIDs = []
        }
    }

    /// Gives SessionEnd one bounded, independent retry owner for legacy
    /// destinations left behind by a terminal TeamDelete. The queue claim
    /// applies its durable backoff, so repeated lifecycle hooks do not hammer a
    /// failing workspace while a later teardown can still make progress.
    func retryPendingClaudeLegacyTaskCleanup(
        sessionStore: ClaudeHookSessionStore,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        deadlineUptime: TimeInterval
    ) {
        guard ProcessInfo.processInfo.systemUptime < deadlineUptime else { return }
        do {
            try sessionStore.withClaudeTaskSyncLock(
                deadlineUptime: deadlineUptime,
                scope: taskStoreIdentity.rawValue
            ) {
                if let pendingCleanup = try sessionStore
                    .nextLegacyClaudeTaskOwnerCleanup() {
                    // The claim above advances its retry timestamp before
                    // external I/O; drain explicitly bypasses that timestamp
                    // so the worker can process the record it just claimed.
                    _ = try? drainLegacyClaudeTaskChecklistOwner(
                        taskDirectoryName: pendingCleanup.directoryName,
                        sessionStore: sessionStore,
                        client: client,
                        telemetry: telemetry,
                        workspaceIDs: pendingCleanup.workspaceIDs,
                        deadlineUptime: deadlineUptime
                    )
                }
                let retiredDestinations = try sessionStore
                    .allRetiredClaudeTaskListDestinationRecords()
                    .sorted {
                        let lhsIdentity = $0.taskStoreIdentity?.rawValue ?? ""
                        let rhsIdentity = $1.taskStoreIdentity?.rawValue ?? ""
                        if lhsIdentity != rhsIdentity { return lhsIdentity < rhsIdentity }
                        return $0.taskListID < $1.taskListID
                    }
                if !retiredDestinations.isEmpty,
                   ProcessInfo.processInfo.systemUptime < deadlineUptime {
                    let index = Int(Date.now.timeIntervalSince1970 / 60)
                        % retiredDestinations.count
                    let record = retiredDestinations[index]
                    if let cleanupIdentity = record.taskStoreIdentity {
                        let cleanup = drainClaudeTaskChecklistOwner(
                            taskDirectoryName: record.taskListID,
                            taskStoreIdentity: cleanupIdentity,
                            client: client,
                            telemetry: telemetry,
                            workspaceIDs: record.workspaceIDs,
                            deadlineUptime: deadlineUptime
                        )
                        if cleanup.succeeded, cleanup.completed {
                            try sessionStore.clearClaudeTaskDirectoryBindings(
                                directoryName: record.taskListID,
                                taskStoreIdentity: cleanupIdentity
                            )
                            try sessionStore.removeClaudeTaskListDestinationRecord(record)
                        }
                    }
                }
                let retiredTeams = try sessionStore
                    .retiredClaudeTeamTaskBindingRecords(
                        taskStoreIdentity: taskStoreIdentity
                    ).sorted {
                        $0.binding.taskListID < $1.binding.taskListID
                    }
                if !retiredTeams.isEmpty,
                   ProcessInfo.processInfo.systemUptime < deadlineUptime {
                    let index = Int(Date.now.timeIntervalSince1970 / 60)
                        % retiredTeams.count
                    let record = retiredTeams[index]
                    let cleanup = drainClaudeTaskChecklistOwner(
                        taskDirectoryName: record.binding.taskListID,
                        taskStoreIdentity: taskStoreIdentity,
                        client: client,
                        telemetry: telemetry,
                        workspaceIDs: record.workspaceIDs,
                        deadlineUptime: deadlineUptime
                    )
                    if cleanup.succeeded, cleanup.completed {
                        try sessionStore.clearClaudeTaskDirectoryBindings(
                            directoryName: record.binding.taskListID,
                            taskStoreIdentity: taskStoreIdentity
                        )
                        try sessionStore.removeClaudeTeamTaskListBinding(record.binding)
                    }
                }
            }
        } catch {
            telemetry.breadcrumb(
                "claude-hook.task-sync.legacy-owner-cleanup-retry-failed",
                data: ["error": String(describing: error)]
            )
        }
    }

    /// Validates and publishes one authoritative task snapshot to Feed and
    /// workspace todos.
    ///
    /// The preview uses the same owner-scoped reconciliation code as the real
    /// mutation but does not commit it. This prevents an over-cap checklist
    /// rejection from advancing Feed first and leaving the two projections at
    /// different revisions.
}
