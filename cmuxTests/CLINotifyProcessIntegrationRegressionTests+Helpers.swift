import XCTest
import Darwin
#if canImport(cmux_DEV)

extension CLINotifyProcessIntegrationRegressionTests {
    func assertSSHPTYAttachAuthUsesRetryLoop(
        _ script: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            script.contains("cmux_ssh_attach_foreground_auth"),
            "missing cmux_ssh_attach_foreground_auth: \(script)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            script.contains("CMUX_SSH_PTY_ATTACH_MANAGED_RECONNECT=1"),
            "missing CMUX_SSH_PTY_ATTACH_MANAGED_RECONNECT=1: \(script)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            script.contains("CMUX_SSH_PTY_ATTACH_SUPPRESS_REPLAY"),
            "missing CMUX_SSH_PTY_ATTACH_SUPPRESS_REPLAY: \(script)",
            file: file,
            line: line
        )
        XCTAssertFalse(
            script.contains("[cmux] ssh exited with status"),
            "legacy exit-status message still present: \(script)",
            file: file,
            line: line
        )
    }

    func assertSSHPersistentPTYUsesReusableForegroundAuthControlConnection(
        run: MockedSSHRun,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let createParams = try XCTUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try XCTUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let initialCommand = try XCTUnwrap(createParams["initial_command"] as? String)
        let terminalStartupCommand = try XCTUnwrap(configureParams["terminal_startup_command"] as? String)
        let initialScript = try XCTUnwrap(decodedReusableStartupScript(from: initialCommand))
        let terminalStartupScript = try XCTUnwrap(decodedReusableStartupScript(from: terminalStartupCommand))
        XCTAssertTrue(initialScript.contains("ssh-pty-attach"), initialScript)
        XCTAssertTrue(initialScript.contains("--wait"), initialScript)
        XCTAssertTrue(initialScript.contains("ssh-session-end") && initialScript.contains("--lifecycle-only"), initialScript)
        XCTAssertTrue(initialScript.contains("CMUX_WORKSPACE_ID"), initialScript)
        XCTAssertTrue(initialScript.contains("CMUX_SURFACE_ID"), initialScript)
        XCTAssertTrue(
            initialScript.contains("required workspace context missing for SSH PTY attach"),
            initialScript
        )
        XCTAssertTrue(
            initialScript.contains("required terminal context missing for SSH PTY attach"),
            initialScript
        )
        XCTAssertTrue(
            initialScript.contains("CMUX_SSH_PTY_SESSION_ID=\"ssh-${CMUX_WORKSPACE_ID:-}-${CMUX_SURFACE_ID:-}\""),
            initialScript
        )
        XCTAssertTrue(initialScript.contains("cmux_ssh_attach_session_id=\"${CMUX_SSH_PTY_SESSION_ID:-}\""), initialScript)
        XCTAssertTrue(initialScript.contains("--session-id \"$cmux_ssh_attach_session_id\""), initialScript)
        XCTAssertTrue(initialScript.contains("--lifecycle-id \"$cmux_ssh_attach_lifecycle_id\""), initialScript)
        assertSSHPTYAttachAuthUsesRetryLoop(initialScript)
        assertSSHPTYAttachOmitsSurfaceArgument(initialScript)
        XCTAssertTrue(
            initialScript.contains("--workspace \"$CMUX_WORKSPACE_ID\""),
            initialScript
        )
        XCTAssertEqual(initialScript.components(separatedBy: "workspace.remote.foreground_auth_ready").count - 1, 2, initialScript)
        XCTAssertTrue(terminalStartupScript.contains("ssh-pty-attach"), terminalStartupScript)
        XCTAssertTrue(terminalStartupScript.contains("ssh-session-end") && terminalStartupScript.contains("--lifecycle-only"), terminalStartupScript)
        XCTAssertTrue(terminalStartupScript.contains("CMUX_WORKSPACE_ID"), terminalStartupScript)
        XCTAssertTrue(terminalStartupScript.contains("CMUX_SURFACE_ID"), terminalStartupScript)
        XCTAssertTrue(
            terminalStartupScript.contains("required workspace context missing for SSH PTY attach"),
            terminalStartupScript
        )
        XCTAssertTrue(
            terminalStartupScript.contains("required terminal context missing for SSH PTY attach"),
            terminalStartupScript
        )
        XCTAssertTrue(
            terminalStartupScript.contains("CMUX_SSH_PTY_SESSION_ID=\"ssh-${CMUX_WORKSPACE_ID:-}-${CMUX_SURFACE_ID:-}\""),
            terminalStartupScript
        )
        XCTAssertTrue(terminalStartupScript.contains("cmux_ssh_attach_session_id=\"${CMUX_SSH_PTY_SESSION_ID:-}\""), terminalStartupScript)
        XCTAssertTrue(terminalStartupScript.contains("--session-id \"$cmux_ssh_attach_session_id\""), terminalStartupScript)
        XCTAssertTrue(terminalStartupScript.contains("--lifecycle-id \"$cmux_ssh_attach_lifecycle_id\""), terminalStartupScript)
        assertSSHPTYAttachAuthUsesRetryLoop(terminalStartupScript)
        assertSSHPTYAttachOmitsSurfaceArgument(terminalStartupScript)
        XCTAssertTrue(
            terminalStartupScript.contains("--workspace \"$CMUX_WORKSPACE_ID\""),
            terminalStartupScript
        )
        XCTAssertEqual(terminalStartupScript.components(separatedBy: "workspace.remote.foreground_auth_ready").count - 1, 2, terminalStartupScript)
        XCTAssertEqual(configureParams["auto_connect"] as? Bool, false)
        XCTAssertNotNil(configureParams["foreground_auth_token"] as? String)
        XCTAssertEqual(configureParams["preserve_after_terminal_exit"] as? Bool, true)
        let persistentDaemonSlot = try XCTUnwrap(configureParams["persistent_daemon_slot"] as? String)
        XCTAssertTrue(persistentDaemonSlot.hasPrefix("ssh-"), persistentDaemonSlot)
        XCTAssertNotNil(UUID(uuidString: String(persistentDaemonSlot.dropFirst(4))))
    }

    struct ClaudeHookContext {
        let cliPath: String
        let socketPath: String
        let listenerFD: Int32
        let state: MockSocketServerState
        let root: URL
        let workspaceId: String
        let surfaceId: String

        func cleanup() {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
    }

    func codexLaunchEnvironment(context: ClaudeHookContext, sessionId: String) -> [String: String] {
        agentLaunchEnvironment(
            context: context,
            kind: "codex",
            executable: "/usr/local/bin/codex",
            arguments: ["/usr/local/bin/codex", "--model", "gpt-5.4"]
        )
    }

    func agentLaunchEnvironment(
        context: ClaudeHookContext,
        kind: String,
        executable: String,
        arguments: [String]? = nil
    ) -> [String: String] {
        [
            "CMUX_AGENT_LAUNCH_KIND": kind,
            "CMUX_AGENT_LAUNCH_EXECUTABLE": executable,
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(arguments ?? [executable]),
        ]
    }

    func writeCodexTerminalTranscript(
        context: ClaudeHookContext,
        name: String,
        turnId: String,
        eventType: String = "turn_complete"
    ) throws -> URL {
        let transcriptURL = context.root.appendingPathComponent(name)
        try [
            #"{"type":"turn_context","payload":{"turn_id":"\#(turnId)"}}"#,
            #"{"type":"event_msg","payload":{"type":"\#(eventType)","turn_id":"\#(turnId)"}}"#,
        ].joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        return transcriptURL
    }

    func runCodexHook(
        context: ClaudeHookContext,
        subcommand: String,
        standardInput: String,
        extraEnvironment: [String: String] = [:]
    ) -> ProcessRunResult {
        runAgentHook(
            context: context,
            agent: "codex",
            subcommand: subcommand,
            standardInput: standardInput,
            extraEnvironment: extraEnvironment
        )
    }

    func runAgentHook(
        context: ClaudeHookContext,
        agent: String,
        subcommand: String,
        standardInput: String,
        extraEnvironment: [String: String] = [:]
    ) -> ProcessRunResult {
        return runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", agent, subcommand],
            environment: agentHookEnvironment(
                context: context,
                extraEnvironment: extraEnvironment
            ),
            standardInput: standardInput,
            timeout: 5
        )
    }

    func runFeedHook(
        context: ClaudeHookContext,
        source: String,
        event: String,
        standardInput: String,
        extraEnvironment: [String: String] = [:]
    ) -> ProcessRunResult {
        runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "feed", "--source", source, "--event", event],
            environment: agentHookEnvironment(
                context: context,
                extraEnvironment: extraEnvironment
            ),
            standardInput: standardInput,
            timeout: 5
        )
    }

    func agentHookEnvironment(
        context: ClaudeHookContext,
        extraEnvironment: [String: String]
    ) -> [String: String] {
        var environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": context.root.path,
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": context.root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        environment.merge(extraEnvironment, uniquingKeysWith: { _, new in new })
        return environment
    }

    /// Serves this context's agent-hook mock socket for the rest of the test. One
    /// accept loop answers every connection, including the CLI's extra `system.top`
    /// lookup connection, and the registry reaps the loop at teardown.
    func startAgentHookMockServerAccepting(context: ClaudeHookContext) {
        let state = context.state
        let mockResponse: @Sendable (String) -> String = { line in
            self.agentHookMockResponse(line: line, context: context)
        }
        CLIMockAcceptLoopRegistry.shared.start(listenerFD: context.listenerFD, onConnection: { clientFD in
            defer { Darwin.close(clientFD) }
            cliMockServeLineFramedConnection(clientFD: clientFD) { line in
                state.append(line)
                return mockResponse(line)
            }
        }, onListenerClosed: {})
    }

    func agentHookMockResponse(line: String, context: ClaudeHookContext) -> String {
        guard let payload = jsonObject(line) else {
            return "OK"
        }
        guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
            return malformedRequestResponse(id: payload["id"] as? String, raw: line)
        }
        switch method {
        case "surface.list":
            return surfaceListResponse(id: id, surfaceId: context.surfaceId)
        case "feed.push":
            return v2Response(id: id, ok: true, result: [:])
        case "surface.resume.set":
            return v2Response(id: id, ok: true, result: ["resume_binding": [:]])
        case "surface.resume.clear":
            return v2Response(id: id, ok: true, result: ["cleared": true])
        default:
            return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }
    }

    func makeClaudeHookContext(name: String) throws -> ClaudeHookContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(name)-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeSocketPath(String(name.prefix(6)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ClaudeHookContext(
            cliPath: try bundledCLIPath(),
            socketPath: socketPath,
            listenerFD: try bindUnixSocket(at: socketPath),
            state: MockSocketServerState(),
            root: root,
            workspaceId: "11111111-1111-1111-1111-111111111111",
            surfaceId: "22222222-2222-2222-2222-222222222222"
        )
    }

    func runClaudeHook(
        context: ClaudeHookContext,
        arguments: [String],
        standardInput: String,
        extraEnvironment: [String: String] = [:]
    ) -> ProcessRunResult {
        let serverHandled = startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = self.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: context.surfaceId)
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            case "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["cleared": true])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_CLAUDE_HOOK_STATE_PATH": context.root.appendingPathComponent("claude-hook-sessions.json").path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
        ]
        for (key, value) in extraEnvironment {
            environment[key] = value
        }

        let result = runProcess(
            executablePath: context.cliPath,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            timeout: 5
        )
        wait(for: [serverHandled], timeout: 5)
        return result
    }

    func readClaudeHookSession(_ sessionId: String, context: ClaudeHookContext) throws -> [String: Any] {
        let stateURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let sessions = try XCTUnwrap(state["sessions"] as? [String: Any])
        return try XCTUnwrap(sessions[sessionId] as? [String: Any])
    }

    func feedPushEvents(in context: ClaudeHookContext) -> [[String: Any]] {
        context.state.snapshot().compactMap { line in
            guard let payload = jsonObject(line),
                  payload["method"] as? String == "feed.push",
                  let params = payload["params"] as? [String: Any],
                  let event = params["event"] as? [String: Any] else {
                return nil
            }
            return event
        }
    }

}
