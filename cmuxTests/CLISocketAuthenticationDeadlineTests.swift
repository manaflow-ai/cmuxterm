import CmuxSettings
import Darwin
import Foundation
import Testing

/// Exercises authentication framing through the shipped CLI and real Unix sockets.
struct CLISocketAuthenticationDeadlineTests {
    @Test(arguments: [false, true])
    func savedPasswordChallengeFitsResizeDeadline(useV2: Bool) throws {
        let support = CMUXCLIErrorOutputRegressionTests()
        let cliPath = try support.bundledCLIPath()
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = CmuxStateDirectory.url(homeDirectory: root)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let passwordURL = stateDirectory.appendingPathComponent(SocketControlPasswordStore.fileName)
        try Data("deadline-test-password".utf8).write(to: passwordURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordURL.path)

        let socketPath = root.appendingPathComponent("control.sock").path
        let challenge = useV2
            ? #"{"ok":false,"error":{"code":"auth_required","message":"send auth <password> first"}}"#
            : "ERROR: Authentication required — send auth <password> first"
        let response = useV2 ? #"{"ok":true,"result":{"resized":true}}"# : "PONG"
        let server = try UnixSocketResponder(
            path: socketPath,
            responses: Array(repeating: [challenge, "OK: Authenticated", response], count: 2).flatMap { $0 }
        )
        defer { server.stop() }
        let params = #"{"workspace_id":"11111111-1111-1111-1111-111111111111","cols":120,"rows":40}"#
        let command = useV2 ? ["rpc", "workspace.remote.pty_resize", params] : ["ping"]

        // Each invocation creates a fresh credential-free client, as the resize
        // monitor does. The server keeps the connection open after its replies.
        for invocation in 0..<2 {
            let result = support.runProcess(
                executablePath: cliPath,
                arguments: ["--socket", socketPath] + command,
                environment: environment(home: root, responseTimeout: "0.05"),
                timeout: 5
            )
            #expect(!result.timedOut, "\(result.diagnostics)")
            try #require(result.status == 0, "\(result.diagnostics)")
            if useV2 {
                let object = try #require(
                    JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Bool]
                )
                #expect(object["resized"] == true)
            } else {
                #expect(result.stdout == "PONG\n")
            }
            let requests = server.receivedRequests
            try #require(requests.count == (invocation + 1) * 3)
            let offset = invocation * 3
            #expect(requests[offset + 1] == "auth deadline-test-password")
            #expect(requests[offset] == requests[offset + 2], "Replay must preserve the original request")
            if useV2 {
                let request = try #require(
                    JSONSerialization.jsonObject(with: Data(requests[offset].utf8)) as? [String: Any]
                )
                #expect(request["method"] as? String == "workspace.remote.pty_resize")
            } else {
                #expect(requests[offset] == "ping")
            }
        }
    }

    @Test(arguments: [false, true])
    func reusedClientAuthenticatesAfterPasswordReadExceedsPriorDeadline(useV2: Bool) throws {
        let support = CMUXCLIErrorOutputRegressionTests()
        let cliPath = try support.bundledCLIPath()
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = CmuxStateDirectory.url(homeDirectory: root)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let passwordURL = stateDirectory.appendingPathComponent(SocketControlPasswordStore.fileName)
        try #require(mkfifo(passwordURL.path, 0o600) == 0)

        // Opening the FIFO synchronizes with the real credential read. Delay
        // only after that read starts, so it must overrun the first deadline.
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/bin/sh")
        writer.arguments = [
            "-c", "exec 3>\"$1\"; sleep 1.2; printf '%s' deadline-test-password >&3",
            "cmux-delayed-password", passwordURL.path,
        ]
        try writer.run()
        defer {
            if writer.isRunning {
                writer.terminate()
                writer.waitUntilExit()
            }
        }

        let socketPath = root.appendingPathComponent("control.sock").path
        let challenge = useV2
            ? #"{"ok":false,"error":{"code":"auth_required","message":"send auth <password> first"}}"#
            : "ERROR: Authentication required — send auth <password> first"
        let server = try UnixSocketResponder(path: socketPath, responses: [
            challenge, challenge, "OK: Authenticated",
            #"{"ok":true,"result":{"terminals":[]}}"#,
            #"{"ok":true,"result":{"flashed":true}}"#,
        ])
        defer { server.stop() }
        var testEnvironment = environment(home: root, responseTimeout: "1")
        testEnvironment["TMUX"] = nil
        testEnvironment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        testEnvironment["CMUX_CLI_TTY_NAME"] = "ttys-auth-deadline-fixture"

        // Ambient workspace validation and its TTY fallback reuse one client.
        // Only the fallback's fresh deadline may authenticate and replay.
        let result = support.runProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", socketPath, "--json", "trigger-flash", "--surface",
                "22222222-2222-2222-2222-222222222222",
            ],
            environment: testEnvironment,
            timeout: 8
        )
        #expect(!result.timedOut, "\(result.diagnostics)")
        #expect(result.status == 0, "\(result.diagnostics)")
        let requests = server.receivedRequests
        try #require(requests.count == 5, "\(requests)")
        #expect(requests[2] == "auth deadline-test-password")
        #expect(requests[1] == requests[3], "Replay must preserve the fallback request")
        let methods = try [0, 1, 3, 4].map { index in
            let request = try #require(
                JSONSerialization.jsonObject(with: Data(requests[index].utf8)) as? [String: Any]
            )
            return try #require(request["method"] as? String)
        }
        #expect(methods == ["surface.list", "debug.terminals", "debug.terminals", "surface.trigger_flash"])
        let response = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Bool]
        )
        #expect(response["flashed"] == true)
        writer.waitUntilExit()
        #expect(writer.terminationStatus == 0)
    }

    @Test
    func ordinaryMultilineResponseIsNotTruncated() throws {
        let support = CMUXCLIErrorOutputRegressionTests()
        let cliPath = try support.bundledCLIPath()
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("control.sock").path
        let response = "OK: Listing\nfirst row\nsecond row"
        let server = try UnixSocketResponder(path: socketPath, response: response)
        defer { server.stop() }
        let result = support.runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "ping"],
            environment: environment(home: root, responseTimeout: "1"),
            timeout: 5
        )
        #expect(!result.timedOut, "\(result.diagnostics)")
        #expect(result.status == 0, "\(result.diagnostics)")
        #expect(result.stdout == response + "\n")
        #expect(server.receivedRequests == ["ping"])
    }

    private func makeHome() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/cmx-auth-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func environment(home: URL, responseTimeout: String) -> [String: String] {
        var result = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX") }
        result["CFFIXED_USER_HOME"] = home.path
        result["HOME"] = home.path
        result["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = responseTimeout
        result["CMUX_CLI_SENTRY_DISABLED"] = "1"
        return result
    }
}
