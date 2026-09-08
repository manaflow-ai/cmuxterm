import CMUXAgentLaunch
import Foundation

extension ClaudeHookSessionStore {
    func commitClaudeTeamTaskListBinding(
        _ binding: ClaudeTeamTaskListBinding,
        workspaceIDs: [String],
        retiredRecords: [ClaudeHookTeamTaskBindingRecord]
    ) throws -> [String] {
        let normalizedWorkspaceIDs = Set(workspaceIDs.compactMap(normalizeOptional)).sorted()
        guard !normalizedWorkspaceIDs.isEmpty else {
            throw POSIXError(.EINVAL)
        }
        guard normalizedWorkspaceIDs.count
                <= ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount else {
            throw POSIXError(.E2BIG)
        }
        return try withLockedState(persistTaskSyncSidecar: true) { state in
            guard state.claudeTeamTaskBindings.count <= ClaudeHookTeamTaskBindingRecord.maximumRecordCount else {
                throw POSIXError(.E2BIG)
            }
            for retiredRecord in retiredRecords {
                let retiredStorageKey = claudeTeamTaskBindingStorageKey(
                    retiredRecord.binding
                )
                guard state.claudeTeamTaskBindings[retiredStorageKey] == retiredRecord else {
                    throw POSIXError(.EAGAIN)
                }
            }
            let retiredStorageKeys = Set(retiredRecords.map {
                claudeTeamTaskBindingStorageKey($0.binding)
            })
            for (storageKey, record) in state.claudeTeamTaskBindings
                where !retiredStorageKeys.contains(storageKey) {
                guard sameClaudeTeam(record.binding, binding)
                    || !conflictingClaudeTeams(record.binding, binding) else {
                    throw POSIXError(.EAGAIN)
                }
            }
            for storageKey in retiredStorageKeys {
                state.claudeTeamTaskBindings.removeValue(forKey: storageKey)
            }
            let storageKey = claudeTeamTaskBindingStorageKey(binding)
            guard state.claudeTeamTaskBindings[storageKey] != nil
                || state.claudeTeamTaskBindings.count
                    < ClaudeHookTeamTaskBindingRecord.maximumRecordCount else {
                throw POSIXError(.E2BIG)
            }
            state.claudeTeamTaskBindings[storageKey] = ClaudeHookTeamTaskBindingRecord(
                binding: binding,
                workspaceIDs: normalizedWorkspaceIDs,
                updatedAt: Date.now.timeIntervalSince1970
            )
            state.retiredClaudeTaskLists.removeValue(forKey: storageKey)
            return normalizedWorkspaceIDs
        }
    }

    /// Drops closed workspaces and removes a team proof with no destinations.
    func retainClaudeTeamTaskBindingWorkspaces(
        _ retainedWorkspaceIDs: [String],
        for binding: ClaudeTeamTaskListBinding
    ) throws {
        let retainedWorkspaceIDSet = Set(retainedWorkspaceIDs.compactMap(normalizeOptional))
        guard retainedWorkspaceIDSet.count
                <= ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount else {
            throw POSIXError(.E2BIG)
        }
        try withLockedState(persistTaskSyncSidecar: true) { state in
            let storageKey = claudeTeamTaskBindingStorageKey(binding)
            guard let record = state.claudeTeamTaskBindings[storageKey],
                  record.binding == binding else {
                return
            }
            let remainingWorkspaceIDs = record.workspaceIDs.filter {
                retainedWorkspaceIDSet.contains($0)
            }.sorted()
            guard remainingWorkspaceIDs != record.workspaceIDs else { return }
            if remainingWorkspaceIDs.isEmpty {
                state.claudeTeamTaskBindings.removeValue(forKey: storageKey)
            } else {
                state.claudeTeamTaskBindings[storageKey] = ClaudeHookTeamTaskBindingRecord(
                    binding: record.binding,
                    workspaceIDs: remainingWorkspaceIDs,
                    updatedAt: record.updatedAt
                )
            }
        }
    }

    func sameClaudeTeam(
        _ lhs: ClaudeTeamTaskListBinding,
        _ rhs: ClaudeTeamTaskListBinding
    ) -> Bool {
        guard lhs.taskStoreIdentity == rhs.taskStoreIdentity else { return false }
        guard lhs.taskListID == rhs.taskListID else { return false }
        if lhs.leaderSessionID != nil || rhs.leaderSessionID != nil {
            return lhs.leaderSessionID == rhs.leaderSessionID
        }
        // Older/leaderless Claude configs have no stable leader field. An
        // overlapping exact member proves continuity across membership edits;
        // a fully disjoint member set is a same-named replacement instead.
        return !Set(lhs.agentIDs).isDisjoint(with: rhs.agentIDs)
    }

    func conflictingClaudeTeams(
        _ lhs: ClaudeTeamTaskListBinding,
        _ rhs: ClaudeTeamTaskListBinding
    ) -> Bool {
        if let lhsTaskStoreIdentity = lhs.taskStoreIdentity,
           let rhsTaskStoreIdentity = rhs.taskStoreIdentity,
           lhsTaskStoreIdentity != rhsTaskStoreIdentity {
            return false
        }
        if lhs.taskListID == rhs.taskListID { return true }
        if let leaderSessionID = lhs.leaderSessionID,
           leaderSessionID == rhs.leaderSessionID {
            return true
        }
        return !Set(lhs.agentIDs).isDisjoint(with: rhs.agentIDs)
    }

    /// Retires one consumed cleanup proof after its empty owner sync succeeds.
    func removeClaudeTeamTaskListBinding(
        _ binding: ClaudeTeamTaskListBinding
    ) throws {
        try withLockedState(persistTaskSyncSidecar: true) { state in
            let storageKey = claudeTeamTaskBindingStorageKey(binding)
            guard state.claudeTeamTaskBindings[storageKey]?.binding == binding else {
                return
            }
            state.claudeTeamTaskBindings.removeValue(forKey: storageKey)
        }
    }

    /// Restores a team ownership proof when its first-sighting Feed delivery
    /// was rejected. The compare-and-set preserves a sibling hook's newer
    /// transition if it changed the proof after this hook committed it.
    @discardableResult
    func restoreClaudeTeamTaskBinding(
        before: ClaudeHookTeamTaskBindingRecord?,
        after: ClaudeHookTeamTaskBindingRecord
    ) throws -> Bool {
        try withLockedState(persistTaskSyncSidecar: true) { state in
            let afterStorageKey = claudeTeamTaskBindingStorageKey(after.binding)
            guard state.claudeTeamTaskBindings[afterStorageKey] == after else {
                return false
            }
            state.claudeTeamTaskBindings.removeValue(forKey: afterStorageKey)
            if let before {
                state.claudeTeamTaskBindings[
                    claudeTeamTaskBindingStorageKey(before.binding)
                ] = before
            }
            return true
        }
    }

    func claudeTeamTaskBindingStorageKey(
        _ binding: ClaudeTeamTaskListBinding
    ) -> String {
        guard let taskStoreIdentity = binding.taskStoreIdentity else {
            return binding.taskListID
        }
        return claudeTeamTaskBindingStorageKey(
            taskListID: binding.taskListID,
            taskStoreIdentity: taskStoreIdentity
        )
    }

    func claudeTeamTaskBindingStorageKey(
        taskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity
    ) -> String {
        claudeTaskListStorageKey(
            taskListID: taskListID,
            taskStoreIdentity: taskStoreIdentity
        )
    }

    func claudeTaskListStorageKey(
        _ record: ClaudeHookTaskListDestinationRecord
    ) -> String {
        guard let taskStoreIdentity = record.taskStoreIdentity else {
            return record.taskListID
        }
        return claudeTaskListStorageKey(
            taskListID: record.taskListID,
            taskStoreIdentity: taskStoreIdentity
        )
    }

    func claudeTaskListStorageKey(
        taskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity
    ) -> String {
        "\(taskStoreIdentity.rawValue):\(taskListID)"
    }

    /// Records one Cursor shell command for atomic completion correlation.
    /// Cursor's after/failure hook payloads do not expose the native approval
    /// decision or a stable tool id, so the normalized command is the durable
    /// identity shared by the before and terminal hook callbacks.
}
