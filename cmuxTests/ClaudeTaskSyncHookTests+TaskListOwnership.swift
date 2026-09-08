import CMUXAgentLaunch
import Dispatch
import Foundation
import Testing

extension ClaudeTaskSyncHookTests {
    @Test("Team task directories bind by exact task identity and remain bound")
    func resolvesTeamTaskDirectoryByTaskIdentity() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-team")
        defer { context.cleanup() }
        let workspaceId = "55555555-5555-5555-5555-555555555555"
        let surfaceId = "66666666-6666-6666-6666-666666666666"
        let sessionId = "unrelated-hook-session"
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path
        )

        let tasksRoot = context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        let teamDirectory = tasksRoot.appendingPathComponent("session-team-a", isDirectory: true)
        let neighboringDirectory = tasksRoot.appendingPathComponent("session-team-b", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighboringDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Team task","activeForm":"Running team task","status":"in_progress"}"#,
            named: "1.json",
            in: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Neighbor task","status":"pending"}"#,
            named: "1.json",
            in: neighboringDirectory
        )

        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        let createResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate",
            standardInput: #"{"session_id":"unrelated-hook-session","hook_event_name":"PostToolUse","tool_name":"TaskCreate","tool_input":{"subject":"Team task","description":"probe"},"tool_response":{"task":{"id":"1","subject":"Team task"}}}"#
        )

        #expect(!createResult.timedOut, Comment(rawValue: createResult.stderr))
        #expect(createResult.status == 0, Comment(rawValue: createResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let createdItems = try #require(reconcileRequests(in: context).last?["items"] as? [[String: Any]])
        #expect(createdItems.compactMap { $0["text"] as? String } == ["Running team task"])
        let boundRecord = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        )
        #expect(boundRecord["claudeTaskDirectoryName"] as? String == "session-team-a")

        try writeTask(
            #"{"id":"1","subject":"Team task","activeForm":"Running team task","status":"completed"}"#,
            named: "1.json",
            in: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Team task","status":"pending"}"#,
            named: "1.json",
            in: neighboringDirectory
        )
        let updateResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate",
            standardInput: #"{"session_id":"unrelated-hook-session","hook_event_name":"PostToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"completed"}}"#
        )

        #expect(!updateResult.timedOut, Comment(rawValue: updateResult.stderr))
        #expect(updateResult.status == 0, Comment(rawValue: updateResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let updatedItems = try #require(reconcileRequests(in: context).last?["items"] as? [[String: Any]])
        #expect(updatedItems.isEmpty)

        try FileManager.default.removeItem(at: teamDirectory.appendingPathComponent("1.json"))
        let deleteResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate",
            standardInput: #"{"session_id":"unrelated-hook-session","hook_event_name":"PostToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"deleted"},"tool_response":{"task":{"id":"1","subject":"Team task","status":"deleted"}}}"#
        )

        #expect(!deleteResult.timedOut, Comment(rawValue: deleteResult.stderr))
        #expect(deleteResult.status == 0, Comment(rawValue: deleteResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let deletedItems = try #require(reconcileRequests(in: context).last?["items"] as? [[String: Any]])
        #expect(deletedItems.isEmpty)
    }

    @Test("An ambiguous team task identity publishes no todo mutation")
    func rejectsAmbiguousTeamTaskDirectory() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-ambiguous")
        defer { context.cleanup() }
        let workspaceId = "77777777-7777-7777-7777-777777777777"
        let surfaceId = "88888888-8888-8888-8888-888888888888"
        let sessionId = "ambiguous-hook-session"
        _ = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path
        )

        let tasksRoot = context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        for directoryName in ["session-team-a", "session-team-b"] {
            let directory = tasksRoot.appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeTask(
                #"{"id":"1","subject":"Shared task","status":"pending"}"#,
                named: "1.json",
                in: directory
            )
        }

        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        let result = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate",
            standardInput: #"{"session_id":"ambiguous-hook-session","hook_event_name":"PostToolUse","tool_name":"TaskCreate","tool_input":{"subject":"Shared task"},"tool_response":{"task":{"id":"1","subject":"Shared task"}}}"#
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let mutationMethods = context.state.snapshot().compactMap { line -> String? in
            guard let method = jsonObject(line)?["method"] as? String,
                  method == "feed.push" || method == "workspace.todo.reconcile" else { return nil }
            return method
        }
        #expect(mutationMethods.isEmpty)
        let record = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        )
        #expect(record["claudeTaskDirectoryName"] == nil)
    }

    @Test("Configured shared task lists keep one identity while the leader remains active")
    func usesConfiguredSharedTaskListIdentity() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-shared")
        defer { context.cleanup() }
        let workspaceId = "99999999-9999-9999-9999-999999999999"
        let surfaceId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let teammateWorkspaceId = "17171717-1717-1717-1717-171717171717"
        let teammateSurfaceId = "18181818-1818-1818-1818-181818181818"
        let taskListID = "shared/task list"
        let taskDirectoryName = "shared-task-list"
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            workspaceIDsBySurface: [teammateSurfaceId: teammateWorkspaceId]
        )
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(taskDirectoryName)", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Shared task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )

        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CLAUDE_CODE_TASK_LIST_ID"] = taskListID
        let leaderSessionId = "shared-list-leader"
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: leaderSessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            markActive: true
        )
        let leaderResult = runHook(
            context: context,
            environment: environment,
            sessionId: leaderSessionId,
            toolName: "TaskList"
        )
        #expect(!leaderResult.timedOut, Comment(rawValue: leaderResult.stderr))
        #expect(leaderResult.status == 0, Comment(rawValue: leaderResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        try writeTask(
            #"{"id":"1","subject":"Shared task","activeForm":"Updating shared task","status":"in_progress"}"#,
            named: "1.json",
            in: taskDirectory
        )
        var nestedEnvironment = environment
        nestedEnvironment["CMUX_AGENT_MANAGED_SUBAGENT"] = "1"
        nestedEnvironment["CMUX_WORKSPACE_ID"] = teammateWorkspaceId
        nestedEnvironment["CMUX_SURFACE_ID"] = teammateSurfaceId
        let teammateSessionId = "shared-list-teammate"
        let teammateResult = runHook(
            context: context,
            environment: nestedEnvironment,
            sessionId: teammateSessionId,
            toolName: "TaskUpdate"
        )
        #expect(!teammateResult.timedOut, Comment(rawValue: teammateResult.stderr))
        #expect(teammateResult.status == 0, Comment(rawValue: teammateResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        try FileManager.default.removeItem(at: taskDirectory.appendingPathComponent("1.json"))
        let deletionSessionId = "shared-list-deletion"
        let deletionResult = runHook(
            context: context,
            environment: environment,
            sessionId: deletionSessionId,
            toolName: "TaskUpdate",
            standardInput: #"{"session_id":"shared-list-deletion","hook_event_name":"PostToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"deleted"}}"#
        )
        #expect(!deletionResult.timedOut, Comment(rawValue: deletionResult.stderr))
        #expect(deletionResult.status == 0, Comment(rawValue: deletionResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let reconciliations = reconcileRequests(in: context)
        #expect(reconciliations.count == 5)
        let sharedOwnerID = taskOwnerID(
            directoryName: taskDirectoryName,
            tasksRootURL: taskDirectory.deletingLastPathComponent()
        )
        #expect(reconciliations.allSatisfy {
            $0["owner_id"] as? String == sharedOwnerID
        })
        let leaderItems = try #require(reconciliations.first?["items"] as? [[String: Any]])
        let teammateItems = try #require(reconciliations[1]["items"] as? [[String: Any]])
        let deletionItems = try #require(reconciliations.last?["items"] as? [[String: Any]])
        #expect(leaderItems.first?["id"] as? String == teammateItems.first?["id"] as? String)
        #expect(deletionItems.isEmpty)

        var teamDeleteEnvironment = environment
        teamDeleteEnvironment.removeValue(forKey: "CLAUDE_CODE_TASK_LIST_ID")
        let teamDeleteSessionId = "shared-list-team-delete"
        let teamDeleteResult = runHook(
            context: context,
            environment: teamDeleteEnvironment,
            sessionId: teamDeleteSessionId,
            toolName: "TeamDelete",
            standardInput: #"{"session_id":"shared-list-team-delete","hook_event_name":"PostToolUse","tool_name":"TeamDelete","tool_input":{"team_name":"shared/task list"},"tool_response":{"success":true}}"#
        )
        #expect(!teamDeleteResult.timedOut, Comment(rawValue: teamDeleteResult.stderr))
        #expect(teamDeleteResult.status == 0, Comment(rawValue: teamDeleteResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let teamDeleteRequests = reconcileRequests(in: context).suffix(2)
        #expect(Set(teamDeleteRequests.compactMap { $0["workspace_id"] as? String }) == [
            workspaceId,
            teammateWorkspaceId,
        ])
        #expect(teamDeleteRequests.allSatisfy {
            $0["owner_id"] as? String == sharedOwnerID
                && ($0["items"] as? [[String: Any]])?.isEmpty == true
        })
        #expect(try taskListDestinationRecords(in: context.storeURL).isEmpty)
        let taskStoreIdentity = ClaudeTaskStoreIdentity(
            tasksRootURL: taskDirectory.deletingLastPathComponent()
        )
        let stateAfterDelete = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: context.storeURL)
            ) as? [String: Any]
        )
        let retiredAfterDelete = stateAfterDelete["retiredClaudeTaskLists"] as? [String: Any]
        #expect(
            retiredAfterDelete?["\(taskStoreIdentity.rawValue):\(taskDirectoryName)"] != nil,
            "A successful TeamDelete must leave a retirement fence for delayed hooks"
        )
        let reconciliationCountBeforeDelayedHook = reconcileRequests(in: context).count
        let delayedHookResult = runHook(
            context: context,
            environment: environment,
            sessionId: leaderSessionId,
            toolName: "TaskUpdate"
        )
        #expect(!delayedHookResult.timedOut, Comment(rawValue: delayedHookResult.stderr))
        #expect(delayedHookResult.status == 0, Comment(rawValue: delayedHookResult.stderr))
        #expect(
            reconcileRequests(in: context).count == reconciliationCountBeforeDelayedHook,
            "A delayed task hook must not re-admit the retired task-list owner"
        )

        let feedSessionIds = context.state.snapshot().compactMap(feedEvent)
            .compactMap { $0["session_id"] as? String }
        #expect(feedSessionIds == [
            "claude-\(leaderSessionId)",
            "claude-\(teammateSessionId)",
            "claude-\(deletionSessionId)",
            "claude-\(teamDeleteSessionId)",
        ])
        let leaderRecord = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: leaderSessionId
            )
        )
        #expect(leaderRecord["claudeTaskDirectoryName"] == nil)
    }

    @Test("A delayed configured-list hook cannot re-admit a retired owner")
    func rejectsDelayedConfiguredTaskListAfterRetirement() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-retired-configured"
        )
        defer { context.cleanup() }
        let workspaceId = "abababab-abab-abab-abab-abababababab"
        let surfaceId = "acacacac-acac-acac-acac-acacacacacac"
        let sessionId = "retired-configured-session"
        let taskListID = "retired-configured-list"
        let tasksRoot = context.root.appendingPathComponent(
            ".claude/tasks",
            isDirectory: true
        )
        let taskDirectory = tasksRoot.appendingPathComponent(
            taskListID,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Retained task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CLAUDE_CODE_TASK_LIST_ID"] = taskListID

        let initialResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        #expect(!initialResult.timedOut, Comment(rawValue: initialResult.stderr))
        #expect(initialResult.status == 0, Comment(rawValue: initialResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let taskStoreIdentity = ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
        try retireTaskList(
            taskListID: taskListID,
            taskStoreIdentity: taskStoreIdentity,
            retiredAt: Date().timeIntervalSince1970 + 1,
            storeURL: context.storeURL
        )
        let requestCountBeforeDelayedHook = reconcileRequests(in: context).count
        let delayedResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )

        #expect(!delayedResult.timedOut, Comment(rawValue: delayedResult.stderr))
        #expect(delayedResult.status == 0, Comment(rawValue: delayedResult.stderr))
        #expect(reconcileRequests(in: context).count == requestCountBeforeDelayedHook)
        let state = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: context.storeURL)
            ) as? [String: Any]
        )
        let retired = state["retiredClaudeTaskLists"] as? [String: Any]
        #expect(retired?["\(taskStoreIdentity.rawValue):\(taskListID)"] != nil)
    }

    @Test("A new SessionStart generation cannot reuse a prior task-directory proof")
    func rejectsPriorTaskDirectoryAfterSessionGenerationReset() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-generation-fence"
        )
        defer { context.cleanup() }
        let workspaceId = "adadadad-adad-adad-adad-adadadadadad"
        let surfaceId = "aeaeaeae-aeae-aeae-aeae-aeaeaeaeaeae"
        let sessionId = "generation-fence-session"
        let taskListID = "prior-shared-list"
        let tasksRoot = context.root.appendingPathComponent(
            ".claude/tasks",
            isDirectory: true
        )
        let taskDirectory = tasksRoot.appendingPathComponent(
            taskListID,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Prior generation task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var configuredEnvironment = ClaudeHookLiveDeliveryHarness.hookEnvironment(
            context: context
        )
        configuredEnvironment["CMUX_WORKSPACE_ID"] = workspaceId
        configuredEnvironment["CMUX_SURFACE_ID"] = surfaceId
        configuredEnvironment["CLAUDE_CODE_TASK_LIST_ID"] = taskListID

        let initialResult = runHook(
            context: context,
            environment: configuredEnvironment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        #expect(!initialResult.timedOut, Comment(rawValue: initialResult.stderr))
        #expect(initialResult.status == 0, Comment(rawValue: initialResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        var newGenerationEnvironment = configuredEnvironment
        newGenerationEnvironment.removeValue(forKey: "CLAUDE_CODE_TASK_LIST_ID")
        let sessionStartResult = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            environment: newGenerationEnvironment,
            standardInput: #"{"session_id":"generation-fence-session","source":"clear","hook_event_name":"SessionStart"}"#
        )
        #expect(!sessionStartResult.timedOut, Comment(rawValue: sessionStartResult.stderr))
        #expect(sessionStartResult.status == 0, Comment(rawValue: sessionStartResult.stderr))

        let requestCountBeforeLateHook = reconcileRequests(in: context).count
        let lateResult = runHook(
            context: context,
            environment: newGenerationEnvironment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )
        #expect(!lateResult.timedOut, Comment(rawValue: lateResult.stderr))
        #expect(lateResult.status == 0, Comment(rawValue: lateResult.stderr))
        #expect(reconcileRequests(in: context).count == requestCountBeforeLateHook)
    }

}
