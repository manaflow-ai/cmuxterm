import Darwin
import Foundation
import Testing

struct CLIPinnedHookClockTests {
    enum Route: CaseIterable {
        case ambient, failedAmbient, pinnedOnly
    }

    @Test(arguments: Route.allCases)
    func installedHooksCaptureOnceBeforeChoosingDeliveryRoute(_ route: Route) throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        // Keep the Unix socket path below sockaddr_un's limit on every runner.
        let root = URL(fileURLWithPath: "/tmp/cmux-pinned-clock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let callLog = root.appendingPathComponent("calls")
        let pinnedCLI = try makeCLI(named: "pinned", exitCode: 0, root: root)
        let ambientCLI = try makeCLI(named: "ambient", exitCode: route == .failedAmbient ? 7 : 0, root: root)
        let pinnedSocket = root.appendingPathComponent("pinned.sock").path
        let ambientSocket = root.appendingPathComponent("ambient.sock").path
        if route != .pinnedOnly {
            try makeSocketNode(at: ambientSocket)
        }

        var environment = [
            "HOME": root.path,
            "CFFIXED_USER_HOME": root.path,
            "TMPDIR": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_BUNDLED_CLI_PATH": pinnedCLI,
            "CMUX_SOCKET_PATH": pinnedSocket,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_TEST_CALL_LOG": callLog.path,
        ]
        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "agy", "install", "--yes"],
            environment: environment,
            timeout: 10
        )
        try #require(!install.timedOut, Comment(rawValue: install.stderr))
        try #require(install.status == 0, Comment(rawValue: install.stderr))
        let hookURL = root.appendingPathComponent(".gemini/config/hooks.json")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any])
        let hooks = try #require(json["cmux"] as? [String: Any])

        environment["CMUX_BUNDLED_CLI_PATH"] = ambientCLI
        environment["CMUX_SOCKET_PATH"] = ambientSocket
        // A new callback must replace capture metadata inherited from its parent.
        environment["CMUX_AGENT_HOOK_CAPTURED_AT"] = "946684800.000000"
        var previousTime = 946684800.0
        for (event, action) in [("SessionStart", "session-start"), ("Stop", "stop")] {
            let entries = try #require(hooks[event] as? [[String: Any]])
            let command = try #require(entries.first?["command"] as? String)
            try Data().write(to: callLog)
            let run = runCodexHookProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", command],
                environment: environment,
                standardInput: "{}",
                timeout: 10
            )
            try #require(!run.timedOut, Comment(rawValue: run.stderr))
            try #require(run.status == 0, Comment(rawValue: run.stderr))
            let calls = try String(contentsOf: callLog, encoding: .utf8)
                .split(separator: "\n")
                .map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
            let expectedRoutes = route == .failedAmbient ? ["ambient", "pinned"]
                : [route == .ambient ? "ambient" : "pinned"]
            try #require(calls.count == expectedRoutes.count)
            var capturedTimes: [String] = []
            for (call, expectedRoute) in zip(calls, expectedRoutes) {
                try #require(call.count == 3)
                #expect(call[0] == expectedRoute)
                let timestamp = try #require(Double(call[1]))
                #expect(timestamp > previousTime, "Every callback needs a fresh pre-dispatch timestamp")
                let socketPath = expectedRoute == "ambient" ? ambientSocket : pinnedSocket
                #expect(call[2] == "--socket \(socketPath) hooks antigravity \(action)")
                capturedTimes.append(call[1])
            }
            #expect(Set(capturedTimes).count == 1, "Fallback must retain the original callback's order")
            previousTime = try #require(capturedTimes.first.flatMap(Double.init))
        }
    }

    private func makeCLI(named name: String, exitCode: Int, root: URL) throws -> String {
        let url = root.appendingPathComponent(name)
        let script = """
        #!/bin/sh
        printf '%s|%s|%s\\n' '\(name)' "${CMUX_AGENT_HOOK_CAPTURED_AT:-}" "$*" >> "$CMUX_TEST_CALL_LOG"
        echo '{}'
        exit \(exitCode)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    private func makeSocketNode(at path: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(result == 0, Comment(rawValue: String(cString: strerror(errno))))
    }
}
