import Foundation
import Testing

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/9693.
/// Repeated ordinary Claude tool calls must not turn an already-running
/// lifecycle observation into durable Feed telemetry or a session-file write.
@Suite(.serialized)
struct ClaudeHookWriteAmplificationTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    @Test func ordinaryToolUseWhileRunningDoesNotWriteDurableState() throws {
        let context = try Harness.makeContext(name: "pre-tool-write-amplification")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "ordinary-running-tool-session"
        let now: TimeInterval = 4_102_444_800
        let state: [String: Any] = [
            "version": 1,
            "pendingCursorApprovalIndexInitialized": true,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "running",
                    "lastPermissionMode": "default",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        let stateData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try stateData.write(to: context.storeURL)
        let initialAttributes = try FileManager.default.attributesOfItem(atPath: context.storeURL.path)
        let initialFileNumber = (initialAttributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let initialModificationDate = initialAttributes[.modificationDate] as? Date

        _ = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        for _ in 0..<20 {
            let result = Harness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", "pre-tool-use"],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","permission_mode":"default","cwd":"\#(context.root.path)"}"#
            )
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
        }
        #expect(
            !context.state.snapshot().contains { command in
                command.contains(#""method":"feed.push""#)
                    || command.hasPrefix("set_status ")
                    || command.hasPrefix("set_agent_lifecycle ")
                    || command.hasPrefix("clear_notifications ")
            }
        )
        #expect(try Data(contentsOf: context.storeURL) == stateData)
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: context.storeURL.path)
        #expect(
            (finalAttributes[.systemFileNumber] as? NSNumber)?.uint64Value == initialFileNumber,
            "An unchanged session must not be atomically replaced"
        )
        #expect(
            finalAttributes[.modificationDate] as? Date == initialModificationDate,
            "An unchanged session must not be rewritten"
        )
    }

    @Test(arguments: ["AskUserQuestion", "ExitPlanMode", "permission_prompt"])
    func resumeClearsAttentionBeforeOrdinaryObservationsBecomeNoOps(_ trigger: String) throws {
        let context = try Harness.makeContext(name: "hook-resume-write-amplification")
        defer { context.cleanup() }
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "resume-write-amplification-session"
        try Harness.writeSessionStore(
            to: context.storeURL, sessionId: sessionId,
            workspaceId: workspaceId, surfaceId: surfaceId, cwd: context.root.path
        )
        _ = Harness.startDeliveryTargetServer(
            context: context, surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil, surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        let isPermissionPrompt = trigger == "permission_prompt"
        let blockingInput = isPermissionPrompt
            ? #"{"session_id":"\#(sessionId)","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Bash needs approval","cwd":"\#(context.root.path)"}"#
            : #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"\#(trigger)","permission_mode":"bypassPermissions","cwd":"\#(context.root.path)"}"#
        let blocking = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", isPermissionPrompt ? "notification" : "pre-tool-use"],
            environment: environment, standardInput: blockingInput
        )
        #expect(!blocking.timedOut, Comment(rawValue: blocking.stderr))
        try #require(blocking.status == 0, Comment(rawValue: blocking.stderr))
        #expect(try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)?["agentLifecycle"] as? String == "needsInput")
        #expect(context.state.snapshot().contains { $0.hasPrefix("notify_target_async ") })
        let beforeResumeCount = context.state.snapshot().count
        let ordinaryInput = #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","permission_mode":"default","cwd":"\#(context.root.path)"}"#
        let resumed = Harness.runHookProcess(
            context: context, arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment, standardInput: ordinaryInput
        )
        #expect(!resumed.timedOut, Comment(rawValue: resumed.stderr))
        try #require(resumed.status == 0, Comment(rawValue: resumed.stderr))
        #expect(try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)?["agentLifecycle"] as? String == "running")
        let resumedCommands = context.state.snapshot().dropFirst(beforeResumeCount)
        #expect(resumedCommands.contains { $0 == "clear_notifications --tab=\(workspaceId) --panel=\(surfaceId)" })
        #expect(resumedCommands.contains { $0.hasPrefix("set_status claude_code Running ") })

        let runningData = try Data(contentsOf: context.storeURL)
        let runningAttributes = try FileManager.default.attributesOfItem(atPath: context.storeURL.path)
        let beforeNoOpCount = context.state.snapshot().count
        for _ in 0..<5 {
            let result = Harness.runHookProcess(
                context: context, arguments: ["hooks", "claude", "pre-tool-use"],
                environment: environment, standardInput: ordinaryInput
            )
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
        }
        #expect(context.state.snapshot().count == beforeNoOpCount)
        #expect(try Data(contentsOf: context.storeURL) == runningData)
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: context.storeURL.path)
        #expect(finalAttributes[.systemFileNumber] as? NSNumber == runningAttributes[.systemFileNumber] as? NSNumber)
        #expect(finalAttributes[.modificationDate] as? Date == runningAttributes[.modificationDate] as? Date)
    }

    @Test(arguments: ["oversized-padding", "oversized-sessions", "legacy-surface"])
    func unchangedPermissionObservationPersistsLoadRepairs(_ repair: String) throws {
        let context = try Harness.makeContext(name: "hook-load-repair")
        defer { context.cleanup() }
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "load-repair-session"
        let now: TimeInterval = 4_102_444_800
        let record: [String: Any] = [
            "sessionId": sessionId, "workspaceId": workspaceId,
            "surfaceId": surfaceId, "cwd": context.root.path,
            "agentLifecycle": "running", "lastPermissionMode": "default",
            "startedAt": now, "updatedAt": now,
        ]
        var sessions = [sessionId: record]
        if repair == "oversized-sessions" {
            for index in 0..<513 {
                var older = record
                let olderId = "older-\(index)"
                older["sessionId"] = olderId
                older["updatedAt"] = now - Double(index + 1)
                sessions[olderId] = older
            }
        }
        let active: [String: Any] = ["sessionId": sessionId, "updatedAt": now]
        var state: [String: Any] = [
            "version": 1, "pendingCursorApprovalIndexInitialized": true,
            "sessions": sessions, "activeSessionsByWorkspace": [workspaceId: active],
        ]
        if repair != "legacy-surface" {
            state["activeSessionsBySurface"] = [surfaceId: active]
        }
        var originalData = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        if repair.hasPrefix("oversized") {
            // Padding also exercises oversized JSON whose decoded model needs
            // no compaction: semantic equality alone cannot detect this repair.
            originalData.append(Data(repeating: 0x20, count: 8 * 1024 * 1024))
        }
        try originalData.write(to: context.storeURL)
        _ = Harness.startDeliveryTargetServer(
            context: context, surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil, surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        // A read-only lookup must not persist the in-memory repair.
        let lookup = Harness.runHookProcess(
            context: context, arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash"}"#
        )
        try #require(!lookup.timedOut && lookup.status == 0, Comment(rawValue: lookup.stderr))
        #expect(try Data(contentsOf: context.storeURL) == originalData)

        let input = #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","permission_mode":"default"}"#
        let repaired = Harness.runHookProcess(
            context: context, arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment, standardInput: input
        )
        try #require(!repaired.timedOut && repaired.status == 0, Comment(rawValue: repaired.stderr))
        #expect(repaired.stdout == "{}\n")
        let repairedData = try Data(contentsOf: context.storeURL)
        #expect(repairedData != originalData, "An unchanged hook must still persist load-time repairs")
        #expect(repairedData.count < 8 * 1024 * 1024)
        let saved = try #require(JSONSerialization.jsonObject(with: repairedData) as? [String: Any])
        let savedSessions = try #require(saved["sessions"] as? [String: Any])
        #expect(savedSessions.count == (repair == "oversized-sessions" ? 512 : 1))
        let savedSurfaces = try #require(saved["activeSessionsBySurface"] as? [String: [String: Any]])
        #expect(savedSurfaces[surfaceId]?["sessionId"] as? String == sessionId)
        let repairedAttributes = try FileManager.default.attributesOfItem(atPath: context.storeURL.path)

        for _ in 0..<5 {
            let result = Harness.runHookProcess(
                context: context, arguments: ["hooks", "claude", "pre-tool-use"],
                environment: environment, standardInput: input
            )
            #expect(!result.timedOut && result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
        }
        #expect(context.state.snapshot().isEmpty)
        #expect(try Data(contentsOf: context.storeURL) == repairedData)
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: context.storeURL.path)
        #expect(finalAttributes[.systemFileNumber] as? NSNumber == repairedAttributes[.systemFileNumber] as? NSNumber)
        #expect(finalAttributes[.modificationDate] as? Date == repairedAttributes[.modificationDate] as? Date)
    }
}
