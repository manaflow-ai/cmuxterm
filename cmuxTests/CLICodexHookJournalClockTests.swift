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
    func installedSynchronousHooksReserveDistinctJournalMilliseconds() throws {
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
        for _ in 0..<2 {
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
        }
        let values = try String(contentsOf: captureFile, encoding: .utf8)
            .split(separator: "\n").compactMap { Double($0) }
        #expect(values.count == 2)
        let ticks = values.map { Int64(($0 * 1_000_000).rounded()) }
        #expect(ticks == [(seed / 1000 + 1) * 1000, (seed / 1000 + 2) * 1000])
    }
}
