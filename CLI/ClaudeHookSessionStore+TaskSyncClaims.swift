import CMUXAgentLaunch
import Foundation

extension ClaudeHookSessionStore {
    func claimClaudeTaskSync(
        scope: String,
        sessionId: String? = nil,
        expectedStartedAt: TimeInterval? = nil
    ) throws -> String {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedScope.isEmpty else { return UUID().uuidString }
        let normalizedSessionId = sessionId.map(normalizeSessionId)
        var token = ""
        try withLockedState(persistTaskSyncSidecar: true) { state in
            if let normalizedSessionId, !normalizedSessionId.isEmpty {
                let hasEndedBoundary = state.endedSessionIDs[normalizedSessionId] != nil
                    || state.endedSessionGenerationStarts[normalizedSessionId] != nil
                if let expectedStartedAt {
                    guard state.sessions[normalizedSessionId]?.startedAt == expectedStartedAt,
                          !hasEndedBoundary else {
                        throw POSIXError(.EAGAIN)
                    }
                } else {
                    // A first-sighting hook may claim only while the store is
                    // still empty for this id. If SessionStart wins the race,
                    // this claim is rejected before it can replace a valid
                    // generation's token.
                    guard state.sessions[normalizedSessionId] == nil,
                          !hasEndedBoundary else {
                        throw POSIXError(.EAGAIN)
                    }
                }
            }
            let isOverflowScope = normalizedScope.hasSuffix(
                Self.claudeTaskSyncOverflowScopeSuffix
            )
            let ordinaryScopeCount = state.claudeTaskSyncLatestTokens.keys.reduce(into: 0) { count, key in
                if !key.hasSuffix(Self.claudeTaskSyncOverflowScopeSuffix) {
                    count += 1
                }
            }
            let canAdmit = state.claudeTaskSyncLatestTokens[normalizedScope] != nil
                || (isOverflowScope
                    ? state.claudeTaskSyncLatestTokens.count < Self.maxClaudeTaskSyncScopes
                    : ordinaryScopeCount < Self.maxClaudeTaskSyncScopes - 1)
            guard canAdmit else {
                // Never evict an unknown in-flight token: doing so would let
                // an older worker publish after its coalescing proof vanished.
                throw POSIXError(.E2BIG)
            }
            let persistedGeneration = state.claudeTaskSyncLatestTokens.values
                .compactMap(Self.claudeTaskSyncTokenGeneration)
                .max() ?? 0
            state.claudeTaskSyncGeneration = max(
                state.claudeTaskSyncGeneration,
                persistedGeneration
            )
            state.claudeTaskSyncGeneration &+= 1
            token = "\(state.claudeTaskSyncGeneration):\(Int(Date.now.timeIntervalSince1970 * 1_000)):\(UUID().uuidString)"
            state.claudeTaskSyncLatestTokens[normalizedScope] = token
        }
        return token
    }

    /// Returns whether a task-sync worker still owns the latest claim.
    func isLatestClaudeTaskSync(scope: String, token: String) throws -> Bool {
        try withLockedState { state in
            state.claudeTaskSyncLatestTokens[scope] == token
        }
    }

    /// Checks claim ownership and session provenance in one state transaction.
    func isLatestClaudeTaskSyncForSession(
        scope: String,
        token: String,
        sessionId: String,
        expectedStartedAt: TimeInterval?,
        hookPID: Int?,
        validateProcessIdentity: Bool = true
    ) throws -> Bool {
        let normalizedSessionId = normalizeSessionId(sessionId)
        guard !normalizedSessionId.isEmpty else { return false }
        return try withLockedState { state in
            guard state.claudeTaskSyncLatestTokens[scope] == token,
                  state.endedSessionIDs[normalizedSessionId] == nil,
                  state.endedSessionGenerationStarts[normalizedSessionId] == nil else {
                return false
            }
            guard let expectedStartedAt else {
                return state.sessions[normalizedSessionId] == nil
            }
            guard let record = state.sessions[normalizedSessionId],
                  record.startedAt == expectedStartedAt else {
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
            guard let identity = processStartIdentity(pid: hookPID) else { return true }
            return identity.seconds == expectedSeconds
                && identity.microseconds == expectedMicroseconds
        }
    }

    /// Moves one live task-sync claim to its authoritative task-list scope.
    ///
    /// The caller holds the store-wide task-sync lease while transferring so
    /// a TeamDelete or replacement hook cannot mutate the destination between
    /// owner resolution and this compare-and-move.
    @discardableResult
    func transferClaudeTaskSyncClaim(
        fromScope: String,
        toScope: String,
        token: String
    ) throws -> Bool {
        guard !toScope.isEmpty else { return false }
        return try withLockedState(persistTaskSyncSidecar: true) { state in
            guard state.claudeTaskSyncLatestTokens[fromScope] == token else {
                return false
            }
            guard fromScope != toScope else { return true }
            if let destinationToken = state.claudeTaskSyncLatestTokens[toScope],
               destinationToken != token {
                // Keep whichever claim was created later. A newer scan may
                // already be queued behind this worker's lease; overwriting
                // it would make that authoritative hook coalesce itself away.
                guard Self.isNewerClaudeTaskSyncToken(
                    token,
                    than: destinationToken
                ) else {
                    return false
                }
            }
            state.claudeTaskSyncLatestTokens.removeValue(forKey: fromScope)
            state.claudeTaskSyncLatestTokens[toScope] = token
            return true
        }
    }

    static func isNewerClaudeTaskSyncToken(
        _ candidate: String,
        than existing: String
    ) -> Bool {
        guard let candidateGeneration = claudeTaskSyncTokenGeneration(candidate),
              let existingGeneration = claudeTaskSyncTokenGeneration(existing) else {
            return false
        }
        if candidateGeneration != existingGeneration {
            return candidateGeneration > existingGeneration
        }
        return candidate > existing
    }

    static func claudeTaskSyncTokenGeneration(_ token: String) -> UInt64? {
        let components = token.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count >= 3 else { return nil }
        return UInt64(components[0])
    }

    /// Releases a task-sync claim only when no newer worker replaced it.
    func finishClaudeTaskSync(scope: String, token: String) throws {
        _ = try withLockedState(persistTaskSyncSidecar: true) { state in
            guard state.claudeTaskSyncLatestTokens[scope] == token else { return }
            state.claudeTaskSyncLatestTokens.removeValue(forKey: scope)
        }
    }

    /// Removes session task-directory proofs after the owning list is deleted.
    ///
    /// Team task lists are shared by several Claude sessions, so deleting the
    /// list must invalidate every session-scoped fallback binding for the same
    /// task-store identity. The session's lifecycle and pane routing remain
    /// intact; only the task-directory proof is discarded.
    func clearClaudeTaskDirectoryBindings(
        directoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity?
    ) throws {
        let normalizedDirectoryName = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDirectoryName.isEmpty,
              normalizedDirectoryName != ".",
              normalizedDirectoryName != "..",
              !normalizedDirectoryName.contains("/"),
              !normalizedDirectoryName.contains("\0") else { return }
        let expectedStoreID = taskStoreIdentity?.rawValue
        try withLockedState(persistTaskSyncSidecar: true) { state in
            let now = Date().timeIntervalSince1970
            for sessionID in Array(state.sessions.keys) {
                guard var record = state.sessions[sessionID],
                      record.claudeTaskDirectoryName == normalizedDirectoryName,
                      record.claudeTaskStoreID == expectedStoreID else { continue }
                record.claudeTaskDirectoryName = nil
                record.claudeTaskStoreID = nil
                record.claudeTaskLegacyOwnerCleared = nil
                record.claudeTaskBindingStartedAt = nil
                record.claudeTaskBindingSource = nil
                record.updatedAt = now
                state.sessions[sessionID] = record
            }
            for sessionID in Array(state.pendingSupersededSessionCleanup.keys) {
                guard var record = state.pendingSupersededSessionCleanup[sessionID],
                      record.claudeTaskDirectoryName == normalizedDirectoryName,
                      record.claudeTaskStoreID == expectedStoreID else { continue }
                record.claudeTaskDirectoryName = nil
                record.claudeTaskStoreID = nil
                record.claudeTaskLegacyOwnerCleared = nil
                record.claudeTaskBindingStartedAt = nil
                record.claudeTaskBindingSource = nil
                // Preserve the pending record's immutable cleanup age anchors.
                state.pendingSupersededSessionCleanup[sessionID] = record
            }
        }
    }

    /// Removes destination/team proofs after a legacy owner is fully cleared.
    /// Session records remain until the replacement binding's compare-and-set
    /// stamps their new task-store identity.
    func removeLegacyClaudeTaskOwnerDestinationProofs(directoryName: String) throws {
        let normalizedDirectoryName = directoryName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedDirectoryName.isEmpty else { return }
        try withLockedState(persistTaskSyncSidecar: true) { state in
            state.claudeTaskListDestinations = state.claudeTaskListDestinations.filter {
                !($0.value.taskStoreIdentity == nil
                    && $0.value.taskListID == normalizedDirectoryName)
            }
            state.claudeTeamTaskBindings = state.claudeTeamTaskBindings.filter {
                !($0.value.binding.taskStoreIdentity == nil
                    && $0.value.binding.taskListID == normalizedDirectoryName)
            }
        }
    }

    /// Advances legacy destination proofs after one successful cleanup page.
    func markLegacyClaudeTaskOwnerDestinationProofsCleared(
        directoryName: String,
        workspaceIDs: [String]
    ) throws {
        let normalizedDirectoryName = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let clearedWorkspaceIDs = Set(workspaceIDs.compactMap(normalizeOptional))
        guard !normalizedDirectoryName.isEmpty, !clearedWorkspaceIDs.isEmpty else { return }
        try withLockedState(persistTaskSyncSidecar: true) { state in
            for key in Array(state.claudeTaskListDestinations.keys) {
                guard let record = state.claudeTaskListDestinations[key],
                      record.taskStoreIdentity == nil,
                      record.taskListID == normalizedDirectoryName else { continue }
                let remainingWorkspaceIDs = record.workspaceIDs.filter {
                    !clearedWorkspaceIDs.contains($0)
                }
                if remainingWorkspaceIDs.isEmpty {
                    state.claudeTaskListDestinations.removeValue(forKey: key)
                } else {
                    state.claudeTaskListDestinations[key] = ClaudeHookTaskListDestinationRecord(
                        taskStoreIdentity: nil,
                        taskListID: record.taskListID,
                        workspaceIDs: remainingWorkspaceIDs,
                        updatedAt: record.updatedAt
                    )
                }
            }
            for key in Array(state.claudeTeamTaskBindings.keys) {
                guard let record = state.claudeTeamTaskBindings[key],
                      record.binding.taskStoreIdentity == nil,
                      record.binding.taskListID == normalizedDirectoryName else { continue }
                let remainingWorkspaceIDs = record.workspaceIDs.filter {
                    !clearedWorkspaceIDs.contains($0)
                }
                if remainingWorkspaceIDs.isEmpty {
                    state.claudeTeamTaskBindings.removeValue(forKey: key)
                } else {
                    state.claudeTeamTaskBindings[key] = ClaudeHookTeamTaskBindingRecord(
                        binding: record.binding,
                        workspaceIDs: remainingWorkspaceIDs,
                        updatedAt: record.updatedAt
                    )
                }
            }
        }
    }

    /// Returns every workspace still carrying one pre-profile owner.
    ///
    /// The returned list includes the durable continuation, not just live
    /// session records. A session can be rebound to a namespaced owner while a
    /// legacy socket cleanup is in flight; retaining this proof is what makes
    /// that cleanup safe to retry.
    func legacyClaudeTaskOwnerWorkspaceIDs(
        directoryName: String,
        including workspaceIDs: [String],
        includeFallbackDestinations: Bool = false
    ) throws -> [String] {
        let normalizedDirectoryName = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDirectoryName.isEmpty,
              normalizedDirectoryName != ".",
              normalizedDirectoryName != "..",
              !normalizedDirectoryName.contains("/"),
              !normalizedDirectoryName.contains("\0") else { return [] }
        return try withLockedState { state -> [String] in
            let sessionRecords = Array(state.sessions.values)
            let supersededSessionRecords = Array(state.pendingSupersededSessionCleanup.values)
            let records = sessionRecords + supersededSessionRecords
            let pendingRecords = records.filter {
                $0.claudeTaskDirectoryName == normalizedDirectoryName
                    && $0.claudeTaskStoreID == nil
                    && $0.claudeTaskLegacyOwnerCleared != true
            }
            let legacyDestinationRecords = state.claudeTaskListDestinations.values
                .filter {
                    $0.taskStoreIdentity == nil
                        && $0.taskListID == normalizedDirectoryName
                }
            let legacyDestinationWorkspaceIDs = legacyDestinationRecords.flatMap(\.workspaceIDs)
            let legacyTeamBindingRecords = state.claudeTeamTaskBindings.values
                .filter {
                    $0.binding.taskStoreIdentity == nil
                        && $0.binding.taskListID == normalizedDirectoryName
                }
            let legacyTeamWorkspaceIDs = legacyTeamBindingRecords.flatMap(\.workspaceIDs)
            let pendingCleanupWorkspaceIDs = state.pendingLegacyClaudeTaskOwnerCleanup[
                normalizedDirectoryName
            ]?.workspaceIDs ?? []
            let overflowCleanupWorkspaceIDs = state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries[
                normalizedDirectoryName
            ]?.workspaceIDs ?? []
            let spillCleanupWorkspaceIDs = state.pendingLegacyClaudeTaskOwnerCleanupSpill[
                normalizedDirectoryName
            ]?.workspaceIDs ?? []
            let persistedWorkspaceIDs = pendingCleanupWorkspaceIDs
                + overflowCleanupWorkspaceIDs
                + spillCleanupWorkspaceIDs
            guard !pendingRecords.isEmpty
                    || !persistedWorkspaceIDs.isEmpty
                    || !legacyDestinationWorkspaceIDs.isEmpty
                    || !legacyTeamWorkspaceIDs.isEmpty
                    || includeFallbackDestinations else {
                return []
            }
            let requiredWorkspaceIDs = Set(workspaceIDs.compactMap(normalizeOptional))
            let pendingRecordWorkspaceIDs = pendingRecords.compactMap {
                normalizeOptional($0.workspaceId)
            }
            let persistedDestinationWorkspaceIDs = persistedWorkspaceIDs.compactMap(normalizeOptional)
            let legacyDestinationIDs = legacyDestinationWorkspaceIDs.compactMap(normalizeOptional)
            let legacyTeamIDs = legacyTeamWorkspaceIDs.compactMap(normalizeOptional)
            let allDestinationWorkspaceIDs = persistedDestinationWorkspaceIDs
                + pendingRecordWorkspaceIDs
                + legacyDestinationIDs
                + legacyTeamIDs
                + Array(requiredWorkspaceIDs)
            let destinationWorkspaceIDs = Set(allDestinationWorkspaceIDs)
            // Explicit destinations are the current owner proof and must be
            // cleaned in the first bounded page; retained continuations
            // follow. If old session records accumulated beyond the aggregate
            // proof cap, leave the unselected records discoverable for the
            // next page instead of rejecting the whole cleanup.
            let orderedWorkspaceIDs = requiredWorkspaceIDs.sorted()
                + destinationWorkspaceIDs.subtracting(requiredWorkspaceIDs).sorted()
            return Array(orderedWorkspaceIDs.prefix(Self.maxLegacyClaudeTaskOwnerWorkspaceIDs))
        }
    }

    /// Marks selected copies of one legacy owner only after app cleanup succeeds.
    func markLegacyClaudeTaskOwnerCleared(
        directoryName: String,
        workspaceIDs: [String]? = nil
    ) throws {
        let normalizedDirectoryName = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDirectoryName.isEmpty,
              normalizedDirectoryName != ".",
              normalizedDirectoryName != "..",
              !normalizedDirectoryName.contains("/"),
              !normalizedDirectoryName.contains("\0") else { return }
        try withLockedState(persistTaskSyncSidecar: true) { state in
            let now = Date.now.timeIntervalSince1970
            let workspaceIDSet = workspaceIDs.map { Set($0.compactMap(normalizeOptional)) }
            for sessionId in Array(state.sessions.keys) {
                guard var record = state.sessions[sessionId],
                      record.claudeTaskDirectoryName == normalizedDirectoryName,
                      record.claudeTaskStoreID == nil,
                      workspaceIDSet?.contains(normalizeOptional(record.workspaceId) ?? "") != false else { continue }
                record.claudeTaskLegacyOwnerCleared = true
                record.updatedAt = now
                state.sessions[sessionId] = record
            }
            for sessionId in Array(state.pendingSupersededSessionCleanup.keys) {
                guard var record = state.pendingSupersededSessionCleanup[sessionId],
                      record.claudeTaskDirectoryName == normalizedDirectoryName,
                      record.claudeTaskStoreID == nil,
                      workspaceIDSet?.contains(normalizeOptional(record.workspaceId) ?? "") != false else { continue }
                record.claudeTaskLegacyOwnerCleared = true
                // Preserve the pending record's immutable cleanup age anchors.
                state.pendingSupersededSessionCleanup[sessionId] = record
            }
        }
    }

    /// Records or retires a bounded legacy-owner cleanup continuation.
}
