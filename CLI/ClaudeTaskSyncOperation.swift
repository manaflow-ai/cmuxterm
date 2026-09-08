import CMUXAgentLaunch
import Foundation

/// Owns one synchronous Claude task-sync invocation while its socket work runs.
final class ClaudeTaskSyncOperation {
    let client: SocketClient
    let telemetry: CLISocketSentryTelemetry
    let parsedInput: ClaudeHookParsedInput
    let sessionStore: ClaudeHookSessionStore
    let socketPassword: String?
    let sessionID: String
    let resolvedTarget: CMUXCLI.AgentHookDeliveryTarget
    let loader: ClaudeTaskSnapshotLoader
    let teamsRootURL: URL
    let taskStoreIdentity: ClaudeTaskStoreIdentity
    let taskStoreScope: String
    let agentID: String?
    let taskIdentity: ClaudeTaskIdentity?
    let configuredTaskListID: String?
    let configuredTaskDirectoryName: String?
    let deletedTeamTaskDirectoryName: String?
    let isTeamDeleteHook: Bool
    let initialCoalescingScope: String
    let hookDeadlineUptime: TimeInterval
    let taskHookStartedAfterSessionEnd: Bool
    let taskHookPID: Int?

    var taskHookStartedAt: TimeInterval?
    var activeTaskSyncClaim: (scope: String, token: String)?
    var taskSyncLease: ClaudeHookSessionStore.ClaudeTaskSyncLockLease?
    var currentRecord: ClaudeHookSessionRecord?

    init(
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        parsedInput: ClaudeHookParsedInput,
        sessionStore: ClaudeHookSessionStore,
        socketPassword: String?,
        sessionID: String,
        mappedSession: ClaudeHookSessionRecord?,
        resolvedTarget: CMUXCLI.AgentHookDeliveryTarget,
        loader: ClaudeTaskSnapshotLoader,
        teamsRootURL: URL,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        agentID: String?,
        taskIdentity: ClaudeTaskIdentity?,
        configuredTaskListID: String?,
        configuredTaskDirectoryName: String?,
        deletedTeamTaskDirectoryName: String?,
        isTeamDeleteHook: Bool,
        initialCoalescingScope: String,
        hookDeadlineUptime: TimeInterval,
        taskHookStartedAfterSessionEnd: Bool,
        taskHookPID: Int?
    ) {
        self.client = client
        self.telemetry = telemetry
        self.parsedInput = parsedInput
        self.sessionStore = sessionStore
        self.socketPassword = socketPassword
        self.sessionID = sessionID
        self.resolvedTarget = resolvedTarget
        self.loader = loader
        self.teamsRootURL = teamsRootURL
        self.taskStoreIdentity = taskStoreIdentity
        taskStoreScope = taskStoreIdentity.rawValue
        self.agentID = agentID
        self.taskIdentity = taskIdentity
        self.configuredTaskListID = configuredTaskListID
        self.configuredTaskDirectoryName = configuredTaskDirectoryName
        self.deletedTeamTaskDirectoryName = deletedTeamTaskDirectoryName
        self.isTeamDeleteHook = isTeamDeleteHook
        self.initialCoalescingScope = initialCoalescingScope
        self.hookDeadlineUptime = hookDeadlineUptime
        self.taskHookStartedAfterSessionEnd = taskHookStartedAfterSessionEnd
        self.taskHookPID = taskHookPID
        taskHookStartedAt = mappedSession?.startedAt
    }

    func isLatest() -> Bool {
        guard let activeTaskSyncClaim else { return true }
        guard !taskHookStartedAfterSessionEnd else { return false }
        if isTeamDeleteHook {
            return (try? sessionStore.isLatestClaudeTaskSync(
                scope: activeTaskSyncClaim.scope,
                token: activeTaskSyncClaim.token
            )) == true
        }
        return (try? sessionStore.isLatestClaudeTaskSyncForSession(
            scope: activeTaskSyncClaim.scope,
            token: activeTaskSyncClaim.token,
            sessionId: sessionID,
            expectedStartedAt: taskHookStartedAt,
            hookPID: taskHookPID,
            validateProcessIdentity: !client.isRelayBacked
        )) == true
    }

    func retarget(to taskListID: String) throws -> Bool {
        let normalizedTaskListID = taskListID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTaskListID.isEmpty else { return false }
        guard let currentClaim = activeTaskSyncClaim else { return true }
        let ownerScope = taskStoreScope + ":" + normalizedTaskListID
        if currentClaim.scope.hasSuffix(":<task-sync-overflow>") {
            guard try sessionStore.transferClaudeTaskSyncClaim(
                fromScope: currentClaim.scope,
                toScope: ownerScope,
                token: currentClaim.token
            ) else { return false }
            activeTaskSyncClaim = (ownerScope, currentClaim.token)
            try taskSyncLease?.switchScope(to: ownerScope)
            return true
        }
        guard ownerScope != currentClaim.scope else { return true }
        guard try sessionStore.transferClaudeTaskSyncClaim(
            fromScope: currentClaim.scope,
            toScope: ownerScope,
            token: currentClaim.token
        ) else { return false }
        activeTaskSyncClaim = (ownerScope, currentClaim.token)
        try taskSyncLease?.switchScope(to: ownerScope)
        return true
    }

    func claimInitial() throws {
        do {
            activeTaskSyncClaim = (
                initialCoalescingScope,
                try sessionStore.claimClaudeTaskSync(
                    scope: initialCoalescingScope,
                    sessionId: isTeamDeleteHook ? nil : sessionID,
                    expectedStartedAt: isTeamDeleteHook ? nil : taskHookStartedAt
                )
            )
        } catch let error as POSIXError where error.code == .E2BIG {
            let overflowScope = taskStoreScope + ":<task-sync-overflow>"
            activeTaskSyncClaim = (
                overflowScope,
                try sessionStore.claimClaudeTaskSync(
                    scope: overflowScope,
                    sessionId: isTeamDeleteHook ? nil : sessionID,
                    expectedStartedAt: isTeamDeleteHook ? nil : taskHookStartedAt
                )
            )
            telemetry.breadcrumb("claude-hook.task-sync.coalesce-overflow")
        }
    }

    func finishClaim() {
        guard let activeTaskSyncClaim else { return }
        try? sessionStore.finishClaudeTaskSync(
            scope: activeTaskSyncClaim.scope,
            token: activeTaskSyncClaim.token
        )
    }
}
