import Foundation

extension ClaudeHookSessionStore {
    func update(
        _ record: inout ClaudeHookSessionRecord,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String?,
        pid: Int?,
        launchCommand: AgentHookLaunchCommandRecord?,
        isRestorable: Bool?,
        agentLifecycle: AgentHibernationLifecycleState?,
        hookEventName: String? = nil,
        lastSubtitle: String?,
        lastBody: String?,
        updateLastSummary: Bool = false,
        lastNotificationStatus: AgentHookNotificationStatus?,
        updateLastNotificationStatus: Bool,
        runtimeStatus: AgentHookRuntimeStatus?,
        updateRuntimeStatus: Bool,
        runtimeStatusEventTime: TimeInterval? = nil,
        hadPendingBackgroundWorkAtStop: Bool? = nil,
        title: String? = nil,
        now: TimeInterval
    ) -> Bool {
        let hasRuntimeMutation = agentLifecycle != nil || updateRuntimeStatus
        let hasOrderedEvent = hasRuntimeMutation || runtimeStatusEventTime != nil
        let shouldApplyRuntimeMutation = !hasOrderedEvent
            || !runtimeEventIsStale(record: record, eventTime: runtimeStatusEventTime)
        guard shouldApplyRuntimeMutation else { return false }
        record.workspaceId = workspaceId
        if !surfaceId.isEmpty {
            record.surfaceId = surfaceId
        }
        if let cwd = normalizeOptional(cwd) {
            record.cwd = cwd
        }
        if let title = normalizeOptional(title) {
            record.title = title
        }
        if let transcriptPath = normalizeOptional(transcriptPath) {
            record.transcriptPath = transcriptPath
        }
        if let pid {
            record.updateProcessGeneration(
                pid: pid,
                startIdentity: processStartIdentity(pid: pid)
            )
        }
        if let launchCommand {
            let existingHasArguments = !(record.launchCommand?.arguments.isEmpty ?? true)
            let incomingHasArguments = !launchCommand.arguments.isEmpty
            let incomingHasEnvironment = !(launchCommand.environment?.isEmpty ?? true)
            // Persist an argv-bearing record always. Persist an argv-less, env-only record (the
            // CODEX_HOME / CLAUDE_CONFIG_DIR fallback for a plain agent whose launch argv couldn't be
            // captured) only when we don't already hold an argv-bearing one — so the durable store
            // keeps the non-default home for the fork/resume path without ever downgrading a richer
            // earlier capture to an env-only stub.
            if incomingHasArguments || normalizeOptional(launchCommand.source)?.lowercased() == "rejected" || (normalizeOptional(launchCommand.source)?.lowercased() == "default" && !existingHasArguments && normalizeOptional(record.launchCommand?.environment?["CODEX_HOME"]) == nil) || (incomingHasEnvironment && !existingHasArguments) {
                record.launchCommand = launchCommand
            } else if let verificationHome = normalizeOptional(launchCommand.verificationHome),
                      var existingLaunchCommand = record.launchCommand,
                      normalizeOptional(existingLaunchCommand.verificationHome) == nil {
                // Keep a richer argv capture while filling in the separate
                // Codex verification hint learned by a later hook event.
                existingLaunchCommand.verificationHome = verificationHome
                record.launchCommand = existingLaunchCommand
            }
        }
        if let isRestorable {
            // Preserve sticky true: a later isRestorable=false must not clear
            // record.isRestorable=true from a transcript-backed event.
            record.isRestorable = isRestorable || record.isRestorable == true
        }
        if let agentLifecycle {
            record.agentLifecycle = agentLifecycle
        }
        if let hookEventName = normalizeOptional(hookEventName) {
            record.hookEventName = hookEventName
        }
        if updateLastSummary {
            record.lastSubtitle = normalizeOptional(lastSubtitle)
            record.lastBody = normalizeOptional(lastBody)
        } else {
            if let subtitle = normalizeOptional(lastSubtitle) {
                record.lastSubtitle = subtitle
            }
            if let body = normalizeOptional(lastBody) {
                record.lastBody = body
            }
        }
        if shouldApplyRuntimeMutation, updateLastNotificationStatus {
            record.lastNotificationStatus = lastNotificationStatus
        }
        if updateRuntimeStatus {
            record.runtimeStatus = runtimeStatus
        }
        if hasOrderedEvent, let runtimeStatusEventTime {
            record.runtimeStatusEventTime = runtimeStatusEventTime
        }
        if shouldApplyRuntimeMutation, let hadPendingBackgroundWorkAtStop {
            record.hadPendingBackgroundWorkAtStop = hadPendingBackgroundWorkAtStop
        }
        record.updatedAt = now
        return true
    }

    func runtimeEventIsStale(
        record: ClaudeHookSessionRecord,
        eventTime: TimeInterval?
    ) -> Bool {
        guard let eventTime, let existingEventTime = record.runtimeStatusEventTime else {
            return record.runtimeStatusEventTime != nil && eventTime == nil
        }
        return eventTime < existingEventTime
    }

    func recordRepresentsActiveRunningSession(
        _ record: ClaudeHookSessionRecord
    ) -> Bool {
        if record.hadPendingBackgroundWorkAtStop == true {
            return true
        }
        if (record.activePromptDepth ?? 0) > 0 {
            return true
        }
        if record.activePromptTurnId.map({ !normalizeSessionId($0).isEmpty }) == true {
            return true
        }
        return record.activePromptTurnIds?.contains { !normalizeSessionId($0).isEmpty } == true
    }

    func hasRunningSession(
        workspaceId: String,
        surfaceId: String?,
        excludingSessionId: String?,
        onlyNewerThanExcludedSession: Bool = false,
        requireLiveProcess: Bool = false,
        requireActiveTurn: Bool = false
    ) throws -> Bool {
        guard let normalizedWorkspace = normalizeOptional(workspaceId) else {
            return false
        }
        let normalizedSurface = normalizeOptional(surfaceId)
        let excluded = normalizeOptional(excludingSessionId)
        return try withLockedState { state in
            let excludedRuntimeEventTime = excluded.flatMap { state.sessions[$0]?.runtimeStatusEventTime }
            var foundRunningSession = false
            let now = Date().timeIntervalSince1970

            for sessionId in Array(state.sessions.keys) {
                guard var record = state.sessions[sessionId] else { continue }
                guard normalizeOptional(record.workspaceId) == normalizedWorkspace,
                      record.sessionId != excluded,
                      record.runtimeStatus == .running else {
                    continue
                }
                if let normalizedSurface, normalizeOptional(record.surfaceId) != normalizedSurface {
                    continue
                }
                // Without an excluded timestamp there is no ordering boundary;
                // any live, active sibling must keep an untimed Idle from
                // demoting the surface. Timestamped boundaries remain strict.
                if onlyNewerThanExcludedSession, let excludedRuntimeEventTime {
                    guard let candidateEventTime = record.runtimeStatusEventTime,
                          candidateEventTime > excludedRuntimeEventTime else {
                        continue
                    }
                }

                if requireLiveProcess,
                   !Self.processExists(record.pid) || Self.processGenerationIsConfirmedDead(record) {
                    record.runtimeStatus = nil
                    record.agentLifecycle = nil
                    // Keep the accepted event-time watermark when demoting a
                    // dead record.  The process probe only invalidates
                    // liveness; it must not reopen the record to a delayed
                    // pre-exit hook that could relatch Running.
                    record.updatedAt = now
                    state.sessions[sessionId] = record
                    continue
                }
                if requireActiveTurn, !recordRepresentsActiveRunningSession(record) {
                    continue
                }
                foundRunningSession = true
                break
            }

            return foundRunningSession
        }
    }
}
