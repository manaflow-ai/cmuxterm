import CMUXAgentLaunch
import Dispatch
import Foundation
import Testing

extension ClaudeTaskSyncHookTests {
    @Test("Task-tool hooks publish one authoritative snapshot to Feed and workspace todos")
    func publishesAuthoritativeSnapshot() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync")
        defer { context.cleanup() }
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "task-sync-session"
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )

        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"First task","activeForm":"Running first task","status":"in_progress"}"#,
            named: "1.json",
            in: taskDirectory
        )
        try writeTask(
            #"{"id":"2","subject":"Second task","activeForm":"Running second task","status":"pending"}"#,
            named: "2.json",
            in: taskDirectory
        )

        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        let firstResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        #expect(!firstResult.timedOut, Comment(rawValue: firstResult.stderr))
        #expect(firstResult.status == 0, Comment(rawValue: firstResult.stderr))
        #expect(firstResult.stdout == "{}\n")
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let firstReconcile = try #require(reconcileRequests(in: context).last)
        #expect(firstReconcile["owner_id"] as? String == taskOwnerID(
            directoryName: sessionId,
            tasksRootURL: taskDirectory.deletingLastPathComponent()
        ))
        let firstItems = try #require(firstReconcile["items"] as? [[String: Any]])
        #expect(firstItems.count == 2)
        #expect(firstItems.compactMap { $0["text"] as? String } == ["Running first task", "Second task"])
        #expect(firstItems.compactMap { $0["state"] as? String } == ["in-progress", "pending"])
        #expect(firstItems.allSatisfy { $0["origin"] as? String == "agent" })
        let firstTaskId = try #require(firstItems.first?["id"] as? String)
        #expect(UUID(uuidString: firstTaskId) != nil)

        try writeTask(
            #"{"id":"1","subject":"First task","activeForm":"Running first task","status":"completed"}"#,
            named: "1.json",
            in: taskDirectory
        )
        try writeTask(
            #"{"id":"2","subject":"Second task","activeForm":"Running second task","status":"deleted"}"#,
            named: "2.json",
            in: taskDirectory
        )
        try writeTask(
            #"{"id":"3","subject":"Third task","activeForm":"Running third task","status":"pending"}"#,
            named: "3.json",
            in: taskDirectory
        )
        let secondResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )
        #expect(!secondResult.timedOut, Comment(rawValue: secondResult.stderr))
        #expect(secondResult.status == 0, Comment(rawValue: secondResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let secondReconcile = try #require(reconcileRequests(in: context).last)
        let secondItems = try #require(secondReconcile["items"] as? [[String: Any]])
        #expect(secondItems.compactMap { $0["text"] as? String } == ["First task", "Third task"])
        #expect(secondItems.compactMap { $0["state"] as? String } == ["completed", "pending"])
        #expect(secondItems.first?["id"] as? String == firstTaskId)

        let feedEvents = context.state.snapshot().compactMap(feedEvent)
        #expect(feedEvents.count == 2)
        #expect(feedEvents.allSatisfy { $0["hook_event_name"] as? String == "TodoWrite" })
        let latestInput = try #require(feedEvents.last?["tool_input"] as? [String: Any])
        let latestTodos = try #require(latestInput["todos"] as? [[String: Any]])
        #expect(latestTodos.compactMap { $0["id"] as? String } == ["1", "3"])

        // The task-store scope namespaces durable claims, while the
        // cross-process lease uses one of a bounded set of deterministic files.
        let taskSyncLockPrefix = context.storeURL.lastPathComponent + ".task-sync.lock."
        let taskSyncLockFiles = try FileManager.default.contentsOfDirectory(
            at: context.storeURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(taskSyncLockPrefix) }
        // First-sighting hooks briefly hold the identity-qualified scan slot,
        // then retarget to the resolved task-list slot. Those scopes may hash
        // to one or two bounded lock files; they must never create one file
        // per task list or per hook invocation.
        #expect((1...2).contains(taskSyncLockFiles.count))
    }

    @Test("A personal task list clears its prior workspace after its pane moves")
    func movesPersonalTaskOwnerToTheCurrentWorkspace() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-personal-move")
        defer { context.cleanup() }
        let previousWorkspaceId = "31313131-3131-3131-3131-313131313131"
        let currentWorkspaceId = "32323232-3232-3232-3232-323232323232"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "moved-personal-session"
        let tasksRoot = context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        let taskDirectory = tasksRoot.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Moved task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let taskStoreIdentity = ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: previousWorkspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            claudeTaskDirectoryName: sessionId,
            claudeTaskStoreID: taskStoreIdentity.rawValue,
            markActive: true
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: currentWorkspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = currentWorkspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        let reconciliations = reconcileRequests(in: context)
        #expect(reconciliations.count == 2)
        let previousReconciliation = try #require(
            reconciliations.first { ($0["items"] as? [[String: Any]])?.isEmpty == true }
        )
        let currentReconciliation = try #require(
            reconciliations.first { ($0["items"] as? [[String: Any]])?.isEmpty != true }
        )
        let ownerID = taskOwnerID(directoryName: sessionId, tasksRootURL: tasksRoot)
        #expect(previousReconciliation["workspace_id"] as? String == previousWorkspaceId)
        #expect(previousReconciliation["owner_id"] as? String == ownerID)
        #expect((previousReconciliation["items"] as? [[String: Any]])?.isEmpty == true)
        #expect(currentReconciliation["workspace_id"] as? String == currentWorkspaceId)
        #expect(currentReconciliation["owner_id"] as? String == ownerID)
        #expect(
            (currentReconciliation["items"] as? [[String: Any]])?.compactMap {
                $0["text"] as? String
            } == ["Moved task"]
        )
        let persistedRecord = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            )
        )
        #expect(persistedRecord["workspaceId"] as? String == currentWorkspaceId)
        #expect(persistedRecord["surfaceId"] as? String == surfaceId)
    }

    @Test("A late task hook cannot resurrect a session consumed by SessionEnd")
    func rejectsTaskSyncAfterSessionEnd() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-after-session-end"
        )
        defer { context.cleanup() }
        let workspaceId = "38383838-3838-3838-3838-383838383838"
        let surfaceId = "39393939-3939-3939-3939-393939393939"
        let sessionId = "ended-task-session"
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Should not resurrect","status":"pending"}"#,
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
        let reconciliationCountBeforeEnd = reconcileRequests(in: context).count

        let endResult = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"ended-task-session","hook_event_name":"SessionEnd","cwd":"/tmp"}"#
        )
        #expect(!endResult.timedOut, Comment(rawValue: endResult.stderr))
        #expect(endResult.status == 0, Comment(rawValue: endResult.stderr))
        #expect(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            ) == nil
        )

        let lateResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )
        #expect(!lateResult.timedOut, Comment(rawValue: lateResult.stderr))
        #expect(lateResult.status == 0, Comment(rawValue: lateResult.stderr))
        #expect(reconcileRequests(in: context).count == reconciliationCountBeforeEnd)
        #expect(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            ) == nil
        )
    }

    @Test("An unrecorded SessionEnd tombstones a first-sighting task hook")
    func tombstonesUnrecordedSessionBeforeTaskSync() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-unrecorded-session-end"
        )
        defer { context.cleanup() }
        let workspaceId = "3a3a3a3a-3a3a-3a3a-3a3a-3a3a3a3a3a3a"
        let surfaceId = "3b3b3b3b-3b3b-3b3b-3b3b-3b3b3b3b3b3b"
        let sessionId = "unrecorded-session-end"
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Must not resurrect","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        _ = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let endResult = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"unrecorded-session-end","hook_event_name":"SessionEnd"}"#
        )
        #expect(!endResult.timedOut, Comment(rawValue: endResult.stderr))
        #expect(endResult.status == 0, Comment(rawValue: endResult.stderr))

        let lateResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        #expect(!lateResult.timedOut, Comment(rawValue: lateResult.stderr))
        #expect(lateResult.status == 0, Comment(rawValue: lateResult.stderr))
        #expect(reconcileRequests(in: context).isEmpty)
        let state = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: context.storeURL)
            ) as? [String: Any]
        )
        #expect(
            (state["endedSessionIDs"] as? [String: Any])?[sessionId] != nil
        )
    }

    @Test("A personal task list clears its prior workspace after session teardown and resume")
    func movesPersonalTaskOwnerAfterSessionTeardown() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-personal-resume-move"
        )
        defer { context.cleanup() }
        let previousWorkspaceId = "34343434-3434-3434-3434-343434343434"
        let currentWorkspaceId = "35353535-3535-3535-3535-353535353535"
        let previousSurfaceId = "36363636-3636-3636-3636-363636363636"
        let currentSurfaceId = "37373737-3737-3737-3737-373737373737"
        let sessionId = "resumed-personal-session"
        let tasksRoot = context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        let taskDirectory = tasksRoot.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Resume task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: previousWorkspaceId,
            surfaceId: previousSurfaceId,
            workspaceIDsBySurface: [
                previousSurfaceId: previousWorkspaceId,
                currentSurfaceId: currentWorkspaceId,
            ]
        )
        var previousEnvironment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        previousEnvironment["CMUX_WORKSPACE_ID"] = previousWorkspaceId
        previousEnvironment["CMUX_SURFACE_ID"] = previousSurfaceId

        let firstResult = runHook(
            context: context,
            environment: previousEnvironment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        #expect(!firstResult.timedOut, Comment(rawValue: firstResult.stderr))
        #expect(firstResult.status == 0, Comment(rawValue: firstResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let teardownResult = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: previousEnvironment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"SessionEnd","cwd":"\#(context.root.path)"}"#
        )
        #expect(!teardownResult.timedOut, Comment(rawValue: teardownResult.stderr))
        #expect(teardownResult.status == 0, Comment(rawValue: teardownResult.stderr))
        #expect(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            ) == nil
        )

        var currentEnvironment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        currentEnvironment["CMUX_WORKSPACE_ID"] = currentWorkspaceId
        currentEnvironment["CMUX_SURFACE_ID"] = currentSurfaceId

        // SessionEnd leaves a tombstone so a late task hook cannot resurrect
        // the consumed generation. A real resume starts a new generation
        // first; only that lifecycle boundary may re-admit the task hook.
        let resumeStartResult = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            environment: currentEnvironment,
            standardInput: #"{"session_id":"resumed-personal-session","hook_event_name":"SessionStart","source":"resume","cwd":"\#(context.root.path)"}"#
        )
        #expect(!resumeStartResult.timedOut, Comment(rawValue: resumeStartResult.stderr))
        #expect(resumeStartResult.status == 0, Comment(rawValue: resumeStartResult.stderr))

        try writeTask(
            #"{"id":"1","subject":"Resumed task","status":"in_progress"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let resumedResult = runHook(
            context: context,
            environment: currentEnvironment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )
        #expect(!resumedResult.timedOut, Comment(rawValue: resumedResult.stderr))
        #expect(resumedResult.status == 0, Comment(rawValue: resumedResult.stderr))

        let reconciliations = reconcileRequests(in: context)
        #expect(reconciliations.count == 3)
        let previousDelivery = try #require(reconciliations.first)
        let previousCleanup = try #require(
            reconciliations.dropFirst().first {
                ($0["items"] as? [[String: Any]])?.isEmpty == true
            }
        )
        let currentDelivery = try #require(
            reconciliations.dropFirst().first {
                ($0["items"] as? [[String: Any]])?.isEmpty != true
            }
        )
        let ownerID = taskOwnerID(directoryName: sessionId, tasksRootURL: tasksRoot)
        #expect(previousDelivery["workspace_id"] as? String == previousWorkspaceId)
        #expect(previousCleanup["workspace_id"] as? String == previousWorkspaceId)
        #expect(previousCleanup["owner_id"] as? String == ownerID)
        #expect((previousCleanup["items"] as? [[String: Any]])?.isEmpty == true)
        #expect(currentDelivery["workspace_id"] as? String == currentWorkspaceId)
        #expect(currentDelivery["owner_id"] as? String == ownerID)
        #expect(
            (currentDelivery["items"] as? [[String: Any]])?.compactMap {
                $0["text"] as? String
            } == ["Resumed task"]
        )
    }

}
