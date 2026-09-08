import CMUXAgentLaunch
import Dispatch
import Foundation
import Testing

extension ClaudeTaskSyncHookTests {
    @Test("Configured-list capacity clears the oldest owner before admission")
    func retiresOldestConfiguredTaskDestinationAtCapacity() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-list-capacity")
        defer { context.cleanup() }
        let workspaceId = "23232323-2323-2323-2323-232323232323"
        let surfaceId = "24242424-2424-2424-2424-242424242424"
        let sessionId = "configured-capacity-session"
        let taskListID = "NewestList"
        let tasksRoot = context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        let taskDirectory = tasksRoot.appendingPathComponent(taskListID, isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Newest configured task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            markActive: true
        )
        let taskStoreIdentity = ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
        try seedConfiguredTaskDestinations(
            count: 128,
            taskStoreIdentity: taskStoreIdentity,
            workspaceId: workspaceId,
            storeURL: context.storeURL
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

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskList"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let requests = reconcileRequests(in: context)
        #expect(requests.count == 2)
        let archivedRequest = try #require(
            requests.first {
                $0["owner_id"] as? String == taskOwnerID(
                    directoryName: "ArchivedList0",
                    tasksRootURL: tasksRoot
                )
            }
        )
        #expect((archivedRequest["items"] as? [[String: Any]])?.isEmpty == true)
        #expect(
            requests.contains {
                $0["owner_id"] as? String == taskOwnerID(
                    directoryName: taskListID,
                    tasksRootURL: tasksRoot
                )
            }
        )
        let records = try taskListDestinationRecords(in: context.storeURL)
        #expect(records.count == 128)
        #expect(!records.values.contains {
            $0["taskListID"] as? String == "ArchivedList0"
        })
        #expect(records.values.contains {
            $0["taskListID"] as? String == taskListID
        })
    }

    @Test("Automatic team cleanup does not consume the first personal task hook")
    func transitionsFromAutomaticTeamToPersonalTasksInOneHook() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-auto-team")
        defer { context.cleanup() }
        let workspaceId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let surfaceId = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let teammateWorkspaceId = "12121212-1212-1212-1212-121212121212"
        let teammateSurfaceId = "34343434-3434-3434-3434-343434343434"
        let leaderSessionId = "automatic-team-leader"
        let teammateSessionId = "automatic-team-teammate"
        let leaderAgentId = "agent-leader"
        let teammateAgentId = "agent-teammate"
        let teamName = "Session_Automatic_Team"
        let teamDirectoryName = "session-automatic-team"
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            workspaceIDsBySurface: [teammateSurfaceId: teammateWorkspaceId],
            rejectsEmptyFeedSnapshots: true
        )
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: leaderSessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            markActive: true
        )

        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(teamName)", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Claim shared task","activeForm":"Claiming shared task","status":"in_progress"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/\(teamDirectoryName)", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try Data(
            #"{"name":"\#(teamName)","leadAgentId":"\#(leaderAgentId)","leadSessionId":"\#(leaderSessionId)","members":[{"agentId":"\#(leaderAgentId)"},{"agentId":"\#(teammateAgentId)"}]}"#.utf8
        ).write(to: teamDirectory.appendingPathComponent("config.json"))

        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = teammateWorkspaceId
        environment["CMUX_SURFACE_ID"] = teammateSurfaceId
        environment["CMUX_AGENT_MANAGED_SUBAGENT"] = "1"
        let result = runHook(
            context: context,
            environment: environment,
            sessionId: teammateSessionId,
            toolName: "TaskUpdate",
            standardInput: #"{"session_id":"\#(teammateSessionId)","hook_event_name":"PostToolUse","agent_id":"\#(teammateAgentId)","tool_name":"TaskUpdate","tool_input":{"taskId":"1","owner":"teammate","status":"in_progress"},"tool_response":{"success":true,"taskId":"1","updatedFields":["owner","status"],"statusChange":{"from":"pending","to":"in_progress"}}}"#
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let reconciliation = try #require(reconcileRequests(in: context).last)
        #expect(reconciliation["workspace_id"] as? String == teammateWorkspaceId)
        let teamOwnerID = taskOwnerID(
            directoryName: teamName,
            tasksRootURL: taskDirectory.deletingLastPathComponent()
        )
        #expect(reconciliation["owner_id"] as? String == teamOwnerID)
        let items = try #require(reconciliation["items"] as? [[String: Any]])
        #expect(items.compactMap { $0["text"] as? String } == ["Claiming shared task"])

        var leaderEnvironment = environment
        leaderEnvironment["CMUX_WORKSPACE_ID"] = workspaceId
        leaderEnvironment["CMUX_SURFACE_ID"] = surfaceId
        leaderEnvironment.removeValue(forKey: "CMUX_AGENT_MANAGED_SUBAGENT")
        let personalTaskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(leaderSessionId)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: personalTaskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Stale personal task","status":"pending"}"#,
            named: "1.json",
            in: personalTaskDirectory
        )
        let leaderTeamResult = runHook(
            context: context,
            environment: leaderEnvironment,
            sessionId: leaderSessionId,
            toolName: "TaskList"
        )

        #expect(!leaderTeamResult.timedOut, Comment(rawValue: leaderTeamResult.stderr))
        #expect(leaderTeamResult.status == 0, Comment(rawValue: leaderTeamResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let sharedDestinations = Array(reconcileRequests(in: context).suffix(2))
        #expect(Set(sharedDestinations.compactMap { $0["workspace_id"] as? String }) == [
            workspaceId,
            teammateWorkspaceId,
        ])
        #expect(sharedDestinations.allSatisfy {
            $0["owner_id"] as? String == teamOwnerID
        })

        try FileManager.default.removeItem(at: teamDirectory)
        try FileManager.default.removeItem(at: taskDirectory)
        try setTeamBindingUpdatedAt(
            0,
            taskListID: teamName,
            storeURL: context.storeURL
        )
        try writeTask(
            #"{"id":"1","subject":"Personal follow-up","status":"pending"}"#,
            named: "1.json",
            in: personalTaskDirectory
        )
        let personalResult = runHook(
            context: context,
            environment: leaderEnvironment,
            sessionId: leaderSessionId,
            toolName: "TaskCreate",
            standardInput: #"{"session_id":"\#(leaderSessionId)","hook_event_name":"PostToolUse","tool_name":"TaskCreate","tool_input":{"subject":"Personal follow-up"},"tool_response":{"task":{"id":"1","subject":"Personal follow-up"}}}"#
        )

        #expect(!personalResult.timedOut, Comment(rawValue: personalResult.stderr))
        #expect(personalResult.status == 0, Comment(rawValue: personalResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let transitionReconciliations = Array(reconcileRequests(in: context).suffix(3))
        #expect(transitionReconciliations.count == 3)
        let cleanupReconciliations = transitionReconciliations.filter {
            $0["owner_id"] as? String == teamOwnerID
        }
        #expect(cleanupReconciliations.count == 2)
        #expect(Set(cleanupReconciliations.compactMap { $0["workspace_id"] as? String }) == [
            workspaceId,
            teammateWorkspaceId,
        ])
        #expect(cleanupReconciliations.allSatisfy { reconciliation in
            reconciliation["owner_id"] as? String == teamOwnerID
                && (reconciliation["items"] as? [[String: Any]])?.isEmpty == true
        })

        let personalReconciliation = try #require(
            transitionReconciliations.first {
                $0["owner_id"] as? String != teamOwnerID
            }
        )
        #expect(personalReconciliation["workspace_id"] as? String == workspaceId)
        #expect(personalReconciliation["owner_id"] as? String == taskOwnerID(
            directoryName: leaderSessionId,
            tasksRootURL: personalTaskDirectory.deletingLastPathComponent()
        ))
        let personalItems = try #require(personalReconciliation["items"] as? [[String: Any]])
        #expect(personalItems.compactMap { $0["text"] as? String } == ["Personal follow-up"])
    }

    @Test("An all-completed snapshot preserves Feed history and clears workspace-owned todos")
    func clearsWorkspaceOwnerForAllCompletedSnapshot() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-completed")
        defer { context.cleanup() }
        let workspaceId = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        let surfaceId = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        let sessionId = "completed-list-session"
        let taskListID = "completed-list"
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(taskListID)", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Finished task","status":"completed"}"#,
            named: "1.json",
            in: taskDirectory
        )

        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CLAUDE_CODE_TASK_LIST_ID"] = taskListID
        let result = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let feedTodos = context.state.snapshot().compactMap(feedEvent)
            .compactMap { $0["tool_input"] as? [String: Any] }
            .compactMap { $0["todos"] as? [[String: Any]] }
            .last
        #expect(feedTodos?.compactMap { $0["status"] as? String } == ["completed"])
        let checklistItems = try #require(
            reconcileRequests(in: context).last?["items"] as? [[String: Any]]
        )
        #expect(checklistItems.isEmpty)
    }

    @Test("An all-completed personal list retires its durable destination proof")
    func retiresCompletedPersonalTaskDestinations() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-completed-personal"
        )
        defer { context.cleanup() }
        let workspaceId = "dededede-dede-dede-dede-dededededede"
        let surfaceId = "efefefef-efef-efef-efef-efefefefefef"
        let sessionId = "completed-personal-session"
        let taskDirectory = context.root.appendingPathComponent(
            ".claude/tasks/\(sessionId)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Personal task","status":"pending"}"#,
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

        let pendingResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        #expect(!pendingResult.timedOut, Comment(rawValue: pendingResult.stderr))
        #expect(pendingResult.status == 0, Comment(rawValue: pendingResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(try taskListDestinationRecords(in: context.storeURL).count == 1)

        try writeTask(
            #"{"id":"1","subject":"Personal task","status":"completed"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let completedResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )

        #expect(!completedResult.timedOut, Comment(rawValue: completedResult.stderr))
        #expect(completedResult.status == 0, Comment(rawValue: completedResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(try taskListDestinationRecords(in: context.storeURL).isEmpty)
    }

}
