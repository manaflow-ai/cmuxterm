import Darwin
import Foundation
import Testing

extension CLICodexHookTimeoutRegressionTests {
    @Test func codexStopPreservesRunningForUntimestampedLiveSibling() throws {
        let cliPath = try bundledCLIPath()
        let root = try makeRuntimeOrderingFixtureRoot(name: "untimestamped")
        let socketPath = makeCodexHookSocketPath("codex-untimed")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-untimestamped-current"
        let siblingSessionId = "codex-untimestamped-sibling"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let livePID = Int(ProcessInfo.processInfo.processIdentifier)
        let eventTime = Date().timeIntervalSince1970
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        try writeRuntimeOrderingStore(
            to: stateURL,
            currentSessionId: sessionId,
            siblingSessionId: siblingSessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            pid: livePID,
            currentEventTime: nil,
            siblingEventTime: nil
        )
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 12
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: runtimeOrderingEnvironment(
                root: root,
                socketPath: socketPath,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                pid: livePID
            ),
            standardInput: "{\"session_id\":\"\(sessionId)\",\"turn_id\":\"current-turn\",\"cwd\":\"\(root.path)\",\"hook_event_name\":\"Stop\",\"timestamp\":\(eventTime),\"last_assistant_message\":\"done\"}",
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let current = try #require(sessions[sessionId] as? [String: Any])
        #expect(
            current["runtimeStatus"] as? String == "running",
            "An untimestamped excluded record must not be demoted while a live running sibling exists"
        )
        #expect(
            !commands.snapshot().contains { $0.hasPrefix("set_status codex Idle ") },
            "The stale Stop must not publish Idle over the live sibling"
        )
    }

    @Test func codexStopKeepsStrictTimestampOrderingForOlderLiveSibling() throws {
        let cliPath = try bundledCLIPath()
        let root = try makeRuntimeOrderingFixtureRoot(name: "timestamped")
        let socketPath = makeCodexHookSocketPath("codex-timed")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-timestamped-current"
        let siblingSessionId = "codex-timestamped-sibling"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let livePID = Int(ProcessInfo.processInfo.processIdentifier)
        let eventTime = Date().timeIntervalSince1970
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        try writeRuntimeOrderingStore(
            to: stateURL,
            currentSessionId: sessionId,
            siblingSessionId: siblingSessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            pid: livePID,
            currentEventTime: eventTime - 1,
            siblingEventTime: eventTime - 2
        )
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 12
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: runtimeOrderingEnvironment(
                root: root,
                socketPath: socketPath,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                pid: livePID
            ),
            standardInput: "{\"session_id\":\"\(sessionId)\",\"turn_id\":\"current-turn\",\"cwd\":\"\(root.path)\",\"hook_event_name\":\"Stop\",\"timestamp\":\(eventTime),\"last_assistant_message\":\"done\"}",
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let current = try #require(sessions[sessionId] as? [String: Any])
        #expect(
            current["runtimeStatus"] as? String == "idle",
            "A sibling older than the timestamped excluded record must not block settlement"
        )
        #expect(
            !commands.snapshot().contains { $0.hasPrefix("set_status codex Idle ") },
            "The older active sibling may keep the workspace badge Running without changing ordering"
        )
    }

    @Test(arguments: [false, true])
    func codexStopRetiresDeadSiblingGeneration(reusedPID: Bool) throws {
        let cliPath = try bundledCLIPath()
        let root = try makeRuntimeOrderingFixtureRoot(name: "dead-generation")
        let socketPath = makeCodexHookSocketPath("codex-dead")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-current-generation"
        let siblingSessionId = "codex-dead-generation"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let livePID = Int(ProcessInfo.processInfo.processIdentifier)
        let siblingPID = reusedPID ? livePID : Int(Int32.max)
        let eventTime = Date().timeIntervalSince1970
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        if !reusedPID {
            try #require(Darwin.kill(pid_t(siblingPID), 0) == -1 && errno == ESRCH)
        }
        try writeRuntimeOrderingStore(
            to: stateURL,
            currentSessionId: sessionId,
            siblingSessionId: siblingSessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            pid: livePID,
            currentEventTime: eventTime - 3,
            siblingEventTime: eventTime - 2,
            siblingPID: siblingPID,
            siblingStartIdentity: reusedPID ? (seconds: 1, microseconds: 0) : nil
        )
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 12
        )
        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: runtimeOrderingEnvironment(
                root: root,
                socketPath: socketPath,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                pid: livePID
            ),
            standardInput: "{\"session_id\":\"\(sessionId)\",\"turn_id\":\"current-turn\",\"cwd\":\"\(root.path)\",\"hook_event_name\":\"Stop\",\"timestamp\":\(eventTime),\"last_assistant_message\":\"done\"}",
            timeout: 5
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let current = try #require(sessions[sessionId] as? [String: Any])
        let sibling = try #require(sessions[siblingSessionId] as? [String: Any])
        #expect(current["runtimeStatus"] as? String == "idle")
        #expect(sibling["runtimeStatus"] == nil)
        #expect(sibling["agentLifecycle"] == nil)
        #expect(sibling["runtimeStatusEventTime"] as? Double == eventTime - 2)
        #expect(commands.snapshot().contains { $0.hasPrefix("set_status codex Idle ") })
    }

    private func makeRuntimeOrderingFixtureRoot(name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-runtime-ordering-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func runtimeOrderingEnvironment(
        root: URL,
        socketPath: String,
        workspaceId: String,
        surfaceId: String,
        pid: Int
    ) -> [String: String] {
        [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CODEX_PID": "\(pid)",
        ]
    }

    private func writeRuntimeOrderingStore(
        to url: URL,
        currentSessionId: String,
        siblingSessionId: String,
        workspaceId: String,
        surfaceId: String,
        pid: Int,
        currentEventTime: TimeInterval?,
        siblingEventTime: TimeInterval?,
        siblingPID: Int? = nil,
        siblingStartIdentity: (seconds: Int64, microseconds: Int64)? = nil
    ) throws {
        let now = Date().timeIntervalSince1970
        var current: [String: Any] = [
            "sessionId": currentSessionId,
            "workspaceId": workspaceId,
            "surfaceId": surfaceId,
            "cwd": url.deletingLastPathComponent().path,
            "pid": pid,
            "agentLifecycle": "running",
            "runtimeStatus": "running",
            "activePromptDepth": 1,
            "activePromptTurnId": "current-turn",
            "activePromptTurnIds": ["current-turn"],
            "lastPromptTurnId": "current-turn",
            "startedAt": now,
            "updatedAt": now,
        ]
        var sibling: [String: Any] = [
            "sessionId": siblingSessionId,
            "workspaceId": workspaceId,
            "surfaceId": surfaceId,
            "cwd": url.deletingLastPathComponent().path,
            "pid": siblingPID ?? pid,
            "agentLifecycle": "running",
            "runtimeStatus": "running",
            "activePromptDepth": 1,
            "activePromptTurnId": "sibling-turn",
            "activePromptTurnIds": ["sibling-turn"],
            "lastPromptTurnId": "sibling-turn",
            "startedAt": now,
            "updatedAt": now,
        ]
        if let currentEventTime {
            current["runtimeStatusEventTime"] = currentEventTime
        }
        if let siblingEventTime {
            sibling["runtimeStatusEventTime"] = siblingEventTime
        }
        if let siblingStartIdentity {
            sibling["pidStartSeconds"] = siblingStartIdentity.seconds
            sibling["pidStartMicroseconds"] = siblingStartIdentity.microseconds
        }
        let object: [String: Any] = [
            "version": 1,
            "sessions": [currentSessionId: current, siblingSessionId: sibling],
        ]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }
}
