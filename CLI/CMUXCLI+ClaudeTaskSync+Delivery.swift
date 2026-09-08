import CMUXAgentLaunch
import CryptoKit
import Foundation

extension CMUXCLI {
    func deliverClaudeTaskSnapshot(
        _ snapshot: ClaudeTaskSnapshot,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        parsedInput: ClaudeHookParsedInput,
        workspaceId: String,
        surfaceId: String,
        reconciliationWorkspaceIDs: [String],
        socketPassword: String?,
        deadlineUptime: TimeInterval
    ) -> (
        reconciliationSucceeded: Bool,
        workspaceItemsAreEmpty: Bool,
        retainedWorkspaceIDs: [String]
    )? {
        let validation = reconcileClaudeTaskSnapshot(
            snapshot,
            taskStoreIdentity: taskStoreIdentity,
            client: client,
            telemetry: telemetry,
            reconciliationWorkspaceIDs: reconciliationWorkspaceIDs,
            deadlineUptime: deadlineUptime,
            validateOnly: true
        )
        // A closed destination is already a valid cleanup outcome; let the
        // real reconciliation retire it and preserve the existing Feed path.
        // Any retained destination means validation found a mutation error
        // (most importantly the combined checklist cap), so do not advance
        // Feed before that rejection is surfaced.
        guard let validation,
              validation.reconciliationSucceeded || validation.retainedWorkspaceIDs.isEmpty else {
            return nil
        }
        guard sendClaudeTaskFeedSnapshot(
            snapshot.todos,
            client: client,
            telemetry: telemetry,
            parsedInput: parsedInput,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            socketPassword: socketPassword,
            deadlineUptime: deadlineUptime
        ) else { return nil }

        return reconcileClaudeTaskSnapshot(
            snapshot,
            taskStoreIdentity: taskStoreIdentity,
            client: client,
            telemetry: telemetry,
            reconciliationWorkspaceIDs: reconciliationWorkspaceIDs,
            deadlineUptime: deadlineUptime,
            validateOnly: false
        )
    }

    /// Reconciles a task snapshot whose authoritative Feed update is acknowledged.
    func reconcileClaudeTaskSnapshot(
        _ snapshot: ClaudeTaskSnapshot,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        reconciliationWorkspaceIDs: [String],
        deadlineUptime: TimeInterval,
        validateOnly: Bool = false
    ) -> (
        reconciliationSucceeded: Bool,
        workspaceItemsAreEmpty: Bool,
        retainedWorkspaceIDs: [String]
    )? {
        guard let checklistOwnerID = claudeTaskChecklistOwnerID(
            taskDirectoryName: snapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity
        ) else {
            telemetry.breadcrumb("claude-hook.task-sync.invalid-checklist-owner")
            return nil
        }
        let todos = snapshot.todos

        // Claude removes an all-completed task list on its own grace timer
        // without firing another task-tool hook. Keep the complete snapshot in
        // Feed but clear terminal rows from the workspace progress view.
        let checklistTodos = todos.allSatisfy { $0.state == .completed } ? [] : todos
        let checklistItems = checklistTodos.map {
            claudeTaskChecklistDictionary(
                $0,
                taskDirectoryName: snapshot.directoryName,
                taskStoreIdentity: taskStoreIdentity
            )
        }
        let reconciliation = reconcileClaudeTaskChecklistOwner(
            checklistOwnerID: checklistOwnerID,
            checklistItems: checklistItems,
            client: client,
            telemetry: telemetry,
            workspaceIDs: reconciliationWorkspaceIDs,
            deadlineUptime: deadlineUptime,
            validateOnly: validateOnly
        )
        return (
            reconciliation.succeeded,
            checklistItems.isEmpty,
            reconciliation.retainedWorkspaceIDs
        )
    }

    func sendClaudeTaskFeedSnapshot(
        _ todos: [WorkstreamTaskTodo],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        parsedInput: ClaudeHookParsedInput,
        workspaceId: String,
        surfaceId: String,
        socketPassword: String?,
        deadlineUptime: TimeInterval
    ) -> Bool {
        let remainingSeconds = deadlineUptime - ProcessInfo.processInfo.systemUptime
        guard remainingSeconds > 0 else {
            telemetry.breadcrumb("claude-hook.task-sync.deadline-exceeded")
            return false
        }
        let delivered = sendFeedTelemetry(
            client: client,
            source: "claude",
            subcommand: "task-sync",
            parsedInput: parsedInput,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            socketPassword: socketPassword,
            delivery: .acknowledged(responseTimeout: min(5, remainingSeconds)),
            toolNameOverride: "TodoWrite",
            toolInputOverride: ["todos": todos.map(claudeTaskFeedDictionary)]
        )
        if !delivered {
            telemetry.breadcrumb("claude-hook.task-sync.feed-delivery-failed")
        }
        return delivered
    }

    func clearClaudeTaskChecklistOwner(
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity?,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        workspaceIDs: [String],
        deadlineUptime: TimeInterval
    ) -> (succeeded: Bool, retainedWorkspaceIDs: [String]) {
        guard let checklistOwnerID = claudeTaskChecklistOwnerID(
            taskDirectoryName: taskDirectoryName,
            taskStoreIdentity: taskStoreIdentity
        ) else {
            telemetry.breadcrumb("claude-hook.task-sync.invalid-checklist-owner")
            return (false, workspaceIDs)
        }
        return reconcileClaudeTaskChecklistOwner(
            checklistOwnerID: checklistOwnerID,
            checklistItems: [],
            client: client,
            telemetry: telemetry,
            workspaceIDs: workspaceIDs,
            deadlineUptime: deadlineUptime
        )
    }

    /// Clears a task owner in bounded socket pages for terminal deletion.
    func drainClaudeTaskChecklistOwner(
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        workspaceIDs: [String],
        deadlineUptime: TimeInterval
    ) -> (succeeded: Bool, completed: Bool) {
        var remainingWorkspaceIDs = Set(workspaceIDs.compactMap {
            let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }).sorted()
        while !remainingWorkspaceIDs.isEmpty {
            let page = Array(
                remainingWorkspaceIDs.prefix(
                    ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount
                )
            )
            let cleanup = clearClaudeTaskChecklistOwner(
                taskDirectoryName: taskDirectoryName,
                taskStoreIdentity: taskStoreIdentity,
                client: client,
                telemetry: telemetry,
                workspaceIDs: page,
                deadlineUptime: deadlineUptime
            )
            guard cleanup.succeeded else { return (false, false) }
            remainingWorkspaceIDs.removeFirst(page.count)
            guard remainingWorkspaceIDs.isEmpty
                    || ProcessInfo.processInfo.systemUptime < deadlineUptime else {
                telemetry.breadcrumb("claude-hook.task-sync.owner-cleanup-deferred")
                return (true, false)
            }
        }
        return (true, true)
    }

    func reconcileClaudeTaskChecklistOwner(
        checklistOwnerID: String,
        checklistItems: [[String: Any]],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        workspaceIDs: [String],
        deadlineUptime: TimeInterval,
        validateOnly: Bool = false
    ) -> (succeeded: Bool, retainedWorkspaceIDs: [String]) {
        let destinationWorkspaceIDs = Set(workspaceIDs.compactMap {
            let workspaceID = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return workspaceID.isEmpty ? nil : workspaceID
        }).sorted()
        guard !destinationWorkspaceIDs.isEmpty,
              destinationWorkspaceIDs.count <= ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount else {
            telemetry.breadcrumb("claude-hook.task-sync.invalid-workspace-destinations")
            return (false, destinationWorkspaceIDs)
        }
        let remainingSeconds = deadlineUptime - ProcessInfo.processInfo.systemUptime
        guard remainingSeconds > 0 else {
            telemetry.breadcrumb("claude-hook.task-sync.deadline-exceeded")
            return (false, destinationWorkspaceIDs)
        }
        let response: [String: Any]
        var requestParams: [String: Any] = [
            "workspace_ids": destinationWorkspaceIDs,
            "owner_id": checklistOwnerID,
            "items": checklistItems,
        ]
        if validateOnly {
            requestParams["validate_only"] = true
        }
        do {
            response = try client.sendV2(
                method: "workspace.todo.reconcile",
                params: requestParams,
                responseTimeout: min(5, remainingSeconds)
            )
        } catch {
            telemetry.breadcrumb(
                "claude-hook.task-sync.workspace-batch-error",
                data: ["error": String(describing: error)]
            )
            return (false, destinationWorkspaceIDs)
        }
        guard let rawResults = response["results"] as? [[String: Any]] else {
            telemetry.breadcrumb("claude-hook.task-sync.invalid-workspace-results")
            return (false, destinationWorkspaceIDs)
        }
        var resultsByWorkspaceID: [String: [String: Any]] = [:]
        for result in rawResults {
            guard let workspaceID = result["workspace_id"] as? String,
                  destinationWorkspaceIDs.contains(workspaceID),
                  resultsByWorkspaceID.updateValue(result, forKey: workspaceID) == nil else {
                telemetry.breadcrumb("claude-hook.task-sync.invalid-workspace-results")
                return (false, destinationWorkspaceIDs)
            }
        }

        var reconciliationSucceeded = true
        var retainedWorkspaceIDs: [String] = []
        for destinationWorkspaceID in destinationWorkspaceIDs {
            guard let result = resultsByWorkspaceID[destinationWorkspaceID],
                  let succeeded = result["ok"] as? Bool else {
                reconciliationSucceeded = false
                retainedWorkspaceIDs.append(destinationWorkspaceID)
                continue
            }
            if succeeded {
                retainedWorkspaceIDs.append(destinationWorkspaceID)
                continue
            }
            let error = result["error"] as? [String: Any]
            if error?["code"] as? String == "not_found" {
                telemetry.breadcrumb(
                    "claude-hook.task-sync.workspace-retired",
                    data: ["workspace_id": destinationWorkspaceID]
                )
                continue
            }
            reconciliationSucceeded = false
            retainedWorkspaceIDs.append(destinationWorkspaceID)
            telemetry.breadcrumb(
                "claude-hook.task-sync.workspace-error",
                data: [
                    "error": String(describing: error ?? [:]),
                    "workspace_id": destinationWorkspaceID,
                ]
            )
        }
        return (reconciliationSucceeded, retainedWorkspaceIDs)
    }

    func isClaudeTeamDeleteHook(_ parsedInput: ClaudeHookParsedInput) -> Bool {
        let object = parsedInput.rawObject ?? parsedInput.object
        return object?["tool_name"] as? String == "TeamDelete"
    }

    /// Returns the structured TeamDelete owner independently of ambient environment.
    func claudeTeamDeleteTaskDirectoryName(
        from parsedInput: ClaudeHookParsedInput,
        loader: ClaudeTaskSnapshotLoader
    ) -> String? {
        guard isClaudeTeamDeleteHook(parsedInput) else { return nil }
        let object = parsedInput.rawObject ?? parsedInput.object
        let input = object?["tool_input"] as? [String: Any]
        guard let teamName = nonEmptyClaudeHookIdentifier(
            input?["team_name"] as? String
        ) else { return nil }
        return loader.canonicalDirectoryName(forTaskListID: teamName)
    }

    /// Returns the team task directory named by Claude's synchronous
    /// ``TaskCompleted`` payload, including teammate events that omit
    /// `agent_id` and `CLAUDE_CODE_TASK_LIST_ID`.
    func claudeTaskCompletedTeamDirectoryName(
        from parsedInput: ClaudeHookParsedInput,
        loader: ClaudeTaskSnapshotLoader
    ) -> String? {
        let eventName = reportedHookEventName(from: parsedInput)?.lowercased()
        guard eventName == "taskcompleted" else { return nil }
        let object = parsedInput.rawObject ?? parsedInput.object
        let input = object?["tool_input"] as? [String: Any]
        let teamName = nonEmptyClaudeHookIdentifier(
            (object?["team_name"] as? String)
                ?? (object?["teamName"] as? String)
                ?? (input?["team_name"] as? String)
                ?? (input?["teamName"] as? String)
                ?? ((object?["task"] as? [String: Any])?["team_name"] as? String)
        )
        guard let teamName else { return nil }
        return loader.canonicalDirectoryName(forTaskListID: teamName)
    }

    /// Extracts the exact task identity from Claude's uncompacted hook payload.
    ///
    /// The compact Feed payload intentionally omits `tool_response`, so task
    /// directory resolution must read the original object retained by the hook
    /// parser. A partial identity is never used for directory selection.
    func claudeTaskIdentity(from rawObject: [String: Any]?) -> ClaudeTaskIdentity? {
        let input = rawObject?["tool_input"] as? [String: Any]
        // A successful delete removes the identity-bearing task file before
        // PostToolUse runs. Reuse an existing proven binding (or the exact
        // session path) instead of treating that expected absence as a failed
        // ownership proof.
        if input?["status"] as? String == "deleted" {
            return nil
        }
        let responseTask = (rawObject?["tool_response"] as? [String: Any])?["task"] as? [String: Any]
        let eventTask = rawObject?["task"] as? [String: Any]
        let id = responseTask?["id"] as? String
            ?? eventTask?["id"] as? String
            ?? input?["taskId"] as? String
            ?? input?["task_id"] as? String
            ?? rawObject?["taskId"] as? String
            ?? rawObject?["task_id"] as? String
        guard let id,
              !id.isEmpty else { return nil }
        let responseSubject = responseTask?["subject"] as? String
        let eventSubject = eventTask?["subject"] as? String
        let inputSubject = input?["subject"] as? String
        let rawSubject = rawObject?["task_subject"] as? String
        guard let subject = responseSubject ?? eventSubject ?? inputSubject ?? rawSubject,
              !subject.isEmpty else { return nil }
        return ClaudeTaskIdentity(id: id, subject: subject)
    }

    func claudeTaskFeedDictionary(_ todo: WorkstreamTaskTodo) -> [String: Any] {
        var value: [String: Any] = [
            "id": todo.id,
            "content": todo.content,
            "status": claudeTaskState(todo.state, workspaceWireFormat: false),
        ]
        if let activeForm = todo.activeForm {
            value["activeForm"] = activeForm
        }
        return value
    }

    func claudeTaskChecklistDictionary(
        _ todo: WorkstreamTaskTodo,
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity
    ) -> [String: Any] {
        [
            "id": claudeTaskChecklistID(
                taskDirectoryName: taskDirectoryName,
                taskStoreIdentity: taskStoreIdentity,
                taskID: todo.id
            ).uuidString,
            "text": todo.displayContent,
            "state": claudeTaskState(todo.state, workspaceWireFormat: true),
            "origin": "agent",
        ]
    }

    func claudeTaskChecklistOwnerID(
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity?
    ) -> String? {
        let namespace = taskStoreIdentity.map { "\($0.rawValue):" } ?? ""
        let ownerID = "claude:\(namespace)\(taskDirectoryName)"
        return ownerID.count <= 500 ? ownerID : nil
    }

    func claudeTaskState(
        _ state: WorkstreamTaskTodo.State,
        workspaceWireFormat: Bool
    ) -> String {
        switch state {
        case .pending: return "pending"
        case .inProgress: return workspaceWireFormat ? "in-progress" : "in_progress"
        case .completed: return "completed"
        }
    }

    func claudeTaskChecklistID(
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        taskID: String
    ) -> UUID {
        let name = "cmux.claude-task\0\(taskStoreIdentity.rawValue)\0\(taskDirectoryName)\0\(taskID)"
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
