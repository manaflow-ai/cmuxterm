import CMUXAgentLaunch
import Foundation
import Testing

extension ClaudeAutomaticTeamTaskSyncHookTests {
    @Test("Leaderless team membership edits retain completed destinations")
    func retainsCompletedTeamWorkspaceHistory() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-complete-team")
        defer { context.cleanup() }
        let firstWorkspaceId = "89898989-8989-8989-8989-898989898989"
        let firstSurfaceId = "90909090-9090-9090-9090-909090909090"
        let secondWorkspaceId = "93939393-9393-9393-9393-939393939393"
        let secondSurfaceId = "94949494-9494-9494-9494-949494949494"
        let teamName = "Completed_Team"
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/completed-team", isDirectory: true)
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(teamName)", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: nil,
            agentID: "completed-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Finished","status":"completed"}"#,
            to: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: firstWorkspaceId,
            surfaceId: firstSurfaceId,
            workspaceIDsBySurface: [secondSurfaceId: secondWorkspaceId]
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = firstWorkspaceId
        environment["CMUX_SURFACE_ID"] = firstSurfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: "completed-session",
            agentID: "completed-agent"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let items = try #require(
            reconcileRequests(in: context).last?["items"] as? [[String: Any]]
        )
        #expect(items.isEmpty)
        let completedBinding = try #require(
            try teamBindingRecords(in: context.storeURL).values.first
        )
        #expect(completedBinding["workspaceIDs"] as? [String] == [firstWorkspaceId])

        try writeTask(
            #"{"id":"1","subject":"Reopened","status":"pending"}"#,
            to: taskDirectory
        )
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: nil,
            agentID: "completed-agent",
            additionalAgentIDs: ["new-member"],
            to: teamDirectory
        )
        environment["CMUX_WORKSPACE_ID"] = secondWorkspaceId
        environment["CMUX_SURFACE_ID"] = secondSurfaceId
        let reopenedResult = runHook(
            context: context,
            environment: environment,
            sessionId: "completed-session",
            agentID: "completed-agent"
        )

        #expect(!reopenedResult.timedOut, Comment(rawValue: reopenedResult.stderr))
        #expect(reopenedResult.status == 0, Comment(rawValue: reopenedResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let allReopenedReconciliations = reconcileRequests(in: context)
        #expect(
            allReopenedReconciliations.count == 3,
            "A team workspace already carrying the owner must not receive a redundant empty clear"
        )
        let reopenedDeliveries = allReopenedReconciliations.suffix(2)
        #expect(Set(reopenedDeliveries.compactMap { $0["workspace_id"] as? String }) == [
            firstWorkspaceId,
            secondWorkspaceId,
        ])
        #expect(reopenedDeliveries.allSatisfy { delivery in
            let items = delivery["items"] as? [[String: Any]]
            return items?.compactMap { $0["text"] as? String } == ["Reopened"]
        })
        let reopenedBinding = try #require(
            try teamBindingRecords(in: context.storeURL).values.first
        )
        #expect(reopenedBinding["workspaceIDs"] as? [String] == [
            firstWorkspaceId,
            secondWorkspaceId,
        ])
    }

    @Test("TeamDelete clears the configured owner after identity changes")
    func clearsTeamOwnerOnTeamDelete() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-team-delete")
        defer { context.cleanup() }
        let workspaceId = "95959595-9595-9595-9595-959595959595"
        let surfaceId = "96969696-9696-9696-9696-969696969696"
        let secondWorkspaceId = "95959595-9595-9595-9595-959595959596"
        let secondSurfaceId = "96969696-9696-9696-9696-969696969697"
        let teamName = "Deleted-Team"
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/deleted-team", isDirectory: true)
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(teamName)", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: "deleted-leader",
            agentID: "deleted-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Pending at deletion","status":"pending"}"#,
            to: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            workspaceIDsBySurface: [secondSurfaceId: secondWorkspaceId]
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let initialResult = runHook(
            context: context,
            environment: environment,
            sessionId: "deleted-session",
            agentID: "deleted-agent"
        )
        #expect(!initialResult.timedOut, Comment(rawValue: initialResult.stderr))
        #expect(initialResult.status == 0, Comment(rawValue: initialResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(try teamBindingRecords(in: context.storeURL).count == 1)

        environment["CMUX_WORKSPACE_ID"] = secondWorkspaceId
        environment["CMUX_SURFACE_ID"] = secondSurfaceId
        let secondWorkspaceResult = runHook(
            context: context,
            environment: environment,
            sessionId: "deleted-session",
            agentID: "deleted-agent"
        )
        #expect(!secondWorkspaceResult.timedOut, Comment(rawValue: secondWorkspaceResult.stderr))
        #expect(secondWorkspaceResult.status == 0, Comment(rawValue: secondWorkspaceResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        // Simulate a durable proof written before task-store namespaces existed.
        try rewriteTeamBindingAsLegacy(
            taskListID: teamName,
            storeURL: context.storeURL
        )

        let deleteResult = runHook(
            context: context,
            environment: environment,
            sessionId: "replacement-session",
            agentID: "replacement-agent",
            toolName: "TeamDelete",
            standardInput: #"{"session_id":"replacement-session","hook_event_name":"PostToolUse","agent_id":"replacement-agent","tool_name":"TeamDelete","tool_input":{"team_name":"Deleted-Team"},"tool_response":{"success":true}}"#
        )

        #expect(!deleteResult.timedOut, Comment(rawValue: deleteResult.stderr))
        #expect(deleteResult.status == 0, Comment(rawValue: deleteResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let deletedDeliveries = reconcileRequests(in: context).suffix(2)
        #expect(Set(deletedDeliveries.compactMap { $0["workspace_id"] as? String }) == [
            workspaceId,
            secondWorkspaceId,
        ])
        #expect(deletedDeliveries.allSatisfy {
            $0["owner_id"] as? String == "claude:\(teamName)"
                && ($0["items"] as? [[String: Any]])?.isEmpty == true
        })
        #expect(try teamBindingRecords(in: context.storeURL).isEmpty)
        let deletedSessionRecord = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: "deleted-session"
            )
        )
        #expect(deletedSessionRecord["claudeTaskDirectoryName"] == nil)
        #expect(deletedSessionRecord["claudeTaskStoreID"] == nil)
        #expect(FileManager.default.fileExists(
            atPath: taskDirectory.appendingPathComponent("1.json").path
        ))
    }

    @Test("Fallback TeamDelete retires the bound list when Feed cleanup fails")
    func fallbackTeamDeleteRetiresAfterFeedFailure() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-fallback-delete-feed-failure")
        defer { context.cleanup() }
        let workspaceId = "97979797-9797-9797-9797-979797979797"
        let surfaceId = "98989898-9898-9898-9898-989898989898"
        let sessionId = "fallback-delete-session"
        let agentID = "fallback-delete-agent"
        let teamName = "Fallback-Deleted-Team"
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/fallback-deleted-team", isDirectory: true)
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(teamName)", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: sessionId,
            agentID: agentID,
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Pending at fallback deletion","status":"pending"}"#,
            to: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            rejectsEmptyFeedSnapshots: true
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let initialResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            agentID: agentID
        )
        #expect(!initialResult.timedOut, Comment(rawValue: initialResult.stderr))
        #expect(initialResult.status == 0, Comment(rawValue: initialResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(try teamBindingRecords(in: context.storeURL).count == 1)

        let deleteResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            agentID: agentID,
            toolName: "TeamDelete",
            standardInput: #"{"session_id":"fallback-delete-session","hook_event_name":"PostToolUse","agent_id":"fallback-delete-agent","tool_name":"TeamDelete","tool_input":{},"tool_response":{"success":true}}"#
        )
        #expect(!deleteResult.timedOut, Comment(rawValue: deleteResult.stderr))
        #expect(deleteResult.status == 0, Comment(rawValue: deleteResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(try teamBindingRecords(in: context.storeURL).isEmpty)

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
            retiredAfterDelete?["\(taskStoreIdentity.rawValue):\(teamName)"] != nil,
            "Fallback TeamDelete must retain a retirement fence after Feed failure"
        )
    }

    @Test("A missing team config clears retained rows even when task files remain")
    func clearsRetainedOwnerAfterTeamConfigDisappears() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-orphaned-team")
        defer { context.cleanup() }
        let workspaceId = "91959595-9595-9595-9595-959595959595"
        let surfaceId = "92969696-9696-9696-9696-969696969696"
        let teamName = "Orphaned_Team"
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/orphaned-team", isDirectory: true)
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(teamName)", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: "orphaned-leader",
            agentID: "orphaned-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Orphaned task","status":"pending"}"#,
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

        let initialResult = runHook(
            context: context,
            environment: environment,
            sessionId: "orphaned-session",
            agentID: "orphaned-agent"
        )
        #expect(!initialResult.timedOut, Comment(rawValue: initialResult.stderr))
        #expect(initialResult.status == 0, Comment(rawValue: initialResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(try teamBindingRecords(in: context.storeURL).count == 1)

        try FileManager.default.removeItem(
            at: teamDirectory.appendingPathComponent("config.json")
        )
        let cleanupResult = runHook(
            context: context,
            environment: environment,
            sessionId: "orphaned-session",
            agentID: "orphaned-agent"
        )

        #expect(!cleanupResult.timedOut, Comment(rawValue: cleanupResult.stderr))
        #expect(cleanupResult.status == 0, Comment(rawValue: cleanupResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let cleanupItems = try #require(
            reconcileRequests(in: context).last?["items"] as? [[String: Any]]
        )
        #expect(cleanupItems.isEmpty)
        #expect(try teamBindingRecords(in: context.storeURL).isEmpty)
        let taskStoreIdentity = ClaudeTaskStoreIdentity(
            tasksRootURL: taskDirectory.deletingLastPathComponent()
        )
        let stateAfterCleanup = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: context.storeURL)
            ) as? [String: Any]
        )
        let retiredAfterCleanup = stateAfterCleanup["retiredClaudeTaskLists"] as? [String: Any]
        #expect(
            retiredAfterCleanup?["\(taskStoreIdentity.rawValue):\(teamName)"] != nil,
            "Orphan cleanup must retain a retirement fence for late compatibility scans"
        )
        #expect(FileManager.default.fileExists(
            atPath: taskDirectory.appendingPathComponent("1.json").path
        ))

        let reconciliationCountAfterCleanup = reconcileRequests(in: context).count
        let lateResult = runHook(
            context: context,
            environment: environment,
            sessionId: "late-personal-session",
            toolName: "TaskUpdate",
            standardInput: #"{"session_id":"late-personal-session","hook_event_name":"PostToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"in_progress"},"tool_response":{"task":{"id":"1","subject":"Orphaned task"}}}"#
        )
        #expect(!lateResult.timedOut, Comment(rawValue: lateResult.stderr))
        #expect(lateResult.status == 0, Comment(rawValue: lateResult.stderr))
        #expect(reconcileRequests(in: context).count == reconciliationCountAfterCleanup)
    }

}
