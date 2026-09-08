import CMUXAgentLaunch
import Dispatch
import Foundation
import Testing

extension ClaudeTaskSyncHookTests {
    @Test("A rejected authoritative Feed snapshot prevents checklist commit")
    func rejectsChecklistWhenFeedSnapshotIsRejected() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-feed-rejection"
        )
        defer { context.cleanup() }
        let workspaceId = "38383838-3838-3838-3838-383838383838"
        let surfaceId = "39393939-3939-3939-3939-393939393939"
        let sessionId = "feed-rejection-session"
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Authoritative task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            feedPushSucceeds: false
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(reconcileRequests(in: context).isEmpty)
        #expect(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            ) == nil
        )
    }

    @Test("A first-sighting configured list rolls back durable state when Feed rejects")
    func rollsBackConfiguredStateAfterFeedRejection() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-configured-feed-rejection"
        )
        defer { context.cleanup() }
        let workspaceId = "3c3c3c3c-3c3c-3c3c-3c3c-3c3c3c3c3c3c"
        let surfaceId = "3d3d3d3d-3d3d-3d3d-3d3d-3d3d3d3d3d3d"
        let sessionId = "configured-feed-rejection-session"
        let taskListID = "configured-feed-rejection-list"
        let tasksRoot = context.root.appendingPathComponent(
            ".claude/tasks",
            isDirectory: true
        )
        let taskDirectory = tasksRoot.appendingPathComponent(taskListID, isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Rejected configured task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            feedPushSucceeds: false
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CLAUDE_CODE_TASK_LIST_ID"] = taskListID

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            ) == nil,
            "A rejected first-sighting Feed snapshot must not leave a session binding"
        )
        #expect(
            try taskListDestinationRecords(in: context.storeURL).isEmpty,
            "A rejected first-sighting Feed snapshot must not leave a destination proof"
        )
    }

    @Test("Namespaced delivery removes a legacy owner exactly once")
    func migratesLegacyChecklistOwnerBeforeDelivery() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-owner-migration")
        defer { context.cleanup() }
        let workspaceId = "13131313-1313-1313-1313-131313131313"
        let surfaceId = "14141414-1414-1414-1414-141414141414"
        let teammateWorkspaceId = "15151515-1515-1515-1515-151515151515"
        let teammateSurfaceId = "16161616-1616-1616-1616-161616161616"
        let sessionId = "legacy-owner-session"
        let teammateSessionId = "legacy-owner-teammate"
        let tasksRoot = context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        let taskDirectory = tasksRoot.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Migrated task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            claudeTaskDirectoryName: sessionId,
            markActive: true
        )
        try addLegacyTaskSessionRecord(
            to: context.storeURL,
            sourceSessionId: sessionId,
            sessionId: teammateSessionId,
            workspaceId: teammateWorkspaceId,
            surfaceId: teammateSurfaceId
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let firstResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskList"
        )

        #expect(!firstResult.timedOut, Comment(rawValue: firstResult.stderr))
        #expect(firstResult.status == 0, Comment(rawValue: firstResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let firstRequests = reconcileRequests(in: context)
        #expect(firstRequests.count == 3)
        let legacyRequests = firstRequests.prefix(2)
        #expect(Set(legacyRequests.compactMap { $0["workspace_id"] as? String }) == [
            workspaceId,
            teammateWorkspaceId,
        ])
        #expect(legacyRequests.allSatisfy {
            $0["owner_id"] as? String == "claude:\(sessionId)"
                && ($0["items"] as? [[String: Any]])?.isEmpty == true
        })
        let namespacedOwnerID = taskOwnerID(
            directoryName: sessionId,
            tasksRootURL: tasksRoot
        )
        #expect(firstRequests[2]["owner_id"] as? String == namespacedOwnerID)
        #expect((firstRequests[2]["items"] as? [[String: Any]])?.count == 1)
        let migratedRecord = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            )
        )
        #expect(
            migratedRecord["claudeTaskStoreID"] as? String
                == ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot).rawValue
        )
        let teammateRecord = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: teammateSessionId
            )
        )
        #expect(teammateRecord["claudeTaskStoreID"] == nil)
        #expect(teammateRecord["claudeTaskLegacyOwnerCleared"] as? Bool == true)

        let secondResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskList"
        )

        #expect(!secondResult.timedOut, Comment(rawValue: secondResult.stderr))
        #expect(secondResult.status == 0, Comment(rawValue: secondResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let allRequests = reconcileRequests(in: context)
        #expect(allRequests.count == 4)
        #expect(allRequests.last?["owner_id"] as? String == namespacedOwnerID)
    }

    @Test("TeamDelete clears session-only legacy owners from every workspace")
    func teamDeleteClearsLegacySessionDestinations() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-legacy-delete")
        defer { context.cleanup() }
        let workspaceId = "19191919-1919-1919-1919-191919191919"
        let surfaceId = "20202020-2020-2020-2020-202020202020"
        let teammateWorkspaceId = "21212121-2121-2121-2121-212121212121"
        let teammateSurfaceId = "22212121-2121-2121-2121-212121212121"
        let legacySessionId = "legacy-delete-leader"
        let teammateSessionId = "legacy-delete-teammate"
        let teamName = "Legacy-Deleted-Team"
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: legacySessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            claudeTaskDirectoryName: teamName,
            markActive: true
        )
        try addLegacyTaskSessionRecord(
            to: context.storeURL,
            sourceSessionId: legacySessionId,
            sessionId: teammateSessionId,
            workspaceId: teammateWorkspaceId,
            surfaceId: teammateSurfaceId
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
            sessionId: "replacement-delete-session",
            toolName: "TeamDelete",
            standardInput: #"{"session_id":"replacement-delete-session","hook_event_name":"PostToolUse","tool_name":"TeamDelete","tool_input":{"team_name":"Legacy-Deleted-Team"},"tool_response":{"success":true}}"#
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let requests = reconcileRequests(in: context)
        #expect(requests.count == 3)
        let legacyRequests = requests.prefix(2)
        #expect(Set(legacyRequests.compactMap { $0["workspace_id"] as? String }) == [
            workspaceId,
            teammateWorkspaceId,
        ])
        #expect(legacyRequests.allSatisfy {
            $0["owner_id"] as? String == "claude:\(teamName)"
                && ($0["items"] as? [[String: Any]])?.isEmpty == true
        })
        #expect(requests.last?["owner_id"] as? String == taskOwnerID(
            directoryName: teamName,
            tasksRootURL: context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        ))
        let legacyTaskStoreIdentity = ClaudeTaskStoreIdentity(
            tasksRootURL: context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        )
        let stateAfterDelete = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: context.storeURL)
            ) as? [String: Any]
        )
        let retiredAfterDelete = stateAfterDelete["retiredClaudeTaskLists"] as? [String: Any]
        #expect(
            retiredAfterDelete?["\(legacyTaskStoreIdentity.rawValue):\(teamName)"] != nil,
            "Legacy TeamDelete cleanup must still fence the current task-store identity"
        )
        for sessionId in [legacySessionId, teammateSessionId] {
            let record = try #require(
                try ClaudeHookLiveDeliveryHarness.sessionRecord(
                    in: context.storeURL,
                    sessionId: sessionId
                )
            )
            #expect(record["claudeTaskLegacyOwnerCleared"] as? Bool == true)
        }
    }

    @Test("Structured TeamDelete clears a legacy owner after session proof expires")
    func teamDeleteClearsLegacyOwnerWithoutSessionRecord() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-expired-delete")
        defer { context.cleanup() }
        let workspaceId = "25252525-2525-2525-2525-252525252525"
        let surfaceId = "26262626-2626-2626-2626-262626262626"
        let teamName = "Expired-Legacy-Team"
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
            sessionId: "expired-delete-session",
            toolName: "TeamDelete",
            standardInput: #"{"session_id":"expired-delete-session","hook_event_name":"PostToolUse","tool_name":"TeamDelete","tool_input":{"team_name":"Expired-Legacy-Team"},"tool_response":{"success":true}}"#
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let requests = reconcileRequests(in: context)
        #expect(requests.count == 2)
        #expect(requests[0]["owner_id"] as? String == "claude:\(teamName)")
        #expect((requests[0]["items"] as? [[String: Any]])?.isEmpty == true)
        #expect(requests[1]["owner_id"] as? String == taskOwnerID(
            directoryName: teamName,
            tasksRootURL: context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        ))
    }

    @Test("Snapshots over the checklist cap do not publish Feed before rejection")
    func doesNotPublishOverCapSnapshotToFeed() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-cap")
        defer { context.cleanup() }
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let surfaceId = "44444444-4444-4444-4444-444444444444"
        let sessionId = "task-sync-cap-session"
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        for id in 1...51 {
            try writeTask(
                #"{"id":"\#(id)","subject":"Task \#(id)","status":"pending"}"#,
                named: "\(id).json",
                in: taskDirectory
            )
        }
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskList"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        // The workspace reconciliation rejects the 51-item projection. Feed
        // must not advance first, or the two task views would diverge.
        #expect(deliveries.feed.wait(timeout: .now() + 0.25) == .timedOut)
        #expect(deliveries.validation.wait(timeout: .now() + 5) == .success)
        #expect(context.state.snapshot().compactMap(feedEvent).isEmpty)
        let request = try #require(
            ClaudeHookLiveDeliveryHarness.taskSyncReconcileValidationRequests(in: context).last
        )
        let items = try #require(request["items"] as? [[String: Any]])
        #expect(items.count == 51)
    }

}
