import CMUXAgentLaunch
import Foundation

extension ClaudeHookSessionStore {
    func setLegacyClaudeTaskOwnerCleanupPending(
        directoryName: String,
        workspaceIDs: [String] = [],
        pending: Bool,
        retry: Bool = false,
        replaceWorkspaceIDs: Bool = false
    ) throws -> Bool {
        let normalizedDirectoryName = directoryName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedDirectoryName.isEmpty else { return false }
        return try withLockedState(persistTaskSyncSidecar: true) { state in
            if !pending {
                state.pendingLegacyClaudeTaskOwnerCleanup.removeValue(
                    forKey: normalizedDirectoryName
                )
                state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries.removeValue(
                    forKey: normalizedDirectoryName
                )
                state.pendingLegacyClaudeTaskOwnerCleanupSpill.removeValue(
                    forKey: normalizedDirectoryName
                )
                return true
            }
            let primaryRecord = state.pendingLegacyClaudeTaskOwnerCleanup[
                normalizedDirectoryName
            ]
            let overflowRecord = state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries[
                normalizedDirectoryName
            ]
            let spillRecord = state.pendingLegacyClaudeTaskOwnerCleanupSpill[
                normalizedDirectoryName
            ]
            let usePrimaryTier: Bool
            let useOverflowTier: Bool
            if primaryRecord != nil {
                usePrimaryTier = true
                useOverflowTier = false
            } else if overflowRecord != nil {
                usePrimaryTier = false
                useOverflowTier = true
            } else if spillRecord != nil {
                usePrimaryTier = false
                useOverflowTier = false
            } else if state.pendingLegacyClaudeTaskOwnerCleanup.count
                        < ClaudeHookTaskListDestinationRecord.maximumRecordCount {
                usePrimaryTier = true
                useOverflowTier = false
            } else if state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries.count
                        < ClaudeHookTaskListDestinationRecord.maximumRecordCount {
                usePrimaryTier = false
                useOverflowTier = true
            } else {
                usePrimaryTier = false
                useOverflowTier = false
                state.pendingLegacyClaudeTaskOwnerCleanupOverflow = true
                if spillRecord == nil,
                   state.pendingLegacyClaudeTaskOwnerCleanupSpill.count
                        >= Self.maxLegacyClaudeTaskOwnerCleanupSpillEntries {
                    let evictableDirectory = state.pendingLegacyClaudeTaskOwnerCleanupSpill
                        .first { _, record in
                            record.attemptCount
                                >= Self.maxLegacyClaudeTaskOwnerCleanupAttempts
                        }?.key
                    guard let evictableDirectory else {
                        // Preserve bounded state and fail closed; destination
                        // proofs remain in their owning binding records, and
                        // the overflow marker lets the retry scanner rediscover
                        // those proof-only destinations.
                        return false
                    }
                    state.pendingLegacyClaudeTaskOwnerCleanupSpill.removeValue(
                        forKey: evictableDirectory
                    )
                }
            }
            var record = primaryRecord ?? overflowRecord ?? spillRecord
                ?? .init(workspaceIDs: [])
            let normalizedWorkspaceIDs = workspaceIDs.compactMap(normalizeOptional)
            let mergedWorkspaceIDs = replaceWorkspaceIDs
                ? Set(normalizedWorkspaceIDs).sorted()
                : Set(record.workspaceIDs + normalizedWorkspaceIDs).sorted()
            guard mergedWorkspaceIDs.count <= Self.maxLegacyClaudeTaskOwnerWorkspaceIDs else {
                state.pendingLegacyClaudeTaskOwnerCleanupOverflow = true
                // Keep the prior bounded proof intact; callers fail closed and
                // retain the authoritative destination records for a later
                // capacity retry instead of truncating IDs.
                return false
            }
            record.workspaceIDs = mergedWorkspaceIDs
            if retry {
                let now = Date.now.timeIntervalSince1970
                let alreadyBackedOff = record.nextAttemptAt.map { $0 > now } == true
                if !alreadyBackedOff,
                   record.attemptCount < Self.maxLegacyClaudeTaskOwnerCleanupAttempts {
                    record.attemptCount = min(
                        Self.maxLegacyClaudeTaskOwnerCleanupAttempts,
                        record.attemptCount + 1
                    )
                    let exponent = min(record.attemptCount, 6)
                    let delay = min(
                        Self.maxLegacyClaudeTaskOwnerCleanupRetrySeconds,
                        pow(2, Double(exponent))
                    )
                    record.nextAttemptAt = now + delay
                }
            }
            if useOverflowTier {
                state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries[
                    normalizedDirectoryName
                ] = record
            } else if usePrimaryTier {
                state.pendingLegacyClaudeTaskOwnerCleanup[normalizedDirectoryName] = record
            } else {
                state.pendingLegacyClaudeTaskOwnerCleanupSpill[normalizedDirectoryName] = record
            }
            return true
        }
    }

    /// Returns whether a queued legacy cleanup is eligible for a normal hook.
    func isLegacyClaudeTaskOwnerCleanupEligible(directoryName: String) throws -> Bool {
        let normalizedDirectoryName = directoryName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedDirectoryName.isEmpty else { return false }
        return try withLockedState { state in
            let now = Date.now.timeIntervalSince1970
            resetExpiredLegacyClaudeTaskOwnerCleanupAttempts(
                in: &state,
                now: now
            )
            let record = state.pendingLegacyClaudeTaskOwnerCleanup[
                normalizedDirectoryName
            ] ?? state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries[
                normalizedDirectoryName
            ] ?? state.pendingLegacyClaudeTaskOwnerCleanupSpill[
                normalizedDirectoryName
            ]
            if let record,
               record.attemptCount >= Self.maxLegacyClaudeTaskOwnerCleanupAttempts {
                return false
            }
            guard let nextAttemptAt = record?.nextAttemptAt else { return true }
            return nextAttemptAt <= now
        }
    }

    /// Reopens terminally failed cleanup proofs after a quiet cooldown so a
    /// transient socket outage cannot permanently occupy the bounded queues.
    func resetExpiredLegacyClaudeTaskOwnerCleanupAttempts(
        in state: inout ClaudeHookSessionStoreFile,
        now: TimeInterval
    ) {
        for directoryName in Array(state.pendingLegacyClaudeTaskOwnerCleanup.keys) {
            guard var record = state.pendingLegacyClaudeTaskOwnerCleanup[directoryName],
                  record.attemptCount >= Self.maxLegacyClaudeTaskOwnerCleanupAttempts,
                  let nextAttemptAt = record.nextAttemptAt,
                  now - nextAttemptAt >= Self.legacyClaudeTaskOwnerCleanupTerminalCooldownSeconds else {
                continue
            }
            record.attemptCount = 0
            record.nextAttemptAt = nil
            state.pendingLegacyClaudeTaskOwnerCleanup[directoryName] = record
        }
        for directoryName in Array(
            state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries.keys
        ) {
            guard var record = state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries[
                directoryName
            ],
            record.attemptCount >= Self.maxLegacyClaudeTaskOwnerCleanupAttempts,
            let nextAttemptAt = record.nextAttemptAt,
            now - nextAttemptAt >= Self.legacyClaudeTaskOwnerCleanupTerminalCooldownSeconds else {
                continue
            }
            record.attemptCount = 0
            record.nextAttemptAt = nil
            state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries[directoryName] = record
        }
        for directoryName in Array(state.pendingLegacyClaudeTaskOwnerCleanupSpill.keys) {
            guard var record = state.pendingLegacyClaudeTaskOwnerCleanupSpill[directoryName],
                  record.attemptCount >= Self.maxLegacyClaudeTaskOwnerCleanupAttempts,
                  let nextAttemptAt = record.nextAttemptAt,
                  now - nextAttemptAt >= Self.legacyClaudeTaskOwnerCleanupTerminalCooldownSeconds else {
                continue
            }
            record.attemptCount = 0
            record.nextAttemptAt = nil
            state.pendingLegacyClaudeTaskOwnerCleanupSpill[directoryName] = record
        }
    }

    /// Returns and claims one eligible legacy-owner cleanup, rotating failed
    /// entries behind unrelated work through a durable retry timestamp.
    func nextLegacyClaudeTaskOwnerCleanup() throws -> (
        directoryName: String,
        workspaceIDs: [String]
    )? {
        try withLockedState(persistTaskSyncSidecar: true) { state in
            let now = Date.now.timeIntervalSince1970
            resetExpiredLegacyClaudeTaskOwnerCleanupAttempts(
                in: &state,
                now: now
            )
            let allEntries = state.pendingLegacyClaudeTaskOwnerCleanup.merging(
                state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries
            ) { primary, _ in primary }.merging(
                state.pendingLegacyClaudeTaskOwnerCleanupSpill
            ) { primary, _ in primary }
            let candidate = allEntries
                .filter { _, record in
                    record.attemptCount < Self.maxLegacyClaudeTaskOwnerCleanupAttempts
                        && record.nextAttemptAt.map { $0 > now } != true
                }
                .sorted { lhs, rhs in
                    let lhsAttempt = lhs.value.nextAttemptAt ?? 0
                    let rhsAttempt = rhs.value.nextAttemptAt ?? 0
                    if lhsAttempt != rhsAttempt { return lhsAttempt < rhsAttempt }
                    if lhs.value.attemptCount != rhs.value.attemptCount {
                        return lhs.value.attemptCount < rhs.value.attemptCount
                    }
                    return lhs.key < rhs.key
                }
                .first
            guard let (directoryName, record) = candidate else {
                guard state.pendingLegacyClaudeTaskOwnerCleanupOverflow else { return nil }
                var discoveredCandidates: [(directoryName: String, workspaceIDs: [String])] = []
                for record in (Array(state.sessions.values)
                    + Array(state.pendingSupersededSessionCleanup.values)).prefix(256) {
                        guard record.claudeTaskStoreID == nil,
                              record.claudeTaskLegacyOwnerCleared != true,
                              let directoryName = normalizeOptional(record.claudeTaskDirectoryName),
                              let workspaceID = normalizeOptional(record.workspaceId) else {
                            continue
                        }
                        discoveredCandidates.append((directoryName, [workspaceID]))
                }
                for record in state.claudeTaskListDestinations.values.prefix(128) {
                    guard record.taskStoreIdentity == nil else { continue }
                    discoveredCandidates.append((record.taskListID, record.workspaceIDs))
                }
                for record in state.claudeTeamTaskBindings.values.prefix(128) {
                    guard record.binding.taskStoreIdentity == nil else { continue }
                    discoveredCandidates.append((record.binding.taskListID, record.workspaceIDs))
                }
                let sortedDiscoveredCandidates = discoveredCandidates
                    .filter {
                        state.pendingLegacyClaudeTaskOwnerCleanup[$0.directoryName] == nil
                            && state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries[$0.directoryName] == nil
                            && state.pendingLegacyClaudeTaskOwnerCleanupSpill[$0.directoryName] == nil
                    }
                    .sorted { lhs, rhs in
                        lhs.directoryName < rhs.directoryName
                    }
                let discoveredCandidate = sortedDiscoveredCandidates.first {
                    guard let cursor = state.pendingLegacyClaudeTaskOwnerCleanupOverflowCursor else {
                        return true
                    }
                    return $0.directoryName > cursor
                } ?? sortedDiscoveredCandidates.first
                guard let discoveredCandidate else {
                    // Keep the marker: bounded discovery may have skipped a
                    // proof beyond the current scan window. A later hook will
                    // retry the next window rather than retiring the marker.
                    return nil
                }
                let discoveredDirectory = discoveredCandidate.directoryName
                let discoveredWorkspaceIDs = discoveredCandidate.workspaceIDs
                state.pendingLegacyClaudeTaskOwnerCleanupOverflowCursor = discoveredDirectory
                if state.pendingLegacyClaudeTaskOwnerCleanup.count
                        < ClaudeHookTaskListDestinationRecord.maximumRecordCount {
                    state.pendingLegacyClaudeTaskOwnerCleanup[discoveredDirectory] = .init(
                        workspaceIDs: discoveredWorkspaceIDs
                    )
                } else if state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries.count
                            < ClaudeHookTaskListDestinationRecord.maximumRecordCount {
                    state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries[
                        discoveredDirectory
                    ] = .init(workspaceIDs: discoveredWorkspaceIDs)
                } else {
                    if state.pendingLegacyClaudeTaskOwnerCleanupSpill.count
                            >= Self.maxLegacyClaudeTaskOwnerCleanupSpillEntries {
                        let evictableDirectory = state.pendingLegacyClaudeTaskOwnerCleanupSpill
                            .first { _, record in
                                record.attemptCount
                                    >= Self.maxLegacyClaudeTaskOwnerCleanupAttempts
                            }?.key
                        guard let evictableDirectory else { return nil }
                        state.pendingLegacyClaudeTaskOwnerCleanupSpill.removeValue(
                            forKey: evictableDirectory
                        )
                    }
                    state.pendingLegacyClaudeTaskOwnerCleanupSpill[discoveredDirectory] = .init(
                        workspaceIDs: discoveredWorkspaceIDs
                    )
                }
                return (discoveredDirectory, discoveredWorkspaceIDs)
            }
            var claimed = record
            claimed.attemptCount = min(
                Self.maxLegacyClaudeTaskOwnerCleanupAttempts,
                claimed.attemptCount + 1
            )
            let exponent = min(claimed.attemptCount, 6)
            claimed.nextAttemptAt = now + min(
                Self.maxLegacyClaudeTaskOwnerCleanupRetrySeconds,
                pow(2, Double(exponent))
            )
            if state.pendingLegacyClaudeTaskOwnerCleanup[directoryName] == nil,
               state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries[directoryName] != nil {
                state.pendingLegacyClaudeTaskOwnerCleanupOverflowEntries[directoryName] = claimed
            } else if state.pendingLegacyClaudeTaskOwnerCleanup[directoryName] == nil,
                      state.pendingLegacyClaudeTaskOwnerCleanupSpill[directoryName] != nil {
                state.pendingLegacyClaudeTaskOwnerCleanupSpill[directoryName] = claimed
            } else {
                state.pendingLegacyClaudeTaskOwnerCleanup[directoryName] = claimed
            }
            return (directoryName, claimed.workspaceIDs)
        }
    }

    /// Namespaces one legacy session binding after its old checklist owner was cleared.
    ///
    /// The caller performs the app reconciliation first. Keeping the compare-and-set
    /// inside the session-store lock ensures a failed cleanup remains retryable and a
    /// concurrently replaced binding is never stamped with the wrong profile.
    func markLegacyClaudeTaskDirectoryMigrated(
        sessionId: String,
        directoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        expectedStartedAt: TimeInterval? = nil
    ) throws -> Bool {
        let normalizedSessionId = normalizeSessionId(sessionId)
        let normalizedDirectoryName = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionId.isEmpty,
              !normalizedDirectoryName.isEmpty,
              normalizedDirectoryName != ".",
              normalizedDirectoryName != "..",
              !normalizedDirectoryName.contains("/"),
              !normalizedDirectoryName.contains("\0") else { return false }
        return try withLockedState(persistTaskSyncSidecar: true) { state in
            guard var record = state.sessions[normalizedSessionId],
                  record.claudeTaskDirectoryName == normalizedDirectoryName else {
                return false
            }
            if let expectedStartedAt,
               record.startedAt != expectedStartedAt {
                return false
            }
            if let existingTaskStoreID = record.claudeTaskStoreID {
                return existingTaskStoreID == taskStoreIdentity.rawValue
            }
            guard record.claudeTaskLegacyOwnerCleared == true else { return false }
            record.claudeTaskStoreID = taskStoreIdentity.rawValue
            record.claudeTaskLegacyOwnerCleared = nil
            record.claudeTaskBindingStartedAt = record.startedAt
            record.claudeTaskBindingSource = .compatibilityScan
            record.updatedAt = Date.now.timeIntervalSince1970
            state.sessions[normalizedSessionId] = record
            return true
        }
    }

    /// Plans task-list destinations and any owner cleanup needed for capacity.
}
