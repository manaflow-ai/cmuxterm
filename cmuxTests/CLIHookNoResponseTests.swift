import Darwin
import Foundation
import Testing

@Suite("CLI hook no-response telemetry", .serialized)
struct CLIHookNoResponseTests {
    final class BundleProbe {}

    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            let value = commands
            lock.unlock()
            return value
        }
    }

    struct MockSocketServer {
        let handled: DispatchSemaphore

        func wait(timeout: TimeInterval) -> Bool {
            handled.wait(timeout: .now() + timeout) == .success
        }
    }

    struct FeedHookCase {
        let source: String
        let event: String
        let toolName: String
        let pidKey: String
    }

    @Test func nonActionableFeedHooksDoNotWaitForSocketResponseAcrossAgents() throws {
        let cases = [
            FeedHookCase(source: "codex", event: "PreToolUse", toolName: "apply_patch", pidKey: "CMUX_CODEX_PID"),
            FeedHookCase(source: "gemini", event: "PreToolUse", toolName: "read", pidKey: "CMUX_GEMINI_PID"),
            FeedHookCase(source: "kiro", event: "postToolUse", toolName: "fs_write", pidKey: "CMUX_KIRO_PID"),
            FeedHookCase(source: "hermes-agent", event: "pre_tool_call", toolName: "terminal", pidKey: "CMUX_HERMES_AGENT_PID"),
            FeedHookCase(source: "antigravity", event: "PreToolUse", toolName: "Bash", pidKey: "CMUX_ANTIGRAVITY_PID"),
            FeedHookCase(source: "antigravity", event: "PostToolUse", toolName: "run_command", pidKey: "CMUX_ANTIGRAVITY_PID"),
            FeedHookCase(
                source: "cursor",
                event: "preToolUse",
                toolName: "Shell",
                pidKey: "CMUX_CURSOR_PID"
            ),
        ]

        for testCase in cases {
            let cliPath = try Self.bundledCLIPath()
            let socketPath = Self.makeSocketPath("feed-no-reply-\(testCase.source.prefix(6))")
            let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 1)
            let state = MockSocketServerState()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-feed-no-reply-\(testCase.source)-\(UUID().uuidString)", isDirectory: true)

            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }

            let server = Self.startMockServerAllowingNoResponse(
                listenerFD: listenerFD,
                state: state,
                fulfillWhen: { line in
                    Self.jsonObject(line)?["method"] as? String == "feed.push"
                }
            ) { line in
                guard let payload = Self.jsonObject(line),
                      payload["method"] as? String == "feed.push" else {
                    return Self.malformedRequestResponse(raw: line)
                }
                return nil
            }

            var environment = [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
                "CMUX_SURFACE_ID": "44444444-4444-4444-4444-444444444444",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
            environment[testCase.pidKey] = "626262"

            let toolInput = testCase.source == "cursor"
                ? ["command": "printf cursor-hook"]
                : [
                    "path": root.appendingPathComponent("README.md").path
                ]
            let inputObject: [String: Any] = [
                "hook_event_name": testCase.event,
                "session_id": "\(testCase.source)-session-123",
                "cwd": root.path,
                "tool_name": testCase.toolName,
                "tool_use_id": "\(testCase.source)-tool-use",
                "tool_input": toolInput,
            ]
            let inputData = try JSONSerialization.data(
                withJSONObject: inputObject,
                options: [.sortedKeys]
            )
            let input = try #require(
                String(data: inputData, encoding: .utf8)
            )
            let result = Self.runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "feed", "--source", testCase.source, "--event", testCase.event],
                environment: environment,
                standardInput: input,
                timeout: 0.5
            )

            #expect(server.wait(timeout: 5), "\(testCase.source): socket server did not observe feed.push")
            #expect(!result.timedOut, "\(testCase.source): \(result.stderr)")
            #expect(result.status == 0, "\(testCase.source): \(result.stderr)")
            #expect(result.stdout == "{}\n")
            #expect(state.snapshot().filter { $0.contains(#""method":"feed.push""#) }.count == 1)
        }
    }

    @Test func genericLifecycleFeedTelemetryDoesNotWaitForSocketResponse() throws {
        let cliPath = try Self.bundledCLIPath()
        let socketPath = Self.makeSocketPath("generic-lifecycle-no-response")
        let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 8)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-kiro-lifecycle-no-response-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let surfaceId = "44444444-4444-4444-4444-444444444444"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let server = Self.startMultiConnectionMockServerAllowingNoResponse(
            listenerFD: listenerFD,
            state: state,
            connectionLimit: 8,
            fulfillWhen: { line in
                Self.jsonObject(line)?["method"] as? String == "feed.push"
            }
        ) { line in
            guard let payload = Self.jsonObject(line) else {
                return "OK"
            }
            guard let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            if method == "feed.push" {
                return nil
            }
            guard let id = payload["id"] as? String else {
                return Self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return Self.surfaceListResponse(id: id, surfaceId: surfaceId)
            case "surface.resume.set":
                return Self.v2Response(id: id, ok: true, result: ["ok": true])
            default:
                return Self.v2Response(id: id, ok: false, error: [
                    "code": "unrecognized_method",
                    "message": "unexpected method: \(method)",
                ])
            }
        }

        let result = Self.runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "kiro", "session-start"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_AGENT_LAUNCH_KIND": "kiro",
                "CMUX_AGENT_LAUNCH_EXECUTABLE": "/Users/example/.cargo/bin/kiro-cli",
                "CMUX_AGENT_LAUNCH_ARGV_B64": Self.base64NULSeparated([
                    "/Users/example/.cargo/bin/kiro-cli",
                    "chat",
                    "--agent",
                    "cmux",
                    "--resume-id",
                    "old-session",
                ]),
                "CMUX_AGENT_LAUNCH_CWD": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_SOCKET_PASSWORD": "test-password",
            ],
            standardInput: #"{"session_id":"kiro-lifecycle-no-response","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 1.0
        )

        #expect(server.wait(timeout: 5), "socket server did not observe lifecycle feed.push")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(
            state.snapshot().contains { $0.contains(#""method":"feed.push""#) },
            "Expected lifecycle hook to still emit Feed telemetry"
        )
    }

    @Test func nonActionableFeedHookDoesNotBlockWhenAcceptedSocketStopsReading() throws {
        let cliPath = try Self.bundledCLIPath()
        let socketPath = Self.makeSocketPath("feed-no-read")
        let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 1)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-feed-no-read-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let server = try Self.startAcceptedSocketThatDoesNotRead(listenerFD: listenerFD, holdFor: 1.0)
        // Stay under the CLI's 1 MiB codex feed-hook stdin cap so the payload still
        // reaches the socket, but far above what the non-reading peer will absorb
        // (the fixture pins its receive buffer to 4 KiB) so the write stalls and has
        // to be abandoned by the 0.05s write timeout.
        let largeToolInput = String(repeating: "x", count: 512 * 1024)
        let input = """
        {"hook_event_name":"PreToolUse","session_id":"codex-session-no-read","cwd":"\(root.path)","tool_name":"apply_patch","tool_input":{"payload":"\(largeToolInput)"}}
        """

        let result = Self.runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "feed", "--source", "codex", "--event", "PreToolUse"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
                "CMUX_SURFACE_ID": "44444444-4444-4444-4444-444444444444",
                "CMUX_CODEX_PID": "626262",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: input,
            timeout: 0.5
        )

        #expect(server.wait(timeout: 5), "socket server did not accept feed.push connection")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
    }

    @Test func oversizedFeedHookReturnsWithoutWaitingForStandardInputEOF() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try Self.bundledCLIPath())
        process.arguments = [
            "hooks", "feed", "--source", "codex", "--event", "PostToolUse",
        ]
        process.environment = [
            "HOME": FileManager.default.temporaryDirectory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        try stdin.fileHandleForReading.close()
        let writerFD = stdin.fileHandleForWriting.fileDescriptor
        guard fcntl(writerFD, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                _ = finished.wait(timeout: .now() + 1)
            }
        }

        try stdin.fileHandleForWriting.write(
            contentsOf: Data(repeating: 0x78, count: 1 * 1024 * 1024 + 1)
        )
        let returnedBeforeEOF = finished.wait(timeout: .now() + 2) == .success
        var producerAcceptedAdditionalInput = false
        var additionalWriteError = ""
        if returnedBeforeEOF {
            do {
                try stdin.fileHandleForWriting.write(contentsOf: Data("more".utf8))
                producerAcceptedAdditionalInput = true
            } catch {
                additionalWriteError = String(describing: error)
            }
        }
        try? stdin.fileHandleForWriting.close()
        if !returnedBeforeEOF {
            if finished.wait(timeout: .now() + 1) != .success,
               process.isRunning {
                process.terminate()
                _ = finished.wait(timeout: .now() + 1)
            }
        }

        let standardOutput = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let standardError = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(
            returnedBeforeEOF,
            "An oversized untrusted hook payload must not keep the CLI blocked until its producer closes stdin."
        )
        #expect(
            producerAcceptedAdditionalInput,
            "The detached oversized-input drainer must keep accepting producer bytes after the CLI exits: \(additionalWriteError)"
        )
        #expect(process.terminationStatus == 0, Comment(rawValue: standardError))
        #expect(standardOutput == "{}\n")
    }

}
