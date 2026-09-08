import CMUXAgentLaunch
import CryptoKit
import Foundation

extension CMUXCLI {
    /// Monotonic budget reserved for the complete asynchronous task hook.
    static let claudeTaskSyncResponseBudgetSeconds: TimeInterval = 8
    /// Reserved for durable proof writes after terminal cleanup pages finish.
    static let claudeTaskSyncPersistenceMarginSeconds: TimeInterval = 0.5
    /// SessionEnd waits beyond the task hook's complete eight-second budget.
    static let claudeSessionEndTaskSyncLockBudgetSeconds: TimeInterval = 9
    /// SessionStart shares the task lease so generation replacement cannot
    /// race a task snapshot's final visibility check.
    static let claudeSessionStartTaskSyncLockBudgetSeconds: TimeInterval = 9

    /// Whether one parsed CLI invocation is the Claude task-sync hook.
    static func isClaudeTaskSyncHookCommand(
        command: String,
        commandArgs: [String]
    ) -> Bool {
        switch command.lowercased() {
        case "claude-hook":
            return commandArgs.first?.lowercased() == "task-sync"
        case "hooks":
            return commandArgs.first?.lowercased() == "claude"
                && commandArgs.dropFirst().first?.lowercased() == "task-sync"
        default:
            return false
        }
    }

    /// Whether a CLI invocation is the Claude SessionEnd lifecycle hook.
    static func isClaudeSessionEndHookCommand(
        command: String,
        commandArgs: [String]
    ) -> Bool {
        switch command.lowercased() {
        case "claude-hook":
            return commandArgs.first?.lowercased() == "session-end"
        case "hooks":
            return commandArgs.first?.lowercased() == "claude"
                && commandArgs.dropFirst().first?.lowercased() == "session-end"
        default:
            return false
        }
    }

    /// Reconciles Claude Code's per-file task store into cmux's two todo views.
    ///
    /// A full filesystem snapshot is published to both Feed and the workspace
    /// checklist so neither consumer has to reimplement TaskCreate/TaskUpdate
    /// accumulation semantics.
    func runClaudeTaskSyncHook(
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        parsedInput: ClaudeHookParsedInput,
        sessionStore: ClaudeHookSessionStore,
        routing: ClaudeHookRoutingContext,
        socketPassword: String?,
        markFeedTelemetryHandled: () -> Void
    ) {
        telemetry.breadcrumb("claude-hook.task-sync")
        markFeedTelemetryHandled()
        // The shared CLI path installs this before socket setup. Retain that
        // original deadline here; direct callers still receive the same bound.
        let hookDeadlineUptime = client.enforceResponseDeadline(
            untilUptime: ProcessInfo.processInfo.systemUptime
                + Self.claudeTaskSyncResponseBudgetSeconds
        )
        sessionStore.enforceLockDeadline(untilUptime: hookDeadlineUptime)

        guard let sessionID = nonEmptyClaudeHookIdentifier(parsedInput.sessionId) else {
            telemetry.breadcrumb("claude-hook.task-sync.missing-session")
            printClaudeHookAck()
            return
        }

        do {
            let taskSyncSessionEntry = try sessionStore.claudeTaskSyncSessionEntry(
                sessionId: sessionID
            )
            let mappedSession = taskSyncSessionEntry.record
            var taskRouting = routing
            taskRouting.allowsPidProbe = false
            guard let resolvedTarget = try resolveClaudeHookDeliveryTarget(
                mappedSession: mappedSession,
                routing: taskRouting,
                client: client
            ), resolvedTarget.isAuthoritative else {
                telemetry.breadcrumb("claude-hook.task-sync.unresolved")
                printClaudeHookAck()
                return
            }

            let environment = ProcessInfo.processInfo.environment
            let configuredTaskListID = environment["CLAUDE_CODE_TASK_LIST_ID"].flatMap {
                $0.isEmpty ? nil : $0
            }
            let taskRootResolver = ClaudeTaskRootResolver(
                environment: environment,
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
            )
            let tasksRootURL = taskRootResolver.resolve()
            let teamsRootURL = taskRootResolver.resolveTeamsRoot()
            let loader = ClaudeTaskSnapshotLoader(
                tasksRootURL: tasksRootURL,
                deadlineUptime: hookDeadlineUptime
            )
            let configuredTaskDirectoryName = configuredTaskListID.flatMap {
                loader.canonicalDirectoryName(forTaskListID: $0)
            } ?? claudeTaskCompletedTeamDirectoryName(
                from: parsedInput,
                loader: loader
            )
            let deletedTeamTaskDirectoryName = claudeTeamDeleteTaskDirectoryName(
                from: parsedInput,
                loader: loader
            )
            let taskStoreIdentity = ClaudeTaskStoreIdentity(
                tasksRootURL: tasksRootURL,
                hostNamespace: client.taskStoreHostNamespace
            )
            let agentID = nonEmptyClaudeHookIdentifier(
                parsedInput.rawObject?["agent_id"] as? String
            )
            let taskIdentity = claudeTaskIdentity(from: parsedInput.rawObject)
            let isTeamDeleteHook = isClaudeTeamDeleteHook(parsedInput)
            let coalescingTaskListID = deletedTeamTaskDirectoryName
                ?? configuredTaskDirectoryName
            let taskStoreScope = taskStoreIdentity.rawValue
            let taskSyncScanIdentity = Data(
                "\(sessionID.utf8.count):\(sessionID)\((agentID ?? "").utf8.count):\(agentID ?? "")".utf8
            ).base64EncodedString()
            // Until the authoritative task list is known, every hook keeps an
            // identity-qualified scan scope. Independent automatic teams must
            // not supersede one another's first snapshot.
            let taskSyncScanScope = taskStoreScope
                + ":<task-sync-scan>:" + taskSyncScanIdentity
            let initialCoalescingScope = coalescingTaskListID.map {
                taskStoreScope + ":" + $0
            } ?? taskSyncScanScope
            let operation = ClaudeTaskSyncOperation(
                client: client,
                telemetry: telemetry,
                parsedInput: parsedInput,
                sessionStore: sessionStore,
                socketPassword: socketPassword,
                sessionID: sessionID,
                mappedSession: mappedSession,
                resolvedTarget: resolvedTarget,
                loader: loader,
                teamsRootURL: teamsRootURL,
                taskStoreIdentity: taskStoreIdentity,
                agentID: agentID,
                taskIdentity: taskIdentity,
                configuredTaskListID: configuredTaskListID,
                configuredTaskDirectoryName: configuredTaskDirectoryName,
                deletedTeamTaskDirectoryName: deletedTeamTaskDirectoryName,
                isTeamDeleteHook: isTeamDeleteHook,
                initialCoalescingScope: initialCoalescingScope,
                hookDeadlineUptime: hookDeadlineUptime,
                taskHookStartedAfterSessionEnd: taskSyncSessionEntry.ended && !isTeamDeleteHook,
                taskHookPID: claudeAgentPID(from: environment)
            )
            if let taskHookStartedAt = operation.taskHookStartedAt, !isTeamDeleteHook {
                guard (try? sessionStore.isClaudeTaskHookProcessCurrent(
                    sessionId: sessionID,
                    expectedStartedAt: taskHookStartedAt,
                    hookPID: operation.taskHookPID,
                    validateProcessIdentity: !client.isRelayBacked
                )) == true else {
                    telemetry.breadcrumb("claude-hook.task-sync.process-generation-mismatch")
                    printClaudeHookAck()
                    return
                }
            }
            try operation.claimInitial()
            defer { operation.finishClaim() }
            // Claude launches hooks in separate processes. Preserve the scoped
            // lease while branch handlers perform their bounded socket work.
            try sessionStore.withClaudeTaskSyncLock(
                deadlineUptime: hookDeadlineUptime,
                scope: initialCoalescingScope
            ) { lease in
                operation.taskSyncLease = lease
                defer { operation.taskSyncLease = nil }
                guard operation.isLatest() else {
                    telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                    return
                }
                operation.currentRecord = try sessionStore.lookup(sessionId: sessionID)
                if isTeamDeleteHook {
                    try runClaudeTaskSyncTeamDelete(operation)
                    return
                }
                if configuredTaskListID != nil {
                    try runClaudeTaskSyncConfiguredList(operation)
                    return
                }
                let previouslyBoundRecord = try sessionStore.claudeTeamTaskBindingRecord(
                    sessionId: sessionID,
                    agentId: agentID,
                    taskStoreIdentity: taskStoreIdentity
                )
                // Team membership is authoritative; inspect it before accepting
                // a colliding task identity in a personal list.
                let automaticTeamResolution = try ClaudeTeamTaskListResolver(
                    teamsRootURL: teamsRootURL,
                    taskStoreIdentity: taskStoreIdentity,
                    deadlineUptime: hookDeadlineUptime
                ).resolveTaskListBinding(
                    sessionID: sessionID,
                    agentID: agentID,
                    previouslyBoundBinding: previouslyBoundRecord?.binding
                )
                if let automaticTeamResolution {
                    guard try operation.retarget(to: automaticTeamResolution.binding.taskListID),
                          operation.isLatest() else {
                        telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                        return
                    }
                    if !automaticTeamResolution.usesRetainedCleanupProof {
                        try runClaudeTaskSyncAutomaticTeam(
                            operation,
                            automaticTeamResolution: automaticTeamResolution
                        )
                        return
                    }
                }
                try runClaudeTaskSyncPersonalList(
                    operation,
                    previouslyBoundRecord: previouslyBoundRecord,
                    automaticTeamResolution: automaticTeamResolution
                )
            }
        } catch {
            telemetry.breadcrumb(
                "claude-hook.task-sync.error",
                data: ["error": String(describing: error)]
            )
        }
        printClaudeHookAck()
    }
}
