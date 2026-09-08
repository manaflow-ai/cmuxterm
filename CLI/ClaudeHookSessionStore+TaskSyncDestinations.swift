import CMUXAgentLaunch
import Foundation

extension ClaudeHookSessionStore {
    func claudeTaskListDestinationTransition(
        taskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        including workspaceIDs: [String]
    ) throws -> (
        workspaceIDs: [String],
        retiredRecords: [ClaudeHookTaskListDestinationRecord]
    ) {
        let normalizedTaskListID = taskListID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWorkspaceIDs = Set(workspaceIDs.compactMap(normalizeOptional))
        guard !normalizedTaskListID.isEmpty,
              normalizedTaskListID != ".",
              normalizedTaskListID != "..",
              !normalizedTaskListID.contains("/"),
              !normalizedTaskListID.contains("\0"),
              !normalizedWorkspaceIDs.isEmpty else {
            throw POSIXError(.EINVAL)
        }
        return try withLockedState { state in
            guard state.claudeTaskListDestinations.count
                    <= ClaudeHookTaskListDestinationRecord.maximumRecordCount else {
                throw POSIXError(.E2BIG)
            }
            let storageKey = claudeTaskListStorageKey(
                taskListID: normalizedTaskListID,
                taskStoreIdentity: taskStoreIdentity
            )
            var destinationWorkspaceIDs = normalizedWorkspaceIDs
            var retiredRecords: [ClaudeHookTaskListDestinationRecord] = []
            if let record = state.claudeTaskListDestinations[storageKey] {
                guard record.taskStoreIdentity == taskStoreIdentity,
                      record.taskListID == normalizedTaskListID else {
                    throw POSIXError(.EINVAL)
                }
                destinationWorkspaceIDs.formUnion(record.workspaceIDs)
            } else {
                if let legacyRecord = state.claudeTaskListDestinations[normalizedTaskListID],
                   legacyRecord.taskStoreIdentity == nil,
                   legacyRecord.taskListID == normalizedTaskListID {
                    guard legacyRecord.workspaceIDs.count
                            <= ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount else {
                        throw POSIXError(.E2BIG)
                    }
                    destinationWorkspaceIDs.formUnion(legacyRecord.workspaceIDs)
                    retiredRecords.append(legacyRecord)
                }
                let projectedCount = state.claudeTaskListDestinations.count
                    - retiredRecords.count
                    + 1
                let retirementCount = max(
                    0,
                    projectedCount - ClaudeHookTaskListDestinationRecord.maximumRecordCount
                )
                if retirementCount > 0 {
                    let retiredKeys = Set(retiredRecords.map {
                        claudeTaskListStorageKey($0)
                    })
                    let capacityRetirements = state.claudeTaskListDestinations.values
                        .filter { !retiredKeys.contains(claudeTaskListStorageKey($0)) }
                        .sorted { lhs, rhs in
                            if lhs.updatedAt != rhs.updatedAt {
                                return lhs.updatedAt < rhs.updatedAt
                            }
                            return claudeTaskListStorageKey(lhs)
                                < claudeTaskListStorageKey(rhs)
                        }
                    guard capacityRetirements.count >= retirementCount else {
                        throw POSIXError(.E2BIG)
                    }
                    retiredRecords.append(
                        contentsOf: capacityRetirements.prefix(retirementCount)
                    )
                }
            }
            guard destinationWorkspaceIDs.count
                    <= ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount else {
                throw POSIXError(.E2BIG)
            }
            return (destinationWorkspaceIDs.sorted(), retiredRecords)
        }
    }

    /// Commits task-list destinations after the app accepts reconciliation.
    func commitClaudeTaskListDestinations(
        taskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        workspaceIDs: [String]
    ) throws {
        let normalizedTaskListID = taskListID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWorkspaceIDs = Set(workspaceIDs.compactMap(normalizeOptional)).sorted()
        guard !normalizedTaskListID.isEmpty,
              !normalizedWorkspaceIDs.isEmpty,
              normalizedWorkspaceIDs.count
                <= ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount else {
            throw POSIXError(.EINVAL)
        }
        try withLockedState(persistTaskSyncSidecar: true) { state in
            guard state.claudeTaskListDestinations.count
                    <= ClaudeHookTaskListDestinationRecord.maximumRecordCount else {
                throw POSIXError(.E2BIG)
            }
            let storageKey = claudeTaskListStorageKey(
                taskListID: normalizedTaskListID,
                taskStoreIdentity: taskStoreIdentity
            )
            guard state.claudeTaskListDestinations[storageKey] != nil
                || state.claudeTaskListDestinations.count
                    < ClaudeHookTaskListDestinationRecord.maximumRecordCount else {
                throw POSIXError(.E2BIG)
            }
            state.claudeTaskListDestinations[storageKey] = ClaudeHookTaskListDestinationRecord(
                taskStoreIdentity: taskStoreIdentity,
                taskListID: normalizedTaskListID,
                workspaceIDs: normalizedWorkspaceIDs,
                updatedAt: Date.now.timeIntervalSince1970
            )
            state.retiredClaudeTaskLists.removeValue(forKey: storageKey)
        }
    }

    /// Returns the exact task-list cleanup proof, including legacy state.
    func claudeTaskListDestinationRecord(
        taskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity
    ) throws -> ClaudeHookTaskListDestinationRecord? {
        guard let normalizedTaskListID = normalizeOptional(taskListID),
              normalizedTaskListID != ".",
              normalizedTaskListID != "..",
              !normalizedTaskListID.contains("/"),
              !normalizedTaskListID.contains("\0") else {
            return nil
        }
        return try withLockedState { state in
            guard state.claudeTaskListDestinations.count
                    <= ClaudeHookTaskListDestinationRecord.maximumRecordCount else {
                throw POSIXError(.E2BIG)
            }
            let storageKey = claudeTaskListStorageKey(
                taskListID: normalizedTaskListID,
                taskStoreIdentity: taskStoreIdentity
            )
            let record = state.claudeTaskListDestinations[storageKey]
                ?? state.claudeTaskListDestinations[normalizedTaskListID]
            guard let record,
                  record.taskListID == normalizedTaskListID,
                  record.taskStoreIdentity == taskStoreIdentity
                    || record.taskStoreIdentity == nil else {
                return nil
            }
            guard record.workspaceIDs.count
                    <= ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount else {
                throw POSIXError(.E2BIG)
            }
            return record
        }
    }

    /// Retains unresolved task-list destinations after cleanup attempts.
    func retainClaudeTaskListDestinations(
        _ retainedWorkspaceIDs: [String],
        for record: ClaudeHookTaskListDestinationRecord
    ) throws {
        let retainedWorkspaceIDSet = Set(retainedWorkspaceIDs.compactMap(normalizeOptional))
        guard retainedWorkspaceIDSet.count
                <= ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount else {
            throw POSIXError(.E2BIG)
        }
        try withLockedState(persistTaskSyncSidecar: true) { state in
            let storageKey = claudeTaskListStorageKey(record)
            guard state.claudeTaskListDestinations[storageKey] == record else { return }
            let remainingWorkspaceIDs = record.workspaceIDs.filter {
                retainedWorkspaceIDSet.contains($0)
            }.sorted()
            if remainingWorkspaceIDs.isEmpty {
                state.claudeTaskListDestinations.removeValue(forKey: storageKey)
            } else {
                state.claudeTaskListDestinations[storageKey] = ClaudeHookTaskListDestinationRecord(
                    taskStoreIdentity: record.taskStoreIdentity,
                    taskListID: record.taskListID,
                    workspaceIDs: remainingWorkspaceIDs,
                    updatedAt: record.updatedAt
                )
            }
        }
    }

    /// Removes one task-list proof after every owner destination is clear.
    func removeClaudeTaskListDestinationRecord(
        _ record: ClaudeHookTaskListDestinationRecord
    ) throws {
        try withLockedState(persistTaskSyncSidecar: true) { state in
            let storageKey = claudeTaskListStorageKey(record)
            guard state.claudeTaskListDestinations[storageKey] == record else { return }
            state.claudeTaskListDestinations.removeValue(forKey: storageKey)
        }
    }

    /// Restores one destination proof when a subsequent external mutation was
    /// rejected. The compare-and-set against `after` keeps a newer hook's
    /// authoritative destination intact.
    @discardableResult
    func restoreClaudeTaskListDestinationRecord(
        before: ClaudeHookTaskListDestinationRecord?,
        after: ClaudeHookTaskListDestinationRecord
    ) throws -> Bool {
        try withLockedState(persistTaskSyncSidecar: true) { state in
            let afterStorageKey = claudeTaskListStorageKey(after)
            guard state.claudeTaskListDestinations[afterStorageKey] == after else {
                return false
            }
            state.claudeTaskListDestinations.removeValue(forKey: afterStorageKey)
            if let before {
                state.claudeTaskListDestinations[claudeTaskListStorageKey(before)] = before
            }
            return true
        }
    }

    /// Returns the unique retained automatic-team proof for a hook identity.
    ///
    /// Team proofs are stored outside individual sessions because process-based
    /// teammates and their leader can emit hooks under different session IDs.
    func claudeTeamTaskBindingRecord(
        sessionId: String,
        agentId: String?,
        taskStoreIdentity: ClaudeTaskStoreIdentity
    ) throws -> ClaudeHookTeamTaskBindingRecord? {
        let normalizedSessionId = normalizeSessionId(sessionId)
        let normalizedAgentId = normalizeOptional(agentId)
        guard !normalizedSessionId.isEmpty || normalizedAgentId != nil else { return nil }
        return try withLockedState { state in
            guard state.claudeTeamTaskBindings.count
                    <= ClaudeHookTeamTaskBindingRecord.maximumRecordCount else {
                throw POSIXError(.E2BIG)
            }
            let identityMatches = state.claudeTeamTaskBindings.values.compactMap { record in
                record.binding.matches(
                    sessionID: normalizedSessionId,
                    agentID: normalizedAgentId
                ) ? record : nil
            }
            let exactMatches = identityMatches.filter {
                $0.binding.taskStoreIdentity == taskStoreIdentity
            }
            let legacyMatches = identityMatches.filter {
                $0.binding.taskStoreIdentity == nil
            }
            let match: ClaudeHookTeamTaskBindingRecord?
            if exactMatches.count == 1 {
                match = exactMatches[0]
            } else if exactMatches.isEmpty, legacyMatches.count == 1 {
                match = legacyMatches[0]
            } else {
                match = nil
            }
            guard let match else { return nil }
            guard match.workspaceIDs.count <= ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount else {
                throw POSIXError(.E2BIG)
            }
            return match
        }
    }

    /// Returns the exact durable owner record for a canonical task list.
    ///
    /// TeamDelete can arrive after Claude has already replaced the session or
    /// agent identity, so final cleanup must resolve by the owner storage key.
    func claudeTeamTaskBindingRecord(
        taskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity
    ) throws -> ClaudeHookTeamTaskBindingRecord? {
        guard let normalizedTaskListID = normalizeOptional(taskListID),
              normalizedTaskListID != ".",
              normalizedTaskListID != "..",
              !normalizedTaskListID.contains("/"),
              !normalizedTaskListID.contains("\0") else {
            return nil
        }
        return try withLockedState { state in
            guard state.claudeTeamTaskBindings.count
                    <= ClaudeHookTeamTaskBindingRecord.maximumRecordCount else {
                throw POSIXError(.E2BIG)
            }
            let storageKey = claudeTeamTaskBindingStorageKey(
                taskListID: normalizedTaskListID,
                taskStoreIdentity: taskStoreIdentity
            )
            let record: ClaudeHookTeamTaskBindingRecord
            if let exactRecord = state.claudeTeamTaskBindings[storageKey] {
                guard exactRecord.binding.taskStoreIdentity == taskStoreIdentity,
                      exactRecord.binding.taskListID == normalizedTaskListID else {
                    return nil
                }
                record = exactRecord
            } else {
                guard let legacyRecord = state.claudeTeamTaskBindings[normalizedTaskListID],
                      legacyRecord.binding.taskStoreIdentity == nil,
                      legacyRecord.binding.taskListID == normalizedTaskListID else {
                    return nil
                }
                record = legacyRecord
            }
            guard record.workspaceIDs.count
                    <= ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount else {
                throw POSIXError(.E2BIG)
            }
            return record
        }
    }

    /// Plans the exact owner cleanup required before persisting a team proof.
    func claudeTeamTaskBindingTransition(
        _ binding: ClaudeTeamTaskListBinding,
        workspaceId: String
    ) throws -> (
        workspaceIDs: [String],
        retiredRecords: [ClaudeHookTeamTaskBindingRecord]
    ) {
        let normalizedWorkspaceId = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWorkspaceId.isEmpty else {
            throw POSIXError(.EINVAL)
        }
        return try withLockedState { state in
            guard state.claudeTeamTaskBindings.count <= ClaudeHookTeamTaskBindingRecord.maximumRecordCount else {
                throw POSIXError(.E2BIG)
            }
            var workspaceIDs: Set<String> = [normalizedWorkspaceId]
            var retiredRecords: [ClaudeHookTeamTaskBindingRecord] = []
            for record in state.claudeTeamTaskBindings.values {
                if sameClaudeTeam(record.binding, binding) {
                    workspaceIDs.formUnion(record.workspaceIDs)
                    continue
                }
                guard conflictingClaudeTeams(record.binding, binding) else { continue }
                retiredRecords.append(record)
                if record.binding.leaderSessionID != nil,
                   record.binding.leaderSessionID == binding.leaderSessionID {
                    workspaceIDs.formUnion(record.workspaceIDs)
                }
            }
            let newStorageKey = claudeTeamTaskBindingStorageKey(binding)
            let retiredStorageKeys = Set(retiredRecords.map {
                claudeTeamTaskBindingStorageKey($0.binding)
            })
            let newRecordSurvives = state.claudeTeamTaskBindings[newStorageKey] != nil
                && !retiredStorageKeys.contains(newStorageKey)
            let projectedCount = state.claudeTeamTaskBindings.count
                - retiredRecords.count
                + (newRecordSurvives ? 0 : 1)
            if projectedCount > ClaudeHookTeamTaskBindingRecord.maximumRecordCount {
                let capacityRetirements = state.claudeTeamTaskBindings.values
                    .filter { record in
                        !retiredStorageKeys.contains(
                            claudeTeamTaskBindingStorageKey(record.binding)
                        )
                    }
                    .sorted { lhs, rhs in
                        if lhs.updatedAt != rhs.updatedAt {
                            return lhs.updatedAt < rhs.updatedAt
                        }
                        return claudeTeamTaskBindingStorageKey(lhs.binding)
                            < claudeTeamTaskBindingStorageKey(rhs.binding)
                    }
                let retirementCount = projectedCount
                    - ClaudeHookTeamTaskBindingRecord.maximumRecordCount
                guard capacityRetirements.count >= retirementCount else {
                    throw POSIXError(.E2BIG)
                }
                retiredRecords.append(contentsOf: capacityRetirements.prefix(retirementCount))
            }
            workspaceIDs.insert(normalizedWorkspaceId)
            guard workspaceIDs.count <= ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount else {
                throw POSIXError(.E2BIG)
            }
            return (workspaceIDs.sorted(), retiredRecords)
        }
    }

    /// Commits a planned team transition after every retired owner was cleared.
}
