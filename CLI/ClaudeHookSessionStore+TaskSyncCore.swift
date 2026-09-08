import CMUXAgentLaunch
import CryptoKit
import Darwin
import Foundation

extension ClaudeHookSessionStore {
    /// Captures the session record and its end boundary in one state transaction.
    /// Task hooks use the captured boundary so a later SessionStart cannot make
    /// an already-ended asynchronous process look like a fresh first sighting.
    func claudeTaskSyncSessionEntry(
        sessionId: String
    ) throws -> (record: ClaudeHookSessionRecord?, ended: Bool) {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return (nil, false) }
        return try withLockedState { state -> (record: ClaudeHookSessionRecord?, ended: Bool) in
            (
                state.sessions[normalized],
                state.endedSessionIDs[normalized] != nil
                    || state.endedSessionGenerationStarts[normalized] != nil
            )
        }
    }

    /// Serializes task snapshot publication for one bounded task-sync scope
    /// without waiting past the hook's absolute deadline.
    func withClaudeTaskSyncLock<T>(
        deadlineUptime: TimeInterval,
        scope: String? = nil,
        _ body: () throws -> T
    ) throws -> T {
        try withClaudeTaskSyncLock(
            deadlineUptime: deadlineUptime,
            scope: scope
        ) { _ in
            try body()
        }
    }

    /// Runs a task-sync section with a lease that can move from an initial
    /// identity-scan slot to the resolved task-list slot before external I/O.
    func withClaudeTaskSyncLock<T>(
        deadlineUptime: TimeInterval,
        scope: String? = nil,
        _ body: (ClaudeTaskSyncLockLease) throws -> T
    ) throws -> T {
        try checkLockDeadline()
        let lease = ClaudeTaskSyncLockLease(
            store: self,
            deadlineUptime: deadlineUptime,
            scope: scope
        )
        try lease.acquire()
        defer { lease.release() }
        return try body(lease)
    }

    /// Returns the bounded lock path selected for one task-sync scope.
    func claudeTaskSyncLockPath(scope: String?) -> String {
        // Derive a bounded slot from the task-store identity. Including a
        // domain separator keeps this filename namespace independent from the
        // ownership/claim keys persisted in the state file.
        let normalizedScope = scope?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let digest = SHA256.hash(
            data: Data("cmux.claude-task-sync-lock.v1\0\(normalizedScope)".utf8)
        )
        let digestPrefix = digest.prefix(MemoryLayout<UInt64>.size)
            .reduce(UInt64(0)) { partial, byte in
                (partial << 8) | UInt64(byte)
            }
        let slot = digestPrefix % UInt64(Self.claudeTaskSyncLockSlotCount)
        return statePath + ".task-sync.lock.\(slot)"
    }

    /// Consumes a session only after any in-flight task-sync transaction ends.
    ///
    /// SessionEnd and task-sync run as independent Claude hook processes. They
    /// must share the task-sync lease so teardown cannot win the store race
    /// after a task hook has already started publishing its snapshot.
    func consumeAfterClaudeTaskSync(
        sessionId: String?,
        workspaceId: String?,
        surfaceId: String?,
        turnId: String?,
        expectedStartedAt: TimeInterval? = nil,
        scope: String? = nil,
        deadlineUptime: TimeInterval
    ) throws -> ClaudeHookSessionRecord? {
        let previousLockDeadlineUptime = lockDeadlineUptime
        lockDeadlineUptime = min(
            previousLockDeadlineUptime ?? deadlineUptime,
            deadlineUptime
        )
        defer { lockDeadlineUptime = previousLockDeadlineUptime }
        do {
            return try withClaudeTaskSyncLock(deadlineUptime: deadlineUptime, scope: scope) {
                try consume(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    turnId: turnId,
                    expectedStartedAt: expectedStartedAt
                )
            }
        } catch {
            // A crashed or wedged task hook must not leave SessionEnd without
            // an ordering boundary. The fallback consumes only the captured
            // generation and never scans by workspace when a session id is
            // present; a later SessionStart clears that boundary atomically.
            let recoveryDeadlineUptime = ProcessInfo.processInfo.systemUptime
                + Self.sessionEndRecoveryBudgetSeconds
            let recoveryPreviousDeadlineUptime = lockDeadlineUptime
            lockDeadlineUptime = recoveryDeadlineUptime
            defer { lockDeadlineUptime = recoveryPreviousDeadlineUptime }
            return try recordClaudeSessionEndBoundary(
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                turnId: turnId,
                expectedStartedAt: expectedStartedAt,
                deadlineUptime: recoveryDeadlineUptime
            )
        }
    }

    /// Rejects state I/O after the task hook's monotonic budget expires.
    func checkLockDeadline() throws {
        guard let lockDeadlineUptime else { return }
        guard ProcessInfo.processInfo.systemUptime < lockDeadlineUptime else {
            throw POSIXError(.ETIMEDOUT)
        }
    }

    /// Persists a session-owned task-directory binding and returns its generation proof.
    ///
    /// Claude launches asynchronous hooks in separate CLI processes, so the
    /// binding is updated inside the existing cross-process session-store
    /// transaction rather than process-local mutable state.
    func bindClaudeTaskDirectory(
        sessionId: String,
        directoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        workspaceId: String,
        surfaceId: String,
        pid: Int? = nil,
        expectedStartedAt: TimeInterval? = nil,
        source: ClaudeTaskBindingSource = .directSession
    ) throws -> ClaudeHookSessionRecord? {
        let normalizedSessionId = normalizeSessionId(sessionId)
        let normalizedDirectoryName = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedWorkspaceId = normalizeOptional(workspaceId),
              let normalizedSurfaceId = normalizeOptional(surfaceId),
              !normalizedSessionId.isEmpty,
              !normalizedDirectoryName.isEmpty,
              normalizedDirectoryName != ".",
              normalizedDirectoryName != "..",
              !normalizedDirectoryName.contains("/"),
              !normalizedDirectoryName.contains("\0") else { return nil }
        return try withLockedState(persistTaskSyncSidecar: true) { state in
            // A task hook may finish after SessionEnd consumed its record. Do
            // not let that stale process recreate the ended session.
            guard state.endedSessionIDs[normalizedSessionId] == nil,
                  state.endedSessionGenerationStarts[normalizedSessionId] == nil else {
                return nil
            }
            let now = Date.now.timeIntervalSince1970
            var record: ClaudeHookSessionRecord
            if let existing = state.sessions[normalizedSessionId] {
                guard let expectedStartedAt,
                      existing.startedAt == expectedStartedAt else {
                    // A hook that began without a record must not bind into a
                    // newly-created generation that appeared while it ran.
                    return nil
                }
                record = existing
            } else {
                // Preserve the historical first-hook behavior when no session
                // record existed at hook entry. If one did exist, the caller
                // supplies its generation and this branch fails closed after
                // SessionEnd removes it.
                guard expectedStartedAt == nil else { return nil }
                record = ClaudeHookSessionRecord(
                    sessionId: normalizedSessionId,
                    workspaceId: normalizedWorkspaceId,
                    surfaceId: normalizedSurfaceId,
                    startedAt: now,
                    updatedAt: now
                )
            }
            if let pid {
                if let existingPID = record.pid, existingPID != pid {
                    return nil
                }
                record.pid = pid
                if let identity = processStartIdentity(pid: pid) {
                    record.pidStartSeconds = identity.seconds
                    record.pidStartMicroseconds = identity.microseconds
                }
            }
            let bindingChanged = record.claudeTaskDirectoryName != normalizedDirectoryName
                || record.claudeTaskStoreID != taskStoreIdentity.rawValue
            let destinationChanged = record.workspaceId != normalizedWorkspaceId
                || record.surfaceId != normalizedSurfaceId
            let generationProofChanged = record.claudeTaskBindingStartedAt != record.startedAt
                || record.claudeTaskBindingSource != source
            guard bindingChanged || destinationChanged || generationProofChanged else {
                return record
            }
            if bindingChanged {
                record.claudeTaskDirectoryName = normalizedDirectoryName
                record.claudeTaskStoreID = taskStoreIdentity.rawValue
                record.claudeTaskLegacyOwnerCleared = nil
            }
            record.claudeTaskBindingStartedAt = record.startedAt
            record.claudeTaskBindingSource = source
            record.workspaceId = normalizedWorkspaceId
            record.surfaceId = normalizedSurfaceId
            record.updatedAt = now
            state.sessions[normalizedSessionId] = record
            return record
        }
    }

    /// Removes a first-sighting task-sync session only when its binding proof
    /// still matches the hook that created it. This is the failure rollback for
    /// an unacknowledged Feed snapshot; an unrelated lifecycle update cannot
    /// delete a newer generation by accident.
    @discardableResult
    func removeClaudeTaskSyncSessionIfMatching(
        sessionId: String,
        expectedStartedAt: TimeInterval,
        directoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        source: ClaudeTaskBindingSource
    ) throws -> Bool {
        let normalizedSessionId = normalizeSessionId(sessionId)
        let normalizedDirectoryName = directoryName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedSessionId.isEmpty,
              !normalizedDirectoryName.isEmpty else { return false }
        return try withLockedState(persistTaskSyncSidecar: true) { state in
            guard let record = state.sessions[normalizedSessionId],
                  record.startedAt == expectedStartedAt,
                  record.claudeTaskDirectoryName == normalizedDirectoryName,
                  record.claudeTaskStoreID == taskStoreIdentity.rawValue,
                  record.claudeTaskBindingStartedAt == expectedStartedAt,
                  record.claudeTaskBindingSource?.rawValue == source.rawValue else {
                return false
            }
            state.sessions.removeValue(forKey: normalizedSessionId)
            if record.pendingCursorShellApprovals?.isEmpty == false {
                removeCursorPendingIndex(
                    &state,
                    sessionId: normalizedSessionId,
                    workspaceId: record.workspaceId,
                    surfaceId: record.surfaceId,
                    countDelta: -1
                )
            }
            clearActiveSessionIfMatching(&state, removed: record, turnId: nil)
            return true
        }
    }

    /// Reports whether SessionEnd has already consumed this session generation.
    func isClaudeSessionEnded(_ sessionId: String) throws -> Bool {
        let normalizedSessionId = normalizeSessionId(sessionId)
        guard !normalizedSessionId.isEmpty else { return false }
        return try withLockedState { state in
            state.endedSessionIDs[normalizedSessionId] != nil
                || state.endedSessionGenerationStarts[normalizedSessionId] != nil
        }
    }

    /// Verifies the hook process still belongs to the captured session
    /// generation. Session IDs can be reused across restart/resume, so the
    /// persisted PID/start identity is the additional provenance signal.
    func isClaudeTaskHookProcessCurrent(
        sessionId: String,
        expectedStartedAt: TimeInterval,
        hookPID: Int?,
        validateProcessIdentity: Bool = true
    ) throws -> Bool {
        let normalizedSessionId = normalizeSessionId(sessionId)
        guard !normalizedSessionId.isEmpty else { return false }
        return try withLockedState { state in
            guard let record = state.sessions[normalizedSessionId],
                  record.startedAt == expectedStartedAt,
                  state.endedSessionIDs[normalizedSessionId] == nil,
                  state.endedSessionGenerationStarts[normalizedSessionId] == nil else {
                return false
            }
            guard let recordPID = record.pid else { return true }
            guard let hookPID else { return true }
            guard recordPID == hookPID else { return false }
            guard validateProcessIdentity else { return true }
            guard let expectedSeconds = record.pidStartSeconds,
                  let expectedMicroseconds = record.pidStartMicroseconds else {
                return true
            }
            // The parent Claude process may have exited while this async hook
            // is still draining its socket work. The captured PID/start pair
            // remains valid provenance; an unavailable live lookup is not a
            // generation mismatch.
            guard let identity = processStartIdentity(pid: hookPID) else { return true }
            return identity.seconds == expectedSeconds
                && identity.microseconds == expectedMicroseconds
        }
    }

    /// Records one task-list owner as retired until a new authoritative binding
    /// proves that the directory has been reused.
    func retireClaudeTaskList(
        taskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity
    ) throws {
        let normalizedTaskListID = taskListID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTaskListID.isEmpty else { return }
        try withLockedState(persistTaskSyncSidecar: true) { state in
            let key = claudeTaskListStorageKey(
                taskListID: normalizedTaskListID,
                taskStoreIdentity: taskStoreIdentity
            )
            state.retiredClaudeTaskLists[key] = Date().timeIntervalSince1970
            if state.retiredClaudeTaskLists.count > Self.maxRetiredClaudeTaskLists {
                // Deferred destination/team proofs are the retry owner; do
                // not evict their retirement key while they still exist.
                let protectedKeys = Set(
                    state.claudeTaskListDestinations.values.compactMap { record -> String? in
                        guard record.taskStoreIdentity != nil else { return nil }
                        return claudeTaskListStorageKey(record)
                    }
                    + state.claudeTeamTaskBindings.values.compactMap { record -> String? in
                        guard let identity = record.binding.taskStoreIdentity else { return nil }
                        return claudeTaskListStorageKey(
                            taskListID: record.binding.taskListID,
                            taskStoreIdentity: identity
                        )
                    }
                )
                let unprotectedKeys = state.retiredClaudeTaskLists
                    .filter { !protectedKeys.contains($0.key) }
                    .sorted { lhs, rhs in lhs.value > rhs.value }
                    .prefix(Self.maxRetiredClaudeTaskLists)
                    .map(\.key)
                let retainedKeys = protectedKeys.union(unprotectedKeys)
                state.retiredClaudeTaskLists = state.retiredClaudeTaskLists.filter {
                    retainedKeys.contains($0.key)
                }
            }
        }
    }

    /// Returns whether a task-list owner is still retired.
    func isClaudeTaskListRetired(
        taskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity
    ) throws -> Bool {
        let normalizedTaskListID = taskListID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTaskListID.isEmpty else { return false }
        let key = claudeTaskListStorageKey(
            taskListID: normalizedTaskListID,
            taskStoreIdentity: taskStoreIdentity
        )
        return try withLockedState { state in
            state.retiredClaudeTaskLists[key] != nil
        }
    }

    /// Returns the wall-clock generation boundary that retired a task list.
    ///
    /// A task hook may re-admit a retired list only when its session generation
    /// or a live automatic-team binding proves that it began after this
    /// boundary.
    func claudeTaskListRetiredAt(
        taskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity
    ) throws -> TimeInterval? {
        let normalizedTaskListID = taskListID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTaskListID.isEmpty else { return nil }
        let key = claudeTaskListStorageKey(
            taskListID: normalizedTaskListID,
            taskStoreIdentity: taskStoreIdentity
        )
        return try withLockedState { state in
            state.retiredClaudeTaskLists[key]
        }
    }

    /// Returns namespaced destination proofs retained for a deleted task list.
    func retiredClaudeTaskListDestinationRecords(
        taskStoreIdentity: ClaudeTaskStoreIdentity
    ) throws -> [ClaudeHookTaskListDestinationRecord] {
        try withLockedState { state in
            state.claudeTaskListDestinations.values.filter { record in
                guard record.taskStoreIdentity == taskStoreIdentity else { return false }
                return state.retiredClaudeTaskLists[
                    claudeTaskListStorageKey(record)
                ] != nil
            }
        }
    }

    /// Returns every retired task-list proof across profile namespaces.
    ///
    /// Session generations can switch `CLAUDE_CONFIG_DIR`, so cleanup cannot
    /// be limited to the identity of the replacement generation.
    func allRetiredClaudeTaskListDestinationRecords() throws -> [ClaudeHookTaskListDestinationRecord] {
        try withLockedState { state in
            state.claudeTaskListDestinations.values.filter { record in
                guard record.taskStoreIdentity != nil else { return false }
                return state.retiredClaudeTaskLists[
                    claudeTaskListStorageKey(record)
                ] != nil
            }
        }
    }

    /// Returns namespaced team proofs retained for a deleted task list.
    func retiredClaudeTeamTaskBindingRecords(
        taskStoreIdentity: ClaudeTaskStoreIdentity
    ) throws -> [ClaudeHookTeamTaskBindingRecord] {
        try withLockedState { state in
            state.claudeTeamTaskBindings.values.filter { record in
                guard record.binding.taskStoreIdentity == taskStoreIdentity else { return false }
                return state.retiredClaudeTaskLists[
                    claudeTaskListStorageKey(
                        taskListID: record.binding.taskListID,
                        taskStoreIdentity: taskStoreIdentity
                    )
                ] != nil
            }
        }
    }

    /// Clears a retirement proof after a new authoritative task-list binding.
    func unretireClaudeTaskList(
        taskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity
    ) throws {
        let normalizedTaskListID = taskListID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTaskListID.isEmpty else { return }
        _ = try withLockedState(persistTaskSyncSidecar: true) { state in
            state.retiredClaudeTaskLists.removeValue(
                forKey: claudeTaskListStorageKey(
                    taskListID: normalizedTaskListID,
                    taskStoreIdentity: taskStoreIdentity
                )
            )
        }
    }

    /// Claims the newest pending task-sync worker for one task-store scope.
    ///
    /// When a session generation is supplied, the generation check and claim
    /// write happen in the same state transaction. A stale asynchronous hook
    /// therefore cannot overwrite a newer generation's coalescing token.
}
