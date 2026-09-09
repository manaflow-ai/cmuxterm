import Darwin
import Foundation
import Testing

extension CLICodexHookTimeoutRegressionTests {
    @Test func codexInstalledAsyncStopDoesNotMarkNewerTurnIdle() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-installed-stale-stop-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-inst")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-installed-stale-stop-session"
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 24
        )

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let promptCommand = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "UserPromptSubmit" }?.command
        )
        let stopCommand = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "Stop" }?.command
        )
        let sessionStartCommand = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "SessionStart" }?.command
        )
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": codexHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "TMPDIR": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_BUNDLED_CLI_PATH": cliPath,
            "CMUX_CODEX_PID": "4242",
        ]

        let sessionStart = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", sessionStartCommand],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 3
        )
        #expect(sessionStart.status == 0, Comment(rawValue: sessionStart.stderr))
        #expect(sessionStart.stdout == "{}\n")
        #expect(
            waitForFile(
                root.appendingPathComponent("codex-turn-ledger.json"),
                containing: sessionId,
                timeout: 2
            ),
            "The installed SessionStart hook must establish Codex ownership before prompt hooks run"
        )

        let oldPrompt = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", promptCommand],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"old"}"#,
            timeout: 3
        )
        #expect(oldPrompt.status == 0, Comment(rawValue: oldPrompt.stderr))
        #expect(oldPrompt.stdout == "{}\n")
        #expect(waitForConditionBlocking(timeout: 2) {
            commands.snapshot().contains { $0.hasPrefix("set_status codex Running ") }
        })

        // The old turn has completed in Codex, while its detached Stop is
        // delayed. Without this real terminal boundary, two prompt submits
        // describe nested work rather than successive foreground turns.
        let transcriptURL = root.appendingPathComponent("completed-old-turn.jsonl")
        try """
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"old-turn"}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"old-turn"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        // Codex prompt reconciliation publishes its status through the journal
        // path; it does not issue Claude's direct clear_notifications command.
        // Count a fresh Running status to prove the detached current prompt
        // finished before admitting the stale Stop below.
        let runningStatusCountBeforeCurrentPrompt = commands.snapshot()
            .filter { $0.hasPrefix("set_status codex Running ") }
            .count
        let currentPrompt = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", promptCommand],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"current"}"#,
            timeout: 3
        )
        #expect(currentPrompt.status == 0, Comment(rawValue: currentPrompt.stderr))
        #expect(currentPrompt.stdout == "{}\n")
        #expect(waitForConditionBlocking(timeout: 2) {
            commands.snapshot()
                .filter { $0.hasPrefix("set_status codex Running ") }
                .count > runningStatusCountBeforeCurrentPrompt
        })

        let staleStopStart = commands.snapshot().count
        let staleStop = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", stopCommand],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(root.path)","hook_event_name":"Stop","last_assistant_message":"old done"}"#,
            timeout: 3
        )
        #expect(staleStop.status == 0, Comment(rawValue: staleStop.stderr))
        #expect(staleStop.stdout == "{}\n")
        #expect(waitForConditionBlocking(timeout: 2) {
            commands.snapshot().count > staleStopStart
        })

        let staleStopCommands = Array(commands.snapshot().dropFirst(staleStopStart))
        #expect(
            !staleStopCommands.contains {
                $0.hasPrefix("notify_target") || ($0.hasPrefix("set_status codex ") && $0.contains(" Idle "))
            },
            "An installed async Stop from an older turn must not notify or mark a newer running turn idle, saw \(staleStopCommands)"
        )
    }

    @Test func codexPromptSubmitDoesNotReviveStoppedTurn() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-prompt-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-stale")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-stale-session"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "agentLifecycle": "idle",
                    "runtimeStatus": "idle",
                    "terminalPromptTurnIds": ["turn-done"],
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-done","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"late"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let sentCommands = commands.snapshot()
        #expect(!sentCommands.contains { $0.hasPrefix("set_status codex Running ") })
        #expect(!sentCommands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(!sentCommands.contains { codexHookJSONObject($0)?["method"] as? String == "feed.push" })
        #expect(!sentCommands.contains { codexHookJSONObject($0)?["method"] as? String == "surface.resume.set" })

        let saved = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        #expect(session["agentLifecycle"] as? String == "idle")
        #expect(session["runtimeStatus"] as? String == "idle")
        #expect(session["terminalPromptTurnIds"] as? [String] == ["turn-done"])
    }

    @Test func codexOlderRunningEventDoesNotOverwriteNewerIdleStop() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-out-of-order-prompt-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-order")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-out-of-order-session"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let idleStopEventTime: TimeInterval = 1_700_000_200
        let staleRunningEventTime: TimeInterval = 1_700_000_100
        let now = Date.now.timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "agentLifecycle": "idle",
                    "runtimeStatus": "idle",
                    "runtimeStatusEventTime": idleStopEventTime,
                    "lastPromptTurnId": "turn-done",
                    "startedAt": idleStopEventTime,
                    // Keep the record live so the store does not prune it
                    // before the stale-event watermark is evaluated.
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: "{\"session_id\":\"\(sessionId)\",\"turn_id\":\"turn-before-stop\",\"cwd\":\"\(root.path)\",\"hook_event_name\":\"UserPromptSubmit\",\"timestamp\":\(staleRunningEventTime),\"prompt\":\"late running\"}",
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let sentCommands = commands.snapshot()
        #expect(!sentCommands.contains { $0.hasPrefix("set_status codex Running ") })
        #expect(!sentCommands.contains { $0.hasPrefix("set_agent_lifecycle codex running ") })
        #expect(!sentCommands.contains { $0.hasPrefix("clear_notifications ") })

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        #expect(session["agentLifecycle"] as? String == "idle")
        #expect(session["runtimeStatus"] as? String == "idle")
        #expect(session["runtimeStatusEventTime"] as? Double == idleStopEventTime)
    }

    @Test func codexStopIgnoresLiveStaleSiblingWithoutActiveTurn() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-sibling-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-sib")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let staleSurfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "codex-current-session"
        let staleSessionId = "codex-stale-sibling-session"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let livePID = Int(ProcessInfo.processInfo.processIdentifier)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let eventTime: TimeInterval = 1_700_000_200
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "pid": livePID,
                    "agentLifecycle": "running",
                    "runtimeStatus": "running",
                    "activePromptDepth": 1,
                    "activePromptTurnId": "turn-current",
                    "activePromptTurnIds": ["turn-current"],
                    "lastPromptTurnId": "turn-current",
                    "runtimeStatusEventTime": eventTime - 1,
                    "startedAt": eventTime - 1,
                    "updatedAt": eventTime - 1,
                ],
                staleSessionId: [
                    "sessionId": staleSessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": staleSurfaceId,
                    "cwd": root.path,
                    "pid": livePID,
                    "agentLifecycle": "running",
                    "runtimeStatus": "running",
                    "lastPromptTurnId": "turn-stale",
                    "runtimeStatusEventTime": eventTime - 2,
                    "startedAt": eventTime - 600,
                    "updatedAt": eventTime - 600,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 12
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CODEX_PID": "\(livePID)",
            ],
            standardInput: "{\"session_id\":\"\(sessionId)\",\"turn_id\":\"turn-current\",\"cwd\":\"\(root.path)\",\"hook_event_name\":\"Stop\",\"timestamp\":\(eventTime),\"last_assistant_message\":\"done\"}",
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let sentCommands = commands.snapshot()
        #expect(
            sentCommands.contains { $0.hasPrefix("set_status codex Idle ") },
            "A live but inactive stale sibling must not veto Idle: \(sentCommands)"
        )

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        #expect(session["agentLifecycle"] as? String == "idle")
        #expect(session["runtimeStatus"] as? String == "idle")
    }

}
