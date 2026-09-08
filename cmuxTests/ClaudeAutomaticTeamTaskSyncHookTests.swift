import CMUXAgentLaunch
import Foundation
import Testing

@Suite("Claude automatic-team task sync", .serialized)
struct ClaudeAutomaticTeamTaskSyncHookTests {
    @Test("A first-sighting automatic-team hook publishes its initial snapshot")
    func publishesFirstSightingAutomaticTeamSnapshot() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-first-sighting-team"
        )
        defer { context.cleanup() }
        let workspaceId = "05010101-0101-0101-0101-010101010101"
        let surfaceId = "05020202-0202-0202-0202-020202020202"
        let sessionId = "first-sighting-team-leader"
        let agentId = "first-sighting-team-agent"
        let teamName = "First_Sighting_Team"
        let teamDirectory = context.root.appendingPathComponent(
            ".claude/teams/first-sighting-team",
            isDirectory: true
        )
        let taskDirectory = context.root.appendingPathComponent(
            ".claude/tasks/\(teamName)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: sessionId,
            agentID: agentId,
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"First team task","status":"pending"}"#,
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
            sessionId: sessionId,
            agentID: agentId
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let delivery = try #require(reconcileRequests(in: context).last)
        #expect(delivery["owner_id"] as? String == taskOwnerID(
            directoryName: teamName,
            tasksRootURL: taskDirectory.deletingLastPathComponent()
        ))
        #expect((delivery["items"] as? [[String: Any]])?.compactMap {
            $0["text"] as? String
        } == ["First team task"])
    }

    @Test("Same-named teams in independent Claude profiles keep distinct owners")
    func isolatesTaskStoresWithTheSameTeamName() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-profiles")
        defer { context.cleanup() }
        let firstWorkspaceId = "01010101-0101-0101-0101-010101010101"
        let firstSurfaceId = "02020202-0202-0202-0202-020202020202"
        let secondWorkspaceId = "03030303-0303-0303-0303-030303030303"
        let secondSurfaceId = "04040404-0404-0404-0404-040404040404"
        let teamName = "Shared_Profile_Team"
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: firstWorkspaceId,
            surfaceId: firstSurfaceId,
            workspaceIDsBySurface: [secondSurfaceId: secondWorkspaceId]
        )

        var expectedOwnerIDs: [String] = []
        var expectedItemIDs: [String] = []
        for profile in [
            ("profile-a", "leader-a", "agent-a", firstWorkspaceId, firstSurfaceId),
            ("profile-b", "leader-b", "agent-b", secondWorkspaceId, secondSurfaceId),
        ] {
            let configRoot = context.root.appendingPathComponent(
                profile.0,
                isDirectory: true
            )
            let teamDirectory = configRoot.appendingPathComponent(
                "teams/shared-profile-team",
                isDirectory: true
            )
            let tasksRoot = configRoot.appendingPathComponent("tasks", isDirectory: true)
            let taskDirectory = tasksRoot.appendingPathComponent(
                teamName,
                isDirectory: true
            )
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
                leaderSessionID: profile.1,
                agentID: profile.2,
                to: teamDirectory
            )
            try writeTask(
                #"{"id":"1","subject":"Task for \#(profile.0)","status":"pending"}"#,
                to: taskDirectory
            )
            var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(
                context: context
            )
            environment["CLAUDE_CONFIG_DIR"] = configRoot.path
            environment["CMUX_WORKSPACE_ID"] = profile.3
            environment["CMUX_SURFACE_ID"] = profile.4

            let result = runHook(
                context: context,
                environment: environment,
                sessionId: "session-\(profile.0)",
                agentID: profile.2
            )

            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
            #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
            let delivery = try #require(reconcileRequests(in: context).last)
            expectedOwnerIDs.append(taskOwnerID(
                directoryName: teamName,
                tasksRootURL: tasksRoot
            ))
            #expect(delivery["owner_id"] as? String == expectedOwnerIDs.last)
            let items = try #require(delivery["items"] as? [[String: Any]])
            expectedItemIDs.append(try #require(items.first?["id"] as? String))
        }

        let reconciliations = reconcileRequests(in: context)
        #expect(reconciliations.count == 2)
        #expect(Set(expectedOwnerIDs).count == 2)
        #expect(Set(expectedItemIDs).count == 2)
        #expect(try teamBindingRecords(in: context.storeURL).count == 2)
    }

    @Test("Authoritative team membership wins over a stale personal task collision")
    func rejectsStalePersonalTaskCollisionForTeamLeader() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-team-collision")
        defer { context.cleanup() }
        let workspaceId = "05050505-0505-0505-0505-050505050505"
        let surfaceId = "06060606-0606-0606-0606-060606060606"
        let sessionId = "team-leader-session"
        let personalTaskDirectory = context.root.appendingPathComponent(
            ".claude/tasks/\(sessionId)",
            isDirectory: true
        )
        let teamName = "Authoritative_Team"
        let teamTaskDirectory = context.root.appendingPathComponent(
            ".claude/tasks/\(teamName)",
            isDirectory: true
        )
        let teamDirectory = context.root.appendingPathComponent(
            ".claude/teams/authoritative-team",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: personalTaskDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: teamTaskDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: teamDirectory,
            withIntermediateDirectories: true
        )
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: sessionId,
            agentID: "team-leader-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Colliding task","activeForm":"Stale personal copy","status":"in_progress"}"#,
            to: personalTaskDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Colliding task","activeForm":"Authoritative team copy","status":"in_progress"}"#,
            to: teamTaskDirectory
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
            sessionId: sessionId,
            toolName: "TaskCreate",
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PostToolUse","tool_name":"TaskCreate","tool_input":{"subject":"Colliding task"},"tool_response":{"task":{"id":"1","subject":"Colliding task"}}}"#
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let items = try #require(
            reconcileRequests(in: context).last?["items"] as? [[String: Any]]
        )
        #expect(items.compactMap { $0["text"] as? String } == ["Authoritative team copy"])
    }

    @Test("A reused team name clears the former owner without inheriting its workspaces")
    func clearsFormerTeamBeforeReusingTaskListID() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-reused-team")
        defer { context.cleanup() }
        let formerWorkspaceId = "45454545-4545-4545-4545-454545454545"
        let formerSurfaceId = "56565656-5656-5656-5656-565656565656"
        let currentWorkspaceId = "67676767-6767-6767-6767-676767676767"
        let currentSurfaceId = "78787878-7878-7878-7878-787878787878"
        let teamName = "Reused_Team"
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/reused-team", isDirectory: true)
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(teamName)", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: formerWorkspaceId,
            surfaceId: formerSurfaceId,
            workspaceIDsBySurface: [currentSurfaceId: currentWorkspaceId]
        )

        try writeTeamConfig(
            name: teamName,
            leaderSessionID: "former-leader",
            agentID: "former-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Former team task","status":"pending"}"#,
            to: taskDirectory
        )
        var formerEnvironment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        formerEnvironment["CMUX_WORKSPACE_ID"] = formerWorkspaceId
        formerEnvironment["CMUX_SURFACE_ID"] = formerSurfaceId
        let formerResult = runHook(
            context: context,
            environment: formerEnvironment,
            sessionId: "former-session",
            agentID: "former-agent"
        )

        #expect(!formerResult.timedOut, Comment(rawValue: formerResult.stderr))
        #expect(formerResult.status == 0, Comment(rawValue: formerResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        try writeTeamConfig(
            name: teamName,
            leaderSessionID: "current-leader",
            agentID: "current-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Current team task","status":"pending"}"#,
            to: taskDirectory
        )
        var currentEnvironment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        currentEnvironment["CMUX_WORKSPACE_ID"] = currentWorkspaceId
        currentEnvironment["CMUX_SURFACE_ID"] = currentSurfaceId
        let currentResult = runHook(
            context: context,
            environment: currentEnvironment,
            sessionId: "current-session",
            agentID: "current-agent"
        )

        #expect(!currentResult.timedOut, Comment(rawValue: currentResult.stderr))
        #expect(currentResult.status == 0, Comment(rawValue: currentResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let reconciliations = reconcileRequests(in: context)
        #expect(reconciliations.count == 3)
        let formerClear = reconciliations[1]
        #expect(formerClear["workspace_id"] as? String == formerWorkspaceId)
        let teamOwnerID = taskOwnerID(
            directoryName: teamName,
            tasksRootURL: taskDirectory.deletingLastPathComponent()
        )
        #expect(formerClear["owner_id"] as? String == teamOwnerID)
        #expect((formerClear["items"] as? [[String: Any]])?.isEmpty == true)

        let currentDelivery = reconciliations[2]
        #expect(currentDelivery["workspace_id"] as? String == currentWorkspaceId)
        #expect(currentDelivery["owner_id"] as? String == teamOwnerID)
        let currentItems = try #require(currentDelivery["items"] as? [[String: Any]])
        #expect(currentItems.compactMap { $0["text"] as? String } == ["Current team task"])
    }

}
