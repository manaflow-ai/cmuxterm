import CMUXAgentLaunch
import Foundation
import Testing

extension ClaudeAutomaticTeamTaskSyncHookTests {
    @Test("Closed workspaces are retired from a durable team binding")
    func retiresClosedWorkspaceDestination() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-closed-workspace")
        defer { context.cleanup() }
        let closedWorkspaceId = "97979797-9797-9797-9797-979797979797"
        let currentWorkspaceId = "98989898-9898-9898-9898-989898989898"
        let currentSurfaceId = "99999999-9898-9898-9898-989898989898"
        let teamName = "Available_Team"
        let tasksRoot = context.root.appendingPathComponent(
            ".claude/tasks",
            isDirectory: true
        )
        let taskStoreIdentity = ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
        let bindingKey = "\(taskStoreIdentity.rawValue):\(teamName)"
        let state: [String: Any] = [
            "version": 1,
            "sessions": [:],
            "claudeTeamTaskBindings": [
                bindingKey: [
                    "binding": [
                        "taskStoreIdentity": ["rawValue": taskStoreIdentity.rawValue],
                        "taskListID": teamName,
                        "leaderSessionID": "available-leader",
                        "agentIDs": ["available-agent"],
                    ],
                    "workspaceIDs": [closedWorkspaceId, currentWorkspaceId],
                    "updatedAt": 1,
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: context.storeURL)

        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/available-team", isDirectory: true)
        let taskDirectory = tasksRoot.appendingPathComponent(teamName, isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: "available-leader",
            agentID: "available-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Current task","status":"pending"}"#,
            to: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: currentWorkspaceId,
            surfaceId: currentSurfaceId,
            missingWorkspaceIDs: [closedWorkspaceId]
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = currentWorkspaceId
        environment["CMUX_SURFACE_ID"] = currentSurfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: "available-session",
            agentID: "available-agent"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let rawReconcileRequests = context.state.snapshot().compactMap { line -> [String: Any]? in
            guard let request = ClaudeHookLiveDeliveryHarness.jsonObject(line),
                  request["method"] as? String == "workspace.todo.reconcile",
                  let params = request["params"] as? [String: Any],
                  params["validate_only"] as? Bool != true else {
                return nil
            }
            return params
        }
        #expect(rawReconcileRequests.count == 1)
        let rawReconcileRequest = try #require(rawReconcileRequests.first)
        let rawWorkspaceIDs = try #require(rawReconcileRequest["workspace_ids"] as? [String])
        #expect(Set(rawWorkspaceIDs) == Set([
            closedWorkspaceId,
            currentWorkspaceId,
        ]))
        let destinations = reconcileRequests(in: context).compactMap {
            $0["workspace_id"] as? String
        }
        #expect(Set(destinations) == [closedWorkspaceId, currentWorkspaceId])
        let binding = try #require(
            try teamBindingRecords(in: context.storeURL)[bindingKey]
        )
        #expect(binding["workspaceIDs"] as? [String] == [currentWorkspaceId])
    }

    @Test("A team binding is removed when every destination is closed")
    func removesTeamBindingWithNoLiveDestinations() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-no-live-team-workspace"
        )
        defer { context.cleanup() }
        let workspaceId = "90909090-9090-9090-9090-909090909090"
        let surfaceId = "91909090-9090-9090-9090-909090909090"
        let teamName = "Unavailable_Team"
        let tasksRoot = context.root.appendingPathComponent(
            ".claude/tasks",
            isDirectory: true
        )
        let taskStoreIdentity = ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
        let bindingKey = "\(taskStoreIdentity.rawValue):\(teamName)"
        let state: [String: Any] = [
            "version": 1,
            "sessions": [:],
            "claudeTeamTaskBindings": [
                bindingKey: [
                    "binding": [
                        "taskStoreIdentity": ["rawValue": taskStoreIdentity.rawValue],
                        "taskListID": teamName,
                        "leaderSessionID": "unavailable-leader",
                        "agentIDs": ["unavailable-agent"],
                    ],
                    "workspaceIDs": [workspaceId],
                    "updatedAt": 1,
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: context.storeURL)

        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/unavailable-team", isDirectory: true)
        let taskDirectory = tasksRoot.appendingPathComponent(teamName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: teamDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: "unavailable-leader",
            agentID: "unavailable-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Unavailable task","status":"pending"}"#,
            to: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            missingWorkspaceIDs: [workspaceId]
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: "unavailable-session",
            agentID: "unavailable-agent"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(try teamBindingRecords(in: context.storeURL).isEmpty)
    }

    @Test("The binding cap clears and replaces the oldest exact owner")
    func retiresOldestBindingAtCapacity() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-binding-cap")
        defer { context.cleanup() }
        let workspaceId = "91919191-9191-9191-9191-919191919191"
        let surfaceId = "92929292-9292-9292-9292-929292929292"
        let tasksRoot = context.root.appendingPathComponent(
            ".claude/tasks",
            isDirectory: true
        )
        let taskStoreIdentity = ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
        let oldestTaskListID = "ArchivedTeam0"
        var bindings: [String: Any] = [:]
        for index in 0..<128 {
            let taskListID = "ArchivedTeam\(index)"
            bindings["\(taskStoreIdentity.rawValue):\(taskListID)"] = [
                "binding": [
                    "taskStoreIdentity": ["rawValue": taskStoreIdentity.rawValue],
                    "taskListID": taskListID,
                    "leaderSessionID": "archived-leader-\(index)",
                    "agentIDs": ["archived-agent-\(index)"],
                ],
                "workspaceIDs": [workspaceId],
                "updatedAt": index,
            ]
        }
        let state: [String: Any] = [
            "version": 1,
            "sessions": [:],
            "claudeTeamTaskBindings": bindings,
        ]
        try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: context.storeURL)

        let teamName = "Current_Team"
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/current-team", isDirectory: true)
        let taskDirectory = tasksRoot.appendingPathComponent(teamName, isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: "current-leader",
            agentID: "current-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Current task","status":"pending"}"#,
            to: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: "current-session",
            agentID: "current-agent"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let reconciliations = reconcileRequests(in: context)
        #expect(reconciliations.count == 2)
        #expect(reconciliations[0]["owner_id"] as? String == taskOwnerID(
            directoryName: oldestTaskListID,
            tasksRootURL: tasksRoot
        ))
        #expect((reconciliations[0]["items"] as? [[String: Any]])?.isEmpty == true)
        #expect(reconciliations[1]["owner_id"] as? String == taskOwnerID(
            directoryName: teamName,
            tasksRootURL: tasksRoot
        ))

        let persistedBindings = try teamBindingRecords(in: context.storeURL)
        #expect(persistedBindings.count == 128)
        #expect(!persistedBindings.values.contains { record in
            let binding = record["binding"] as? [String: Any]
            return binding?["taskListID"] as? String == oldestTaskListID
        })
        #expect(persistedBindings.values.contains { record in
            let binding = record["binding"] as? [String: Any]
            return binding?["taskListID"] as? String == teamName
        })
    }

    @Test("A delayed TeamDelete cannot clear a reused team task list")
    func preservesReusedTeamAfterDelayedDelete() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-reused-team-delete"
        )
        defer { context.cleanup() }
        let workspaceId = "97979797-9797-9797-9797-979797979797"
        let surfaceId = "98989898-9898-9898-9898-989898989898"
        let teamName = "Reused-Team"
        let oldLeaderSessionID = "reused-old-leader"
        let oldAgentID = "reused-old-agent"
        let newLeaderSessionID = "reused-new-leader"
        let newAgentID = "reused-new-agent"
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/reused-team", isDirectory: true)
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(teamName)", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: oldLeaderSessionID,
            agentID: oldAgentID,
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Old team task","status":"pending"}"#,
            to: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let oldResult = runHook(
            context: context,
            environment: environment,
            sessionId: oldLeaderSessionID,
            agentID: oldAgentID
        )
        #expect(!oldResult.timedOut, Comment(rawValue: oldResult.stderr))
        #expect(oldResult.status == 0, Comment(rawValue: oldResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        // The task-list directory is reused by a new team before an old
        // TeamDelete hook arrives.
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: newLeaderSessionID,
            agentID: newAgentID,
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"New team task","status":"in_progress"}"#,
            to: taskDirectory
        )
        let newResult = runHook(
            context: context,
            environment: environment,
            sessionId: newLeaderSessionID,
            agentID: newAgentID
        )
        #expect(!newResult.timedOut, Comment(rawValue: newResult.stderr))
        #expect(newResult.status == 0, Comment(rawValue: newResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let reconciliationCountBeforeDelete = reconcileRequests(in: context).count

        // A failed transition can leave only the destination proof. TeamDelete
        // must still inspect the live config before clearing that owner.
        try removeTeamBindingRecords(storeURL: context.storeURL)
        try rewriteTeamConfigGeneration(at: teamDirectory)

        let deleteResult = runHook(
            context: context,
            environment: environment,
            sessionId: oldLeaderSessionID,
            agentID: oldAgentID,
            toolName: "TeamDelete",
            standardInput: #"{"session_id":"reused-old-leader","agent_id":"reused-old-agent","hook_event_name":"PostToolUse","tool_name":"TeamDelete","tool_input":{"team_name":"Reused-Team"},"tool_response":{"success":true}}"#
        )
        #expect(!deleteResult.timedOut, Comment(rawValue: deleteResult.stderr))
        #expect(deleteResult.status == 0, Comment(rawValue: deleteResult.stderr))
        #expect(reconcileRequests(in: context).count == reconciliationCountBeforeDelete)

        let persistedBinding = try #require(
            try teamBindingRecords(in: context.storeURL).values.first
        )
        let binding = try #require(persistedBinding["binding"] as? [String: Any])
        #expect(binding["leaderSessionID"] as? String == newLeaderSessionID)
        #expect(binding["agentIDs"] as? [String] == [newAgentID])
    }

    @Test("A rejected automatic-team identity cannot scan into another task list")
    func rejectsCrossTeamCompatibilityScanAfterIdentityFailure() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-cross-team-scan"
        )
        defer { context.cleanup() }
        let workspaceId = "9a979797-9797-9797-9797-979797979797"
        let surfaceId = "9b989898-9898-9898-9898-989898989898"
        let oldTeamName = "Old-Scan-Team"
        let replacementTeamName = "Replacement-Scan-Team"
        let oldSessionID = "old-scan-leader"
        let replacementSessionID = "replacement-scan-leader"
        let teamRoot = context.root.appendingPathComponent(
            ".claude/teams",
            isDirectory: true
        )
        let tasksRoot = context.root.appendingPathComponent(
            ".claude/tasks",
            isDirectory: true
        )
        let oldTeamDirectory = teamRoot.appendingPathComponent(
            "old-scan-team",
            isDirectory: true
        )
        let replacementTeamDirectory = teamRoot.appendingPathComponent(
            "replacement-scan-team",
            isDirectory: true
        )
        let oldTaskDirectory = tasksRoot.appendingPathComponent(
            oldTeamName,
            isDirectory: true
        )
        let replacementTaskDirectory = tasksRoot.appendingPathComponent(
            replacementTeamName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: oldTeamDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: oldTaskDirectory,
            withIntermediateDirectories: true
        )
        try writeTeamConfig(
            name: oldTeamName,
            leaderSessionID: oldSessionID,
            agentID: "old-scan-agent",
            to: oldTeamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Cross-team identity","status":"pending"}"#,
            to: oldTaskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let initialResult = runHook(
            context: context,
            environment: environment,
            sessionId: oldSessionID,
            toolName: "TaskCreate"
        )
        #expect(!initialResult.timedOut, Comment(rawValue: initialResult.stderr))
        #expect(initialResult.status == 0, Comment(rawValue: initialResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        try FileManager.default.removeItem(at: oldTeamDirectory)
        try FileManager.default.removeItem(at: oldTaskDirectory)
        try FileManager.default.createDirectory(
            at: replacementTeamDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: replacementTaskDirectory,
            withIntermediateDirectories: true
        )
        try writeTeamConfig(
            name: replacementTeamName,
            leaderSessionID: replacementSessionID,
            agentID: "replacement-scan-agent",
            to: replacementTeamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Cross-team identity","status":"pending"}"#,
            to: replacementTaskDirectory
        )
        try removeTeamBindingRecords(storeURL: context.storeURL)

        let requestCountBeforeLateHook = reconcileRequests(in: context).count
        let lateResult = runHook(
            context: context,
            environment: environment,
            sessionId: oldSessionID,
            toolName: "TaskUpdate",
            standardInput: #"{"session_id":"old-scan-leader","hook_event_name":"PostToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"in_progress"},"tool_response":{"task":{"id":"1","subject":"Cross-team identity"}}}"#
        )
        #expect(!lateResult.timedOut, Comment(rawValue: lateResult.stderr))
        #expect(lateResult.status == 0, Comment(rawValue: lateResult.stderr))
        #expect(reconcileRequests(in: context).count == requestCountBeforeLateHook)
    }

}
