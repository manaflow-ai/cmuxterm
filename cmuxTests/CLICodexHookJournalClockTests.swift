import Darwin
import Foundation
import Testing

extension CLICodexHookTimeoutRegressionTests {
    @Test(arguments: ["1700000200.001000", "", "invalid"])
    func permissionJournalUsesCapturedClockWithoutInventingOrdering(capturedAt: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-journal-clock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = makeCodexHookSocketPath("clock")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD, commands: commands, surfaceId: surfaceId, connectionLimit: 16
        )
        let result = runCodexHookProcess(
            executablePath: try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self),
            arguments: ["hooks", "codex", "notification"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_AGENT_HOOK_CAPTURED_AT": capturedAt,
                "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS": "0",
                "CMUX_CLI_SENTRY_DISABLED": "1"
            ],
            standardInput: #"{"session_id":"journal-clock","cwd":"\#(root.path)","hook_event_name":"PermissionRequest","message":"approval required","occurred_at_ms":1700000300000}"#,
            timeout: 5
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n", "Clock failure must not prevent the permission hook from replying")
        let captures = AgentJournalAppendCapture.captures(in: commands.snapshot())
            .filter { $0.kind == "agent.approval.requested" }
        #expect(!captures.isEmpty, "Exercise the emitted journal event, not just the parser")
        for capture in captures {
            if let attention = capture.draft["attention"] as? [String: Any],
               let notification = attention["notification"] as? [String: Any] {
                #expect(notification["correlation_key"] as? String != "codex",
                        "The legacy status watermark must not become every turn's notification identity")
            }
            if capturedAt == "1700000200.001000" {
                #expect((capture.draft["occurred_at_ms"] as? NSNumber)?.int64Value == 1_700_000_200_001)
                #expect(capture.workspaceId == workspaceId)
                #expect(capture.surfaceId == surfaceId)
                #expect(capture.unattributedReason == nil)
            } else {
                #expect(capture.workspaceId == nil)
                #expect(capture.surfaceId == nil)
                #expect(capture.unattributedReason == "invalid-hook-event-time")
            }
        }
    }

    @Test
    func installedAsyncHooksReserveDistinctJournalMilliseconds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-clock-precision-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let clockDirectory = root.appendingPathComponent("cmux-agent-hook-clock-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clockDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let install = runCodexHookProcess(
            executablePath: try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self),
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome), timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))
        let command = try #require(codexHookEntries(in: codexHome).first { $0.eventName == "PermissionRequest" }?.command)
        let captureFile = root.appendingPathComponent("captured-times.txt")
        let fakeCLI = root.appendingPathComponent("cmux")
        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "cat >/dev/null",
            "printf '%s\\n' \"$CMUX_AGENT_HOOK_CAPTURED_AT\" >> \"$CMUX_TEST_CAPTURE\"",
            "printf '{}\\n'"
        ])
        // Hold the persisted clock ahead of filesystem time. Both invocations
        // must advance this exact sub-millisecond tick, independent of CPU speed.
        let seed = (Int64(Date.now.timeIntervalSince1970) + 60) * 1_000_000 + 111
        try "\(seed)\n".write(to: clockDirectory.appendingPathComponent("state"),
                              atomically: true, encoding: .utf8)
        for invocation in 0..<2 {
            let result = runCodexHookProcess(
                executablePath: "/bin/sh", arguments: ["-c", command],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "TMPDIR": root.path,
                    "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                    "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                    "CMUX_TEST_CAPTURE": captureFile.path
                ],
                standardInput: "{}", timeout: 5
            )
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            let expectedCaptureCount = invocation + 1
            #expect(waitForConditionBlocking(timeout: 2) {
                guard let content = try? String(contentsOf: captureFile, encoding: .utf8) else {
                    return false
                }
                return content.split(whereSeparator: \.isNewline).count >= expectedCaptureCount
            }, "Detached PermissionRequest hook did not append capture \(expectedCaptureCount)")
        }
        let values = try String(contentsOf: captureFile, encoding: .utf8)
            .split(separator: "\n").compactMap { Double($0) }
        #expect(values.count == 2)
        let ticks = values.map { Int64(($0 * 1_000_000).rounded()) }
        #expect(ticks == [(seed / 1000 + 1) * 1000, (seed / 1000 + 2) * 1000])
    }

    @Test func codexTranscriptMonitorReplayUsesItsFreshEventTime() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-replay-time-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-mon")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-monitor-replay-session"
        let turnId = "codex-monitor-replay-turn"
        let ownerPID = 4242
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let transcriptURL = root.appendingPathComponent("transcript.jsonl")
        // Keep the persisted fixture deterministic while remaining inside the
        // production parser's supported epoch range.
        let inheritedEventTime: TimeInterval = 1_700_000_000
        let now = Date.now.timeIntervalSince1970
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        try """
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"\(turnId)"}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"\(turnId)","last_agent_message":"done"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "pid": Int(ProcessInfo.processInfo.processIdentifier),
                    "agentLifecycle": "running",
                    "runtimeStatus": "running",
                    "runtimeStatusEventTime": inheritedEventTime - 1,
                    "activePromptDepth": 1,
                    "activePromptTurnId": turnId,
                    "activePromptTurnIds": [turnId],
                    "lastPromptTurnId": turnId,
                    "startedAt": now,
                    // Keep the record live so transcript replay reaches the
                    // event-time ordering check instead of age-pruning it.
                    "updatedAt": now,
                ],
            ],
        ], options: [.prettyPrinted, .sortedKeys]).write(to: stateURL, options: .atomic)
        let ledgerURL = root.appendingPathComponent("codex-turn-ledger.json")
        let ledgerRecord: [String: Any] = [
            "workspaceID": workspaceId, "surfaceID": surfaceId,
            "owner": ["pid": ownerPID], "activeTurnID": turnId,
            "activeChildrenByTurn": [:], "unknownChildrenByTurn": [:],
            "terminalChildrenByTurn": [:], "pendingTurns": [:],
            "settledTurnIDs": [], "notifiedTurnIDs": [], "updatedAt": now,
        ]
        try JSONSerialization.data(withJSONObject: [
            "records": [sessionId: ledgerRecord], "surfaceOwners": [surfaceId: sessionId],
        ], options: [.prettyPrinted, .sortedKeys]).write(to: ledgerURL, options: .atomic)
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 16
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "codex", "monitor",
                "--workspace", workspaceId,
                "--surface", surfaceId,
                "--session", sessionId,
                "--turn", turnId,
                "--transcript", transcriptURL.path,
            ],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "TMPDIR": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CODEX_TURN_LEDGER_PATH": ledgerURL.path,
                "CMUX_AGENT_HOOK_CAPTURED_AT": AgentHookWireFormat.eventTime(inheritedEventTime),
                "CMUX_CODEX_PID": "\(ownerPID)",
                "CMUX_CODEX_HOOK_PID": "\(ownerPID)",
                "SWIFT_BACKTRACE": "enable=yes,interactive=no,timeout=0s,symbolicate=off,color=no",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 10
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(
            result.status == 0,
            Comment(rawValue: "status=\(result.status) terminationReason=\(String(describing: result.terminationReason?.rawValue)) stderr=\(result.stderr)")
        )
        #expect(result.stdout == "{}\n")
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        let replayEventTime = try #require(session["runtimeStatusEventTime"] as? Double)
        #expect(
            replayEventTime > inheritedEventTime,
            "The monitor's completion replay must use its fresh sample, not the monitor's inherited start timestamp"
        )
        let journalCapture = try #require(AgentJournalAppendCapture.first(
            in: commands.snapshot(), kind: "agent.turn.completed", agentKey: "codex", sessionId: sessionId
        ))
        let journalEventTime = try #require((journalCapture.draft["occurred_at_ms"] as? NSNumber)?.int64Value)
        #expect(
            journalEventTime > Int64(inheritedEventTime * 1000),
            "The monitor's journal replay must use its fresh sample, not the inherited start timestamp"
        )
        #expect(
            journalEventTime == Int64((replayEventTime * 1000).rounded()),
            "The journal and runtime watermark must share the monitor's captured replay time"
        )
        #expect(commands.snapshot().contains { $0.hasPrefix("set_status codex Idle ") })
    }
}
