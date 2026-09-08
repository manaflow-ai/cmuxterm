import Foundation
import Testing

extension ClaudeHookLifecycleCleanupTests {
    @Test func preToolUseNeedsInputUsesAuthoritativeResolvedSurface() throws {
        let context = try Harness.makeContext(name: "needs-input-live-surface")
        defer { context.cleanup() }
        let sessionId = "needs-input-live-surface-session"
        let closedSurfaceId = "66666666-6666-6666-6666-666666666666"

        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: Self.liveWorkspaceId,
            surfaceId: closedSurfaceId,
            cwd: context.root.path
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.liveWorkspaceId: [Self.fallbackSurfaceId]],
            pidTarget: nil,
            surfaceTargets: [Self.liveSurfaceId: Self.liveWorkspaceId]
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43217"

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","permission_mode":"bypassPermissions","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let commands = context.state.snapshot()
        #expect(
            commands.contains {
                $0.hasPrefix("notify_target_async \(Self.liveWorkspaceId) \(Self.liveSurfaceId) ")
            },
            "Needs-input notification must target the authoritative resolved surface; saw \(commands)"
        )
        #expect(
            !commands.contains { $0.contains(closedSurfaceId) },
            "No mutation may target the stale/closed record surface; saw \(commands)"
        )
        let record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(
            record?["surfaceId"] as? String == Self.liveSurfaceId,
            "Upsert must heal the record to the resolved surface, not re-pollute it"
        )
    }

    @Test func preToolUseRejectsPollutedLiveRecord() throws {
        let context = try Harness.makeContext(name: "pre-tool-use-polluted-live-record")
        defer { context.cleanup() }
        let sessionId = "pre-tool-use-polluted-live-record-session"
        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: Self.liveWorkspaceId,
            surfaceId: Self.otherSurfaceId,
            cwd: context.root.path
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.liveWorkspaceId: [Self.liveSurfaceId, Self.otherSurfaceId]],
            pidTarget: nil,
            surfaceTargets: [Self.liveSurfaceId: Self.liveWorkspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43303"
        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"\#(context.root.path)"}"#
        )
        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)
        let commands = context.state.snapshot()
        #expect(!commands.contains { $0.hasPrefix("set_status ") || $0.hasPrefix("clear_notifications ") })
    }

    func assertSuccessfulHook(_ result: ClaudeHookLiveDeliveryHarness.ProcessRunResult) {
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
    }
}
