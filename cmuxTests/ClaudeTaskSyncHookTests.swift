import CMUXAgentLaunch
import Dispatch
import Foundation
import Testing

@Suite(.serialized)
struct ClaudeTaskSyncHookTests {
    @Test("An older SessionEnd cannot clear a replacement generation")
    func rejectsSessionEndFromOlderProcessGeneration() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-session-end-generation"
        )
        defer { context.cleanup() }
        let workspaceId = "01010101-0101-0101-0101-010101010101"
        let surfaceId = "02020202-0202-0202-0202-020202020202"
        let sessionId = "consumed-generation-session"
        _ = ClaudeHookLiveDeliveryHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: (workspaceId, surfaceId),
            surfaceTargets: [surfaceId: workspaceId]
        )

        var oldEnvironment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        oldEnvironment["CMUX_WORKSPACE_ID"] = workspaceId
        oldEnvironment["CMUX_SURFACE_ID"] = surfaceId
        oldEnvironment["CMUX_CLAUDE_PID"] = "41001"
        let oldStart = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            environment: oldEnvironment,
            standardInput: #"{"session_id":"consumed-generation-session","source":"clear","hook_event_name":"SessionStart"}"#
        )
        assertSuccessfulHook(oldStart)

        var replacementEnvironment = oldEnvironment
        replacementEnvironment["CMUX_CLAUDE_PID"] = "41002"
        let replacementStart = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            environment: replacementEnvironment,
            standardInput: #"{"session_id":"consumed-generation-session","source":"clear","hook_event_name":"SessionStart"}"#
        )
        assertSuccessfulHook(replacementStart)

        let commandCountBeforeOldEnd = context.state.snapshot().count
        let oldEnd = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: oldEnvironment,
            standardInput: #"{"session_id":"consumed-generation-session","hook_event_name":"SessionEnd"}"#
        )
        assertSuccessfulHook(oldEnd)
        let oldEndCommands = Array(context.state.snapshot().dropFirst(commandCountBeforeOldEnd))
        // The old hook carries the prior process identity. The bundled CLI
        // must reject it before consuming or mutating the replacement record.
        #expect(
            !oldEndCommands.contains { $0.hasPrefix("clear_agent_pid ") },
            "An older SessionEnd must not clear the replacement generation; saw \(oldEndCommands)"
        )
        #expect(
            !oldEndCommands.contains { $0.hasPrefix("clear_notifications ") },
            "An older SessionEnd must not clear replacement notifications; saw \(oldEndCommands)"
        )
        let record = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            )
        )
        #expect((record["pid"] as? NSNumber)?.intValue == 41002)
    }

    @Test("An unresolved SessionEnd leaves the current generation intact")
    func preservesCurrentGenerationForUnresolvedSessionEndBoundary() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-session-end-unresolved"
        )
        defer { context.cleanup() }
        let workspaceId = "0a0a0a0a-0a0a-0a0a-0a0a-0a0a0a0a0a0a"
        let surfaceId = "0b0b0b0b-0b0b-0b0b-0b0b-0b0b0b0b0b0b"
        let sessionId = "unresolved-generation-session"
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            markActive: true
        )
        _ = ClaudeHookLiveDeliveryHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [:],
            pidTarget: nil,
            surfaceTargets: [:]
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        let result = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"unresolved-generation-session","hook_event_name":"SessionEnd"}"#
        )
        assertSuccessfulHook(result)
        #expect(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            ) != nil
        )
        let state = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: context.storeURL)
            ) as? [String: Any]
        )
        #expect((state["endedSessionIDs"] as? [String: Any])?[sessionId] == nil)
        #expect((state["endedSessionGenerationStarts"] as? [String: Any])?[sessionId] == nil)
    }

    @Test("Task ownership survives an older writer rewriting the main hook store")
    func preservesTaskOwnershipAcrossLegacyStoreRewrite() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-sidecar-recovery"
        )
        defer { context.cleanup() }
        let workspaceId = "03030303-0303-0303-0303-030303030303"
        let surfaceId = "04040404-0404-0404-0404-040404040404"
        let sessionId = "sidecar-session"
        let taskListID = "sidecar-list"
        let tasksRoot = context.root.appendingPathComponent(
            ".claude/tasks",
            isDirectory: true
        )
        let taskDirectory = tasksRoot.appendingPathComponent(taskListID, isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Sidecar task","status":"pending"}"#,
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

        let firstResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        assertSuccessfulHook(firstResult)
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let sidecarURL = URL(fileURLWithPath: context.storeURL.path + ".task-sync.json")
        let sidecarBefore = try Data(contentsOf: sidecarURL)
        #expect(!sidecarBefore.isEmpty)

        let identity = ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
        var mainState = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: context.storeURL)
            ) as? [String: Any]
        )
        for key in [
            "endedSessionIDs",
            "endedSessionGenerationStarts",
            "retiredClaudeTaskLists",
            "claudeTaskSyncLatestTokens",
            "claudeTaskSyncGeneration",
            "pendingLegacyClaudeTaskOwnerCleanup",
            "pendingLegacyClaudeTaskOwnerCleanupOverflowEntries",
            "pendingLegacyClaudeTaskOwnerCleanupSpill",
            "claudeTeamTaskBindings",
            "claudeTaskListDestinations",
        ] {
            mainState.removeValue(forKey: key)
        }
        var sessions = try #require(mainState["sessions"] as? [String: [String: Any]])
        if var session = sessions[sessionId] {
            for key in [
                "claudeTaskDirectoryName",
                "claudeTaskStoreID",
                "claudeTaskLegacyOwnerCleared",
                "claudeTaskBindingStartedAt",
                "claudeTaskBindingSource",
            ] {
                session.removeValue(forKey: key)
            }
            sessions[sessionId] = session
        }
        mainState["sessions"] = sessions
        try JSONSerialization.data(
            withJSONObject: mainState,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: context.storeURL)

        let secondResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )
        assertSuccessfulHook(secondResult)
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let latestReconciliation = try #require(reconcileRequests(in: context).last)
        #expect(
            latestReconciliation["owner_id"] as? String == taskOwnerID(
                directoryName: taskListID,
                tasksRootURL: tasksRoot
            )
        )
        #expect(
            (latestReconciliation["items"] as? [[String: Any]])?.compactMap {
                $0["text"] as? String
            } == ["Sidecar task"]
        )
        let restoredRecord = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            )
        )
        #expect(restoredRecord["claudeTaskDirectoryName"] as? String == taskListID)
        #expect(restoredRecord["claudeTaskStoreID"] as? String == identity.rawValue)
        #expect(try taskListDestinationRecords(in: context.storeURL).count == 1)
    }

    @Test("Unrelated hook state writes do not rewrite the task-sync sidecar")
    func doesNotRewriteTaskSyncSidecarForUnrelatedMutation() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-sidecar-write-scope"
        )
        defer { context.cleanup() }
        let workspaceId = "05050505-0505-0505-0505-050505050505"
        let surfaceId = "06060606-0606-0606-0606-060606060606"
        let sessionId = "sidecar-write-scope-session"
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Sidecar scope task","status":"pending"}"#,
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
        let taskResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        assertSuccessfulHook(taskResult)
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let sidecarURL = URL(fileURLWithPath: context.storeURL.path + ".task-sync.json")
        let beforeData = try Data(contentsOf: sidecarURL)
        let beforeIdentity = try fileSystemNumber(at: sidecarURL)
        let unrelatedResult = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"sidecar-write-scope-session","hook_event_name":"PreToolUse","tool_name":"Bash","permission_mode":"default"}"#
        )
        assertSuccessfulHook(unrelatedResult)
        let afterData = try Data(contentsOf: sidecarURL)
        let afterIdentity = try fileSystemNumber(at: sidecarURL)
        #expect(afterData == beforeData)
        #expect(afterIdentity == beforeIdentity)
    }

    @Test("SessionStart clears the replaced personal task owner before rebinding")
    func clearsReplacedPersonalTaskOwnerBeforeNewGeneration() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-session-start-owner-cleanup"
        )
        defer { context.cleanup() }
        let previousWorkspaceId = "07070707-0707-0707-0707-070707070707"
        let currentWorkspaceId = "08080808-0808-0808-0808-080808080808"
        let previousSurfaceId = "09090909-0909-0909-0909-090909090909"
        let currentSurfaceId = "0a0a0a0a-0a0a-0a0a-0a0a-0a0a0a0a0a0a"
        let sessionId = "session-start-owner-cleanup"
        let tasksRoot = context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        // A personal list is named after the session. Creating it through the
        // real task hook gives the replacement SessionStart the same durable
        // owner proof as production, without importing CLI-only types.
        let oldTaskDirectory = tasksRoot.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: oldTaskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Old generation task","status":"pending"}"#,
            named: "1.json",
            in: oldTaskDirectory
        )

        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: currentWorkspaceId,
            surfaceId: currentSurfaceId,
            workspaceIDsBySurface: [
                previousSurfaceId: previousWorkspaceId,
                currentSurfaceId: currentWorkspaceId,
            ]
        )
        var previousEnvironment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        previousEnvironment["CMUX_WORKSPACE_ID"] = previousWorkspaceId
        previousEnvironment["CMUX_SURFACE_ID"] = previousSurfaceId
        let oldTaskResult = runHook(
            context: context,
            environment: previousEnvironment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        assertSuccessfulHook(oldTaskResult)
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = currentWorkspaceId
        environment["CMUX_SURFACE_ID"] = currentSurfaceId
        let startResult = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"session-start-owner-cleanup","source":"resume","hook_event_name":"SessionStart"}"#
        )
        assertSuccessfulHook(startResult)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let oldOwnerID = taskOwnerID(directoryName: sessionId, tasksRootURL: tasksRoot)
        let startCleanup = try #require(
            reconcileRequests(in: context).first {
                ($0["owner_id"] as? String) == oldOwnerID
                    && ($0["workspace_id"] as? String) == previousWorkspaceId
                    && ($0["items"] as? [[String: Any]])?.isEmpty == true
            }
        )
        #expect((startCleanup["items"] as? [[String: Any]])?.isEmpty == true)

        let newTaskDirectory = tasksRoot.appendingPathComponent(sessionId, isDirectory: true)
        try writeTask(
            #"{"id":"1","subject":"New generation task","status":"pending"}"#,
            named: "1.json",
            in: newTaskDirectory
        )
        let taskResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        #expect(!taskResult.timedOut, Comment(rawValue: taskResult.stderr))
        #expect(taskResult.status == 0, Comment(rawValue: taskResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let newOwnerID = taskOwnerID(directoryName: sessionId, tasksRootURL: tasksRoot)
        #expect(
            reconcileRequests(in: context).contains {
                ($0["owner_id"] as? String) == newOwnerID
                    && ($0["workspace_id"] as? String) == currentWorkspaceId
            }
        )
    }

}
