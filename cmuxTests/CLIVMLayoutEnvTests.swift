import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Black-box coverage for `cmux vm layout export|apply` and `cmux vm env set|ls|rm`:
/// the real CLI binary runs against a mock control socket that plays the app's side of
/// `vm.exec`, `vm.env_set`, `layout.get`, `vm.tree`, and `vm.workspace_open`, so argument parsing,
/// local document validation (the JSON path in the error, zero socket traffic), the
/// base64 layout framing the in-VM shim consumes, the link-only env transport, dotenv parsing, saved-layout
/// wrapper detection, the outdated-shim guard, and the `--open` refresh/retry policy
/// are exercised exactly as an agent hits them. CLI-target code is not linked into
/// this bundle (see CLIVMTransferTests), so the static helpers are verified through
/// their observable command lines.
extension CLINotifyProcessIntegrationRegressionTests {
    /// Every decoded request the mock saw, in order, for assertions on method sequence
    /// and parameters (the raw `state` lines include the auth handshake).
    private final class VMLayoutEnvRequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [[String: Any]] = []

        func append(_ request: [String: Any]) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        func snapshot() -> [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        var methods: [String] { snapshot().compactMap { $0["method"] as? String } }

        func params(ofFirst method: String) -> [String: Any]? {
            snapshot().first { ($0["method"] as? String) == method }?["params"] as? [String: Any]
        }

        func commands() -> [String] {
            snapshot().compactMap { request in
                guard (request["method"] as? String) == "vm.exec" else { return nil }
                return (request["params"] as? [String: Any])?["command"] as? String
            }
        }
    }

    private final class VMLayoutEnvCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private func vmLayoutEnvExecResponse(id: String, stdout: String, stderr: String = "", exitCode: Int = 0) -> String {
        v2Response(id: id, ok: true, result: ["exit_code": exitCode, "stdout": stdout, "stderr": stderr])
    }

    /// The base64 body of a `printf %s '<b64>' | base64 -d | …` command.
    private static func base64Payload(inCommand command: String) -> Data? {
        guard let start = command.range(of: "printf %s '"),
              let end = command.range(of: "' | base64 -d | ") else { return nil }
        return Data(base64Encoded: String(command[start.upperBound..<end.lowerBound]))
    }

    private func vmLayoutEnvEnvironment(socketPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        return environment
    }

    private func vmLayoutEnvTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A mock that answers `vm.exec` through `onExec` and rejects every other method.
    private func startVMExecMock(
        listenerFD: Int32,
        state: MockSocketServerState,
        log: VMLayoutEnvRequestLog,
        onExec: @escaping @Sendable (_ id: String, _ command: String) -> String
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            log.append(request)
            guard method == "vm.exec",
                  let params = request["params"] as? [String: Any],
                  let command = params["command"] as? String else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            return onExec(id, command)
        }
    }

    private static let sampleLayoutNode: [String: Any] = [
        "direction": "horizontal",
        "split": 0.6,
        "children": [
            ["pane": ["surfaces": [["type": "terminal", "name": "agent", "command": "claude", "cwd": "work/app"]]]],
            [
                "direction": "vertical",
                "children": [
                    ["pane": ["surfaces": [["type": "terminal", "command": "bun test --watch"]]]],
                    ["pane": ["surfaces": [["type": "browser", "url": "http://localhost:3000"]]]],
                ],
            ],
        ],
    ]

    // MARK: - vm env

    private struct VMEnvProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    /// Like `runProcess`, with bytes on stdin — `cmux vm env set <m> -` reads assignments
    /// there so values never sit in the caller's argv or history.
    private func runProcessWithInput(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String,
        timeout: TimeInterval
    ) -> VMEnvProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return VMEnvProcessResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
        try? stdinPipe.fileHandleForWriting.close()
        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return VMEnvProcessResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    /// The app's side of `vm.env_set`: names back, never values. Any `vm.exec` is a test
    /// failure — values must not ride the control plane.
    private func startVMEnvSetMock(
        listenerFD: Int32,
        state: MockSocketServerState,
        log: VMLayoutEnvRequestLog
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            log.append(request)
            let params = (request["params"] as? [String: Any]) ?? [:]
            guard method == "vm.env_set",
                  let machine = params["id"] as? String,
                  let entries = params["entries"] as? [[String: Any]] else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            let keys = entries.compactMap { $0["key"] as? String }
            return self.v2Response(id: id, ok: true, result: [
                "machine": machine, "keys": keys, "count": keys.count, "path": "/root/.config/cmux/env",
            ])
        }
    }

    /// `KEY=VALUE` per entry of the first `vm.env_set` the mock saw, in request order.
    private func vmEnvSetEntryLines(_ log: VMLayoutEnvRequestLog) -> [String] {
        let entries = (log.params(ofFirst: "vm.env_set")?["entries"] as? [[String: Any]]) ?? []
        return entries.map { "\(($0["key"] as? String) ?? "?")=\(($0["value"] as? String) ?? "?")" }
    }

    func testVMEnvSetDeliversEntriesOverTheMachineLinkNeverExec() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-env-set")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let serverHandled = startVMEnvSetMock(listenerFD: listenerFD, state: state, log: log)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "env", "set", "brave-otter", "A=1", "B=x y"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        // One request, the link-backed method, typed entries — and no exec anywhere.
        XCTAssertEqual(log.methods, ["vm.env_set"], log.methods.description)
        XCTAssertEqual(log.params(ofFirst: "vm.env_set")?["id"] as? String, "brave-otter")
        XCTAssertEqual(vmEnvSetEntryLines(log), ["A=1", "B=x y"])
        XCTAssertTrue(log.commands().isEmpty, "values must never ride vm.exec: \(log.commands())")
        // Values are secrets: the summary names keys only.
        XCTAssertTrue(result.stdout.contains("OK set 2 variables on brave-otter: A, B"), result.stdout)
        XCTAssertFalse(result.stdout.contains("x y"), result.stdout)
    }

    func testVMEnvSetReadsDotenvFilesAndStdinLiterally() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-env-file")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let tempDir = try vmLayoutEnvTempDir("env-file")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let envFile = tempDir.appendingPathComponent("dev.env")
        try """
        # database
        export DATABASE_URL="postgres://localhost/app"

        TOKEN='abc def'
        PLAIN=hello # trailing comment
        QUOTED_LITERAL="keep" # trailing comment
        SPACEY="  padded  "
        EMPTY=
        """.write(to: envFile, atomically: true, encoding: .utf8)

        let serverHandled = startVMEnvSetMock(listenerFD: listenerFD, state: state, log: log)

        let result = runProcessWithInput(
            executablePath: cliPath,
            arguments: ["vm", "env", "set", "brave-otter", "--from-file", envFile.path, "PLAIN=argv", "Q='x'", "-", "FROM_STDIN=argv-after-stdin"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            standardInput: "FROM_STDIN=\"two words\"\n# ignored\nexport SECOND=2\n",
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods, ["vm.env_set"], log.methods.description)
        // dotenv rules applied on the Mac (comments, `export`, matching quotes, inline
        // comment); every value reaches the app byte for byte, quotes and padding included.
        XCTAssertEqual(vmEnvSetEntryLines(log), [
            "DATABASE_URL=postgres://localhost/app",
            "TOKEN=abc def",
            "PLAIN=argv",
            "QUOTED_LITERAL=keep",
            "SPACEY=  padded  ",
            "EMPTY=",
            "Q='x'",
            "FROM_STDIN=argv-after-stdin",
            "SECOND=2",
        ])
        XCTAssertTrue(result.stdout.contains("OK set 9 variables on brave-otter"), result.stdout)
        XCTAssertFalse(result.stdout.contains("postgres://"), "values never echo back: \(result.stdout)")
    }

    func testVMEnvSetRejectsInvalidKeysWithoutTouchingTheSocket() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-env-bad")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "env", "set", "brave-otter", "1BAD=value"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )

        XCTAssertEqual(result.status, 2, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(result.stderr.contains("invalid variable name '1BAD'"), result.stderr)
        var connection = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(Darwin.poll(&connection, 1, 0), 0, "a rejected assignment must not connect to the socket")
    }

    func testVMEnvListForwardsFlagsAndPrintsStdoutVerbatim() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-env-ls")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let listing = "{\"path\":\"/root/.config/cmux/env\",\"keys\":[\"A\",\"B\"]}\n"
        let serverHandled = startVMExecMock(listenerFD: listenerFD, state: state, log: log) { id, _ in
            self.vmLayoutEnvExecResponse(id: id, stdout: listing)
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "env", "ls", "brave-otter", "--json"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.commands(), ["cmux env ls --json"])
        XCTAssertEqual(result.stdout, listing, "the shim's listing is printed byte for byte")
    }

    func testVMEnvRemoveForwardsKeys() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-env-rm")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let serverHandled = startVMExecMock(listenerFD: listenerFD, state: state, log: log) { id, _ in
            self.vmLayoutEnvExecResponse(id: id, stdout: "")
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "env", "rm", "brave-otter", "A", "DATABASE_URL"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.commands(), ["cmux env rm A DATABASE_URL"])
        XCTAssertTrue(result.stdout.contains("OK removed 2 variables on brave-otter: A, DATABASE_URL"), result.stdout)
    }

    // MARK: - vm layout

    func testVMLayoutExportForwardsWorkspaceAndRawAndPrintsJSON() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-layout-export")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let exported = "{\"version\":1,\"screen_id\":\"screen_1\",\"root\":{\"kind\":\"leaf\",\"pane_id\":\"pane_1\",\"tab_ids\":[]}}\n"
        let serverHandled = startVMExecMock(listenerFD: listenerFD, state: state, log: log) { id, _ in
            self.vmLayoutEnvExecResponse(id: id, stdout: exported)
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "layout", "export", "brave-otter", "ws_1", "--raw"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.commands(), ["cmux layout export --json --workspace ws_1 --raw"])
        XCTAssertEqual(result.stdout, exported)
        let timeout = try XCTUnwrap(log.params(ofFirst: "vm.exec")?["timeout_ms"] as? Int)
        XCTAssertGreaterThanOrEqual(timeout, 30_000)
    }

    func testVMLayoutApplySendsTheDocumentAndForwardsTargetFlags() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-layout-apply")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let tempDir = try vmLayoutEnvTempDir("layout-apply")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let layoutFile = tempDir.appendingPathComponent("dev.json")
        let documentBytes = try JSONSerialization.data(withJSONObject: Self.sampleLayoutNode, options: [.sortedKeys])
        try documentBytes.write(to: layoutFile)

        let applied = """
        {"workspace_id":"ws_1","workspace_name":"dev","panes":[{"pane_id":"pane_1","surfaces":[{"type":"terminal","terminal_id":"term_1","tab_id":"tab_1"}]},{"pane_id":"pane_2","surfaces":[{"type":"terminal","terminal_id":"term_2","tab_id":"tab_2"}]},{"pane_id":"pane_3","surfaces":[{"type":"browser","browser_id":"browser_1","tab_id":"tab_3"}]}],"warnings":["project surfaces are Mac-only; skipped 0"]}

        """
        let serverHandled = startVMExecMock(listenerFD: listenerFD, state: state, log: log) { id, _ in
            self.vmLayoutEnvExecResponse(id: id, stdout: applied)
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "layout", "apply", "brave-otter", layoutFile.path, "--workspace", "ws_1", "--name", "dev"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods, ["vm.exec"], "no open without --open")
        let command = try XCTUnwrap(log.commands().first)
        XCTAssertTrue(command.hasSuffix("| base64 -d | cmux layout apply --json --workspace ws_1 --name dev -"), command)
        XCTAssertEqual(Self.base64Payload(inCommand: command), documentBytes, "the file travels byte for byte")
        XCTAssertTrue(result.stdout.contains("OK workspace=ws_1 name=dev panes=3 surfaces=3 machine=brave-otter"), result.stdout)
        XCTAssertTrue(result.stdout.contains("cmux vm workspace open brave-otter ws_1"), "hint names the manual open: \(result.stdout)")
        XCTAssertTrue(result.stderr.contains("warning: project surfaces are Mac-only"), result.stderr)
    }

    func testVMLayoutApplyFromSavedLayoutRefreshesRetriesAndOpens() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-layout-open")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        let openAttempts = VMLayoutEnvCounter()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let localWorkspaceID = UUID().uuidString

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            log.append(request)
            let params = (request["params"] as? [String: Any]) ?? [:]
            switch method {
            case "layout.get":
                guard (params["name"] as? String) == "dev" else {
                    return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "Layout not found"])
                }
                // What `cmux layout get dev` returns: the saved-layout wrapper.
                let saved: [String: Any] = [
                    "name": "dev",
                    "description": "agent left, tests right",
                    "workspace": ["cwd": "~/src/app", "layout": Self.sampleLayoutNode],
                ]
                return self.v2Response(id: id, ok: true, result: saved)
            case "vm.exec":
                return self.vmLayoutEnvExecResponse(
                    id: id,
                    stdout: "{\"workspace_id\":\"ws_9\",\"workspace_name\":\"dev\",\"panes\":[{\"pane_id\":\"pane_1\",\"surfaces\":[{\"type\":\"terminal\",\"terminal_id\":\"term_1\",\"tab_id\":\"tab_1\"}]}],\"warnings\":[]}\n"
                )
            case "vm.tree":
                return self.v2Response(id: id, ok: true, result: ["machines": [], "resources": [], "projections": []])
            case "vm.workspace_open":
                // The catalog has not seen the new workspace on the first try.
                if openAttempts.next() == 1 {
                    return self.v2Response(id: id, ok: false, error: ["code": "not_ready", "message": "Nothing to open: workspace ws_9 is empty."])
                }
                return self.v2Response(id: id, ok: true, result: [
                    "machine": "brave-otter",
                    "remote_workspace_id": "ws_9",
                    "remote_workspace_name": "dev",
                    "workspace_id": localWorkspaceID,
                    "surface_ids": [UUID().uuidString],
                    "opened": 1,
                    "here": false,
                ])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "layout", "apply", "brave-otter", "--from-saved", "dev", "--open"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 45
        )

        wait(for: [serverHandled], timeout: 45)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(
            log.methods,
            ["layout.get", "vm.exec", "vm.tree", "vm.workspace_open", "vm.workspace_open"],
            "saved layout read locally, applied, catalog refreshed, then opened (one not-found retry)"
        )

        // The wrapper is forwarded as-is: the shim reads `workspace.layout` itself.
        let command = try XCTUnwrap(log.commands().first)
        XCTAssertTrue(command.hasSuffix("| base64 -d | cmux layout apply --json -"), command)
        let forwarded = try XCTUnwrap(Self.base64Payload(inCommand: command))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: forwarded) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "dev")
        let workspace = try XCTUnwrap(object["workspace"] as? [String: Any])
        XCTAssertEqual(workspace["cwd"] as? String, "~/src/app")
        XCTAssertNotNil(workspace["layout"] as? [String: Any])

        let refresh = try XCTUnwrap(log.params(ofFirst: "vm.tree"))
        XCTAssertEqual(refresh["id"] as? String, "brave-otter")
        XCTAssertEqual(refresh["refresh"] as? Bool, true)
        let open = try XCTUnwrap(log.params(ofFirst: "vm.workspace_open"))
        XCTAssertEqual(open["id"] as? String, "brave-otter")
        XCTAssertEqual(open["workspace_id"] as? String, "ws_9")

        XCTAssertTrue(result.stdout.contains("OK workspace=ws_9 name=dev panes=1 surfaces=1 machine=brave-otter"), result.stdout)
        XCTAssertTrue(result.stdout.contains("OK opened workspace=\(localWorkspaceID) opened=1 machine=brave-otter"), result.stdout)
    }

    func testVMLayoutApplyOpenGivesUpWithTheManualCommand() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-layout-open-fail")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let tempDir = try vmLayoutEnvTempDir("layout-open-fail")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let layoutFile = tempDir.appendingPathComponent("one.json")
        try JSONSerialization.data(withJSONObject: ["pane": ["surfaces": [["type": "terminal"]]]]).write(to: layoutFile)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            log.append(request)
            switch method {
            case "vm.exec":
                return self.vmLayoutEnvExecResponse(id: id, stdout: "{\"workspace_id\":\"ws_7\",\"workspace_name\":\"one\",\"panes\":[],\"warnings\":[]}\n")
            case "vm.tree":
                return self.v2Response(id: id, ok: true, result: ["machines": [], "resources": [], "projections": []])
            case "vm.workspace_open":
                // The Mac keeps seeing it as empty: every attempt says so.
                return self.v2Response(id: id, ok: true, result: ["machine": "brave-otter", "remote_workspace_id": "ws_7", "opened": 0, "empty": true])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "layout", "apply", "brave-otter", layoutFile.path, "--open"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 60
        )

        wait(for: [serverHandled], timeout: 60)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods.filter { $0 == "vm.workspace_open" }.count, 5, "five attempts, one second apart: \(log.methods)")
        XCTAssertTrue(result.stderr.contains("ws_7"), result.stderr)
        XCTAssertTrue(result.stderr.contains("cmux vm workspace open brave-otter ws_7"), result.stderr)
    }

    func testVMLayoutApplyRejectsInvalidDocumentsBeforeTouchingTheMachine() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-layout-invalid")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let tempDir = try vmLayoutEnvTempDir("layout-invalid")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cases: [(name: String, document: Any, expectedPath: String, expectedReason: String)] = [
            (
                "one-child",
                ["direction": "horizontal", "children": [["pane": ["surfaces": [["type": "terminal"]]]]]],
                "$.children",
                "exactly 2 children"
            ),
            (
                "nested-bad-type",
                [
                    "layout": [
                        "direction": "vertical",
                        "children": [
                            ["pane": ["surfaces": [["type": "terminal"]]]],
                            ["pane": ["surfaces": [["type": "tmux"]]]],
                        ],
                    ],
                ],
                "$.layout.children[1].pane.surfaces[0].type",
                "'type' must be"
            ),
            (
                "both-keys",
                ["pane": ["surfaces": [["type": "terminal"]]], "direction": "horizontal", "children": []],
                "$",
                "both 'pane' and 'direction'"
            ),
            (
                "no-layout",
                ["name": "dev", "workspace": ["cwd": "~"]],
                "$",
                "no layout found"
            ),
            (
                "empty-surfaces",
                ["workspace": ["layout": ["pane": ["surfaces": []]]]],
                "$.workspace.layout.pane.surfaces",
                "non-empty array"
            ),
        ]

        for testCase in cases {
            let file = tempDir.appendingPathComponent("\(testCase.name).json")
            try JSONSerialization.data(withJSONObject: testCase.document).write(to: file)
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["vm", "layout", "apply", "brave-otter", file.path],
                environment: vmLayoutEnvEnvironment(socketPath: socketPath),
                timeout: 30
            )
            XCTAssertEqual(result.status, 2, "\(testCase.name): stdout=\(result.stdout) stderr=\(result.stderr)")
            XCTAssertTrue(result.stderr.contains("invalid layout document"), "\(testCase.name): \(result.stderr)")
            XCTAssertTrue(result.stderr.contains(" at \(testCase.expectedPath)"), "\(testCase.name) names the path: \(result.stderr)")
            XCTAssertTrue(result.stderr.contains(testCase.expectedReason), "\(testCase.name) says why: \(result.stderr)")
        }

        let notJSON = tempDir.appendingPathComponent("not.json")
        try Data("{".utf8).write(to: notJSON)
        let broken = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "layout", "apply", "brave-otter", notJSON.path],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )
        XCTAssertEqual(broken.status, 2, broken.stderr)
        XCTAssertTrue(broken.stderr.contains("not valid JSON at $"), broken.stderr)

        let conflict = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "layout", "apply", "brave-otter", "--from-saved", "must-not-be-read", "--workspace", "ws_empty", "--name", "conflict"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 5
        )
        XCTAssertEqual(conflict.status, 2, conflict.stderr)
        var connection = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(Darwin.poll(&connection, 1, 0), 0, "invalid documents and targets must not connect to the socket")
    }

    func testVMLayoutApplyExplainsAnOutdatedShim() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-layout-old-shim")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let tempDir = try vmLayoutEnvTempDir("layout-old-shim")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let layoutFile = tempDir.appendingPathComponent("one.json")
        try JSONSerialization.data(withJSONObject: ["pane": ["surfaces": [["type": "terminal"]]]]).write(to: layoutFile)

        // An old shim knows no `layout` word and falls through to cmux-tui, which
        // rejects the resource scope.
        let serverHandled = startVMExecMock(listenerFD: listenerFD, state: state, log: log) { id, _ in
            self.vmLayoutEnvExecResponse(id: id, stdout: "", stderr: "error: unknown resource scope \"layout\"\n", exitCode: 2)
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "layout", "apply", "brave-otter", layoutFile.path],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertNotEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(result.stderr.contains("predates layout support"), result.stderr)
        XCTAssertTrue(result.stderr.contains("cmux vm tree brave-otter --refresh"), result.stderr)
    }
}
