import Darwin
import Dispatch
import Foundation
import Testing
import CmuxFoundation

@Suite(.serialized)
struct ClaudeHookFeedTelemetrySwiftTests {
    @Test func sessionStartFeedTelemetryUsesResolvedTTYSurface() throws {
        let context = try FeedTelemetryTestContext(name: "feed")
        defer { _ = context }

        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let leakedSurfaceID = "22222222-2222-2222-2222-222222222222"
        let resolvedSurfaceID = "33333333-3333-3333-3333-333333333333"
        let ttyName = "ttys-claude-feed-surface"
        let feedSeen = DispatchSemaphore(value: 0)
        startServer(
            listenerFD: context.listenerFD,
            state: context.state,
            workspaceID: workspaceID,
            focusedSurfaceID: leakedSurfaceID,
            ttyName: ttyName,
            resolvedSurfaceID: resolvedSurfaceID,
            feedSeen: feedSeen
        )

        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: context.environment(
                workspaceID: workspaceID,
                surfaceID: leakedSurfaceID,
                ttyName: ttyName
            ),
            standardInput: #"{"session_id":"claude-feed-session","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(result.timedOut == false, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(feedSeen.wait(timeout: .now() + 5) == .success, "Expected feed.push, saw \(context.state.commandsSnapshot())")
        let event = try #require(
            context.state.feedEventsSnapshot().last { $0["hook_event_name"] as? String == "SessionStart" },
            "Expected SessionStart feed telemetry, saw \(context.state.commandsSnapshot())"
        )
        #expect(
            event["surface_id"] as? String == resolvedSurfaceID,
            "Feed telemetry must use the resolved agent TTY surface, not leaked CMUX_SURFACE_ID; event=\(event)"
        )
    }

    // Regression for https://github.com/manaflow-ai/cmux/issues/7962: Claude Code
    // renders any plain-text hook stdout as a visible "hook success" block in the
    // conversation transcript — for prompt-submit hooks, a bare "OK" on every
    // prompt. A bare JSON object is consumed as structured hook output with
    // nothing rendered — the same contract the `echo '{}'` no-op fallback in
    // AgentHookDefinitions already relies on — and success is signaled by the
    // exit code, so hook stdout must stay machine-consumable.
    @Test func sessionStartStdoutIsSilentJSONAck() throws {
        let context = try FeedTelemetryTestContext(name: "silent-ack")
        defer { _ = context }

        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let ttyName = "ttys-claude-silent-ack"
        let feedSeen = DispatchSemaphore(value: 0)
        startServer(
            listenerFD: context.listenerFD,
            state: context.state,
            workspaceID: workspaceID,
            focusedSurfaceID: surfaceID,
            ttyName: ttyName,
            resolvedSurfaceID: surfaceID,
            feedSeen: feedSeen
        )

        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: context.environment(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                ttyName: ttyName
            ),
            standardInput: #"{"session_id":"claude-silent-ack-session","source":"startup","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(result.timedOut == false, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
    }

    @Test func copilotFeedExpandsRealToolCallBatchesWithNativeIdentity() throws {
        let context = try FeedTelemetryTestContext(name: "copilot-identity")
        defer { _ = context }

        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let feedSeen = DispatchSemaphore(value: 0)
        startServer(
            listenerFD: context.listenerFD,
            state: context.state,
            workspaceID: workspaceID,
            focusedSurfaceID: surfaceID,
            ttyName: "ttys-copilot-identity",
            resolvedSurfaceID: surfaceID,
            feedSeen: feedSeen
        )

        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "feed", "--source", "copilot", "--event", "preToolUse"],
            environment: context.environment(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                ttyName: "ttys-copilot-identity"
            ).merging([
                "TRACEPARENT": "00-8327fe24c2bef682bc9aca2509a55783-c9e6580dd8fe7ea7-01"
            ]) { _, override in override },
            standardInput: """
            {"sessionId":"copilot-session","cwd":"\(context.root.path)","toolCalls":[{"id":"tool-9","name":"shell","args":{"command":"pwd"}},{"id":"tool-10","name":"view","args":"{\\"path\\":\\"README.md\\"}"}]}
            """,
            timeout: 5
        )

        #expect(result.timedOut == false, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(feedSeen.wait(timeout: .now() + 5) == .success)
        #expect(feedSeen.wait(timeout: .now() + 5) == .success)
        let events = context.state.feedEventsSnapshot()
        #expect(events.count == 2)
        #expect(events.map { $0["tool_name"] as? String } == ["shell", "view"])
        #expect(events.map { $0["_action_request_id"] as? String } == ["tool-9", "tool-10"])
        #expect(events.map { $0["_opencode_request_id"] as? String } == ["tool-9", "tool-10"])
        #expect(events.map { $0["_source_event_id"] as? String } == ["tool-9", "tool-10"])
        #expect(events.allSatisfy { $0["_source_revision"] == nil })
        #expect(events.allSatisfy {
            ($0["_causal_chain_id"] as? String) == "8327fe24c2bef682bc9aca2509a55783"
        })
        let firstInput = try #require(events[0]["tool_input"] as? [String: Any])
        let secondInput = try #require(events[1]["tool_input"] as? [String: Any])
        #expect(firstInput["command"] as? String == "pwd")
        #expect(secondInput["path"] as? String == "README.md")
    }

    @Test func copilotErrorHookPreservesFailureDetailsAsTelemetry() throws {
        let context = try FeedTelemetryTestContext(name: "copilot-error")
        defer { _ = context }

        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let feedSeen = DispatchSemaphore(value: 0)
        startServer(
            listenerFD: context.listenerFD,
            state: context.state,
            workspaceID: workspaceID,
            focusedSurfaceID: surfaceID,
            ttyName: "ttys-copilot-error",
            resolvedSurfaceID: surfaceID,
            feedSeen: feedSeen
        )

        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "copilot", "error",
                "--workspace", workspaceID,
                "--surface", surfaceID,
            ],
            environment: context.environment(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                ttyName: "ttys-copilot-error"
            ).merging([
                "CMUX_AGENT_LAUNCH_KIND": "copilot",
                "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/copilot",
                "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(["/usr/local/bin/copilot"]),
                "CMUX_AGENT_HOOK_STATE_DIR": context.root.path,
                "CMUX_COPILOT_PID": String(getpid()),
            ]) { _, override in override },
            standardInput: """
            {"sessionId":"copilot-session","timestamp":9,"cwd":"\(context.root.path)","error":{"message":"provider unavailable","name":"ProviderError","stack":"private stack"},"errorContext":"model_call","recoverable":true}
            """,
            timeout: 5
        )

        #expect(result.timedOut == false, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(feedSeen.wait(timeout: .now() + 5) == .success)
        let feedRequest = try #require(
            context.state.commandsSnapshot()
                .compactMap(jsonObject)
                .first { ($0["method"] as? String) == "feed.push" }
        )
        #expect(feedRequest["id"] is String)
        #expect(context.state.commandsSnapshot().contains {
            $0.contains("agent_journal_append") && $0.contains("agent.error.reported")
        })
        let event = try #require(
            context.state.feedEventsSnapshot().last { $0["hook_event_name"] as? String == "Notification" }
        )
        #expect(event["is_error"] as? Bool == true)
        #expect(event["_source_revision"] as? String == "9")
        #expect((event["_source_event_id"] as? String)?.hasPrefix("cmux-derived-") == true)
        let payload = try #require(event["tool_input"] as? [String: Any])
        #expect(payload["error_context"] as? String == "model_call")
        #expect(payload["recoverable"] as? Bool == true)
        #expect((payload["error"] as? String)?.contains("provider unavailable") == true)
        #expect((payload["error"] as? String)?.contains("private stack") == false)
    }

    @Test func copilotChildAndAsynchronousHooksStayTelemetryOnly() throws {
        let context = try FeedTelemetryTestContext(name: "copilot-child")
        defer { _ = context }

        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let feedSeen = DispatchSemaphore(value: 0)
        startServer(
            listenerFD: context.listenerFD,
            state: context.state,
            workspaceID: workspaceID,
            focusedSurfaceID: surfaceID,
            ttyName: "ttys-copilot-child",
            resolvedSurfaceID: surfaceID,
            feedSeen: feedSeen
        )
        let stateURL = context.root.appendingPathComponent("copilot-hook-sessions.json")
        let environment = context.environment(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            ttyName: "ttys-copilot-child"
        ).merging([
            "CMUX_AGENT_LAUNCH_KIND": "copilot",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/copilot",
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(["/usr/local/bin/copilot"]),
            "CMUX_COPILOT_PID": String(getpid()),
            "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS": "0",
            "CMUX_AGENT_HOOK_STATE_DIR": context.root.path,
        ]) { _, override in override }
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)

        let rootStart = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "copilot", "session-start",
                "--workspace", workspaceID,
                "--surface", surfaceID,
            ],
            environment: environment,
            standardInput: """
            {"sessionId":"root-session","timestamp":1,"cwd":"\(context.root.path)","source":"new"}
            """,
            timeout: 5
        )
        #expect(rootStart.status == 0, Comment(rawValue: rootStart.stderr))
        #expect(feedSeen.wait(timeout: .now() + 5) == .success)
        let baselineCount = context.state.commandsSnapshot().count

        let childPrompt = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "copilot", "prompt-submit",
                "--workspace", workspaceID,
                "--surface", surfaceID,
            ],
            environment: environment,
            standardInput: """
            {"sessionId":"child-session","timestamp":2,"cwd":"\(context.root.path)","prompt":"child task"}
            """,
            timeout: 5
        )
        #expect(childPrompt.status == 0, Comment(rawValue: childPrompt.stderr))
        #expect(feedSeen.wait(timeout: .now() + 5) == .success)
        let stateData = try Data(contentsOf: stateURL)
        let state = try #require(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        let sessions = try #require(state["sessions"] as? [String: Any])
        #expect(sessions["root-session"] != nil)
        #expect(sessions["child-session"] == nil)

        let childTool = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "feed", "--source", "copilot", "--event", "preToolUse"],
            environment: environment,
            standardInput: """
            {"sessionId":"child-session","cwd":"\(context.root.path)","toolCalls":[{"id":"child-tool-1","name":"shell","args":{"command":"pwd"}}]}
            """,
            timeout: 5
        )
        #expect(childTool.status == 0, Comment(rawValue: childTool.stderr))
        #expect(feedSeen.wait(timeout: .now() + 5) == .success)

        let childEnd = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "copilot", "session-end",
                "--workspace", workspaceID,
                "--surface", surfaceID,
            ],
            environment: environment,
            standardInput: """
            {"sessionId":"child-session","timestamp":2.5,"cwd":"\(context.root.path)"}
            """,
            timeout: 5
        )
        #expect(childEnd.status == 0, Comment(rawValue: childEnd.stderr))
        #expect(feedSeen.wait(timeout: .now() + 5) == .success)

        let shellCompleted = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "copilot", "notification",
                "--workspace", workspaceID,
                "--surface", surfaceID,
            ],
            environment: environment,
            standardInput: """
            {"sessionId":"root-session","timestamp":3,"cwd":"\(context.root.path)","hook_event_name":"Notification","message":"Shell completed","notification_type":"shell_completed"}
            """,
            timeout: 5
        )
        #expect(shellCompleted.status == 0, Comment(rawValue: shellCompleted.stderr))
        #expect(feedSeen.wait(timeout: .now() + 5) == .success)

        let newCommands = Array(context.state.commandsSnapshot().dropFirst(baselineCount))
        #expect(!newCommands.contains { $0.contains("set_status copilot") })
        #expect(!newCommands.contains { $0.contains("set_agent_pid copilot.") })
        let events = context.state.feedEventsSnapshot()
        #expect(events.contains {
            guard let rawValue = $0["session_id"] as? String,
                  let identity = FeedWorkstreamIdentifier(rawValue: rawValue) else {
                return false
            }
            return identity.agentID == "copilot"
                && identity.sessionID == "child-session"
                && ($0["_telemetry_only"] as? Bool) == true
        })
        #expect(events.contains {
            ($0["_action_request_id"] as? String) == "child-tool-1"
                && ($0["_telemetry_only"] as? Bool) == true
        })
        #expect(events.contains {
            guard ($0["hook_event_name"] as? String) == "SessionEnd",
                  let rawValue = $0["session_id"] as? String,
                  let identity = FeedWorkstreamIdentifier(rawValue: rawValue) else {
                return false
            }
            return identity.sessionID == "child-session"
                && ($0["_telemetry_only"] as? Bool) == true
        })
        #expect(events.contains {
            ($0["hook_event_name"] as? String) == "Notification"
                && (($0["tool_input"] as? [String: Any])?["notification_type"] as? String) == "shell_completed"
                && ($0["_telemetry_only"] as? Bool) == true
        })

        let permissionPrompt = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "copilot", "notification",
                "--workspace", workspaceID,
                "--surface", surfaceID,
            ],
            environment: environment,
            standardInput: """
            {"sessionId":"root-session","timestamp":4,"cwd":"\(context.root.path)","hook_event_name":"Notification","message":"Permission required","notification_type":"permission_prompt"}
            """,
            timeout: 5
        )
        #expect(permissionPrompt.status == 0, Comment(rawValue: permissionPrompt.stderr))
        #expect(feedSeen.wait(timeout: .now() + 5) == .success)
        #expect(context.state.commandsSnapshot().contains {
            $0.contains("agent_journal_append") && $0.contains("agent.approval.requested")
        })
    }

    @Test func deadCopilotRootDoesNotBlockAReplacementSession() throws {
        let context = try FeedTelemetryTestContext(name: "copilot-dead-root")
        defer { _ = context }

        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let feedSeen = DispatchSemaphore(value: 0)
        startServer(
            listenerFD: context.listenerFD,
            state: context.state,
            workspaceID: workspaceID,
            focusedSurfaceID: surfaceID,
            ttyName: "ttys-copilot-dead-root",
            resolvedSurfaceID: surfaceID,
            feedSeen: feedSeen
        )
        let stateURL = context.root.appendingPathComponent("copilot-hook-sessions.json")
        let liveEnvironment = context.environment(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            ttyName: "ttys-copilot-dead-root"
        ).merging([
            "CMUX_AGENT_LAUNCH_KIND": "copilot",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/copilot",
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(["/usr/local/bin/copilot"]),
            "CMUX_COPILOT_PID": String(getpid()),
            "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS": "0",
            "CMUX_AGENT_HOOK_STATE_DIR": context.root.path,
        ]) { _, override in override }
        let deadRootEnvironment = liveEnvironment.merging([
            "CMUX_COPILOT_PID": "2147483647"
        ]) { _, override in override }
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)

        let first = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "copilot", "session-start",
                "--workspace", workspaceID,
                "--surface", surfaceID,
            ],
            environment: deadRootEnvironment,
            standardInput: """
            {"sessionId":"dead-root","timestamp":1,"cwd":"\(context.root.path)","source":"new"}
            """,
            timeout: 5
        )
        #expect(first.status == 0, Comment(rawValue: first.stderr))
        #expect(feedSeen.wait(timeout: .now() + 5) == .success)
        let firstStateData = try Data(contentsOf: stateURL)
        let firstState = try #require(
            JSONSerialization.jsonObject(with: firstStateData) as? [String: Any]
        )
        let firstSessions = try #require(firstState["sessions"] as? [String: Any])
        let deadRoot = try #require(firstSessions["dead-root"] as? [String: Any])
        #expect(deadRoot["pid"] as? Int == 2_147_483_647)
        #expect(deadRoot["runtimeStatus"] as? String == "running")
        let baselineCount = context.state.commandsSnapshot().count

        let replacement = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "copilot", "session-start",
                "--workspace", workspaceID,
                "--surface", surfaceID,
            ],
            environment: liveEnvironment,
            standardInput: """
            {"sessionId":"replacement-root","timestamp":2,"cwd":"\(context.root.path)","source":"new"}
            """,
            timeout: 5
        )
        #expect(replacement.status == 0, Comment(rawValue: replacement.stderr))
        #expect(feedSeen.wait(timeout: .now() + 5) == .success)
        let replacementStateData = try Data(contentsOf: stateURL)
        let replacementState = try #require(
            JSONSerialization.jsonObject(with: replacementStateData) as? [String: Any]
        )
        let replacementSessions = try #require(replacementState["sessions"] as? [String: Any])
        #expect(replacementSessions["replacement-root"] != nil)
        let newCommands = Array(context.state.commandsSnapshot().dropFirst(baselineCount))
        #expect(
            newCommands.contains { $0.contains("set_agent_pid copilot.replacement-root") },
            Comment(rawValue: newCommands.joined(separator: "\n"))
        )
    }
}

private final class FeedTelemetryTestContext {
    let root: URL
    let socketPath: String
    let listenerFD: Int32
    let state: FeedTelemetryMockState

    init(name: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = makeSocketPath(name)
        do {
            let listenerFD = try bindUnixSocket(at: socketPath)
            self.root = root
            self.socketPath = socketPath
            self.listenerFD = listenerFD
            self.state = FeedTelemetryMockState()
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    deinit {
        CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
        Darwin.close(listenerFD)
        unlink(socketPath)
        try? FileManager.default.removeItem(at: root)
    }

    func environment(workspaceID: String, surfaceID: String, ttyName: String) -> [String: String] {
        [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceID,
            "CMUX_SURFACE_ID": surfaceID,
            "CMUX_CLI_TTY_NAME": ttyName,
            "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("claude-hook-sessions.json").path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/claude",
            "CMUX_AGENT_LAUNCH_CWD": root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(["/usr/local/bin/claude"]),
        ]
    }
}

private final class FeedTelemetryMockState: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    private var feedEvents: [[String: Any]] = []

    func appendCommand(_ command: String) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    func appendFeedEvent(_ event: [String: Any]) {
        lock.lock()
        feedEvents.append(event)
        lock.unlock()
    }

    func commandsSnapshot() -> [String] {
        lock.lock()
        let value = commands
        lock.unlock()
        return value
    }

    func feedEventsSnapshot() -> [[String: Any]] {
        lock.lock()
        let value = feedEvents
        lock.unlock()
        return value
    }
}

private struct ProcessRunResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

private func startServer(
    listenerFD: Int32,
    state: FeedTelemetryMockState,
    workspaceID: String,
    focusedSurfaceID: String,
    ttyName: String,
    resolvedSurfaceID: String,
    feedSeen: DispatchSemaphore
) {
    CLIMockAcceptLoopRegistry.shared.start(
        listenerFD: listenerFD,
        onConnection: { clientFD in
            handleClient(
                clientFD,
                state: state,
                workspaceID: workspaceID,
                focusedSurfaceID: focusedSurfaceID,
                ttyName: ttyName,
                resolvedSurfaceID: resolvedSurfaceID,
                feedSeen: feedSeen
            )
        },
        onListenerClosed: {}
    )
}

private func handleClient(
    _ clientFD: Int32,
    state: FeedTelemetryMockState,
    workspaceID: String,
    focusedSurfaceID: String,
    ttyName: String,
    resolvedSurfaceID: String,
    feedSeen: DispatchSemaphore
) {
    defer { Darwin.close(clientFD) }

    func writeResponse(_ response: String) {
        let line = response + "\n"
        _ = line.withCString { pointer in
            Darwin.write(clientFD, pointer, strlen(pointer))
        }
    }

    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.read(clientFD, &buffer, buffer.count)
        if count < 0 {
            if errno == EINTR { continue }
            return
        }
        if count == 0 { return }
        pending.append(buffer, count: count)

        while let newlineRange = pending.firstRange(of: Data([0x0A])) {
            let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
            pending.removeSubrange(0...newlineRange.lowerBound)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            state.appendCommand(line)
            writeResponse(
                response(
                    for: line,
                    state: state,
                    workspaceID: workspaceID,
                    focusedSurfaceID: focusedSurfaceID,
                    ttyName: ttyName,
                    resolvedSurfaceID: resolvedSurfaceID,
                    feedSeen: feedSeen
                )
            )
        }
    }
}

private func response(
    for line: String,
    state: FeedTelemetryMockState,
    workspaceID: String,
    focusedSurfaceID: String,
    ttyName: String,
    resolvedSurfaceID: String,
    feedSeen: DispatchSemaphore
) -> String {
    guard let payload = jsonObject(line),
          let method = payload["method"] as? String else {
        return "OK"
    }
    if method == "feed.push" {
        if let params = payload["params"] as? [String: Any],
           let event = params["event"] as? [String: Any] {
            state.appendFeedEvent(event)
            feedSeen.signal()
        }
        return "OK"
    }
    guard let id = payload["id"] as? String else {
        return "OK"
    }
    switch method {
    case "surface.list":
        return v2Response(id: id, ok: true, result: [
            "surfaces": [
                ["id": focusedSurfaceID, "ref": "surface:1", "focused": true],
                ["id": resolvedSurfaceID, "ref": "surface:2", "focused": false],
            ],
        ])
    case "debug.terminals":
        return v2Response(id: id, ok: true, result: [
            "terminals": [[
                "tty": ttyName,
                "workspace_id": workspaceID,
                "surface_id": resolvedSurfaceID,
            ]],
        ])
    case "surface.resume.set":
        return v2Response(id: id, ok: true, result: ["resume_binding": [:]])
    default:
        return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": method])
    }
}

private func makeSocketPath(_ name: String) -> String {
    let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
    return URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cli-\(name)-\(shortID).sock")
        .path
}

private func bindUnixSocket(at path: String) throws -> Int32 {
    unlink(path)
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw NSError(domain: "cmux.tests", code: Int(errno))
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
    let utf8 = Array(path.utf8)
    guard utf8.count < maxPathLength else {
        Darwin.close(fd)
        throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG))
    }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { pathBuffer in
            for index in 0..<utf8.count {
                pathBuffer[index] = CChar(bitPattern: utf8[index])
            }
            pathBuffer[utf8.count] = 0
        }
    }

    let bindResult = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0, Darwin.listen(fd, 8) == 0 else {
        let code = errno
        Darwin.close(fd)
        throw NSError(domain: "cmux.tests", code: Int(code))
    }
    return fd
}

private func base64NULSeparated(_ values: [String]) -> String {
    var bytes: [UInt8] = []
    for value in values {
        bytes.append(contentsOf: value.utf8)
        bytes.append(0)
    }
    return Data(bytes).base64EncodedString()
}

private func runProcess(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    standardInput: String? = nil,
    timeout: TimeInterval
) -> ProcessRunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.environment = environment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    var stdinPipe: Pipe?
    if let standardInput {
        let input = Pipe()
        process.standardInput = input
        stdinPipe = input
        input.fileHandleForWriting.write(Data(standardInput.utf8))
        input.fileHandleForWriting.closeFile()
    }

    let exitSignal = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exitSignal.signal() }
    do {
        try process.run()
    } catch {
        return ProcessRunResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
    }
    _ = stdinPipe
    let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
    if timedOut {
        process.terminate()
        _ = exitSignal.wait(timeout: .now() + 1)
    }

    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
    return ProcessRunResult(
        status: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? "",
        timedOut: timedOut
    )
}

private func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func v2Response(
    id: String,
    ok: Bool,
    result: [String: Any]? = nil,
    error: [String: Any]? = nil
) -> String {
    var object: [String: Any] = [
        "id": id,
        "ok": ok,
    ]
    if let result { object["result"] = result }
    if let error { object["error"] = error }
    let data = try? JSONSerialization.data(withJSONObject: object)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":false}"#
}
