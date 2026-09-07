import Darwin
import Foundation
import Testing

private final class CopilotHookConfigBundleToken {}

@Suite("Copilot hook configuration", .serialized)
struct CopilotHookConfigTests {
    private struct ProcessResult {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    @Test("Setup writes the documented user hook file and lifecycle events")
    func setupWritesDocumentedHookFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runCLI(
            arguments: ["hooks", "setup", "copilot", "--yes"],
            fixture: fixture
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        let configURL = fixture.home
            .appendingPathComponent(".copilot/hooks/cmux.json", isDirectory: false)
        let config = try jsonObject(at: configURL)
        #expect(config["version"] as? Int == 1)
        let hooks = try #require(config["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set([
            "sessionStart",
            "userPromptSubmitted",
            "agentStop",
            "notification",
            "errorOccurred",
            "sessionEnd",
            "preToolUse",
        ]))
        #expect(command(in: hooks, event: "agentStop").contains("hooks copilot stop"))
        #expect(command(in: hooks, event: "notification").contains("hooks copilot notification"))
        #expect(command(in: hooks, event: "errorOccurred").contains("hooks copilot error"))
        #expect(command(in: hooks, event: "preToolUse").contains("hooks feed --source copilot --event preToolUse"))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(".copilot/config.json").path
        ))
    }

    @Test("Setup honors COPILOT_HOME and removes only legacy cmux hooks")
    func setupHonorsCopilotHomeAndMigratesLegacyHooks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let copilotHome = fixture.root.appendingPathComponent("copilot-home", isDirectory: true)
        try FileManager.default.createDirectory(at: copilotHome, withIntermediateDirectories: true)
        let legacyURL = copilotHome.appendingPathComponent("config.json", isDirectory: false)
        let legacy: [String: Any] = [
            "userSetting": true,
            "hooks": [
                "SessionStart": [
                    [
                        "hooks": [
                            ["type": "command", "command": "cmux hooks copilot session-start"],
                            ["type": "command", "command": "echo user-hook"],
                        ],
                    ],
                ],
                "Notification": [
                    ["hooks": [["type": "command", "command": "cmux hooks copilot stop"]]],
                ],
            ],
        ]
        try writeJSON(legacy, to: legacyURL)

        let result = try runCLI(
            arguments: ["hooks", "setup", "copilot", "--yes"],
            fixture: fixture,
            environmentOverrides: ["COPILOT_HOME": copilotHome.path]
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(FileManager.default.fileExists(
            atPath: copilotHome.appendingPathComponent("hooks/cmux.json").path
        ))
        let migrated = try jsonObject(at: legacyURL)
        #expect(migrated["userSetting"] as? Bool == true)
        let hooks = try #require(migrated["hooks"] as? [String: Any])
        #expect(hooks["Notification"] == nil)
        #expect(command(in: hooks, event: "SessionStart") == "echo user-hook")
    }

    @Test("Repeated setup preserves user hooks without duplicating cmux entries")
    func repeatedSetupPreservesUserHooks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configURL = fixture.home
            .appendingPathComponent(".copilot/hooks/cmux.json", isDirectory: false)
        try writeJSON([
            "version": 1,
            "hooks": [
                "sessionStart": [
                    ["type": "command", "command": "echo user-hook"],
                ],
            ],
        ], to: configURL)

        for _ in 0..<2 {
            let result = try runCLI(
                arguments: ["hooks", "setup", "copilot", "--yes"],
                fixture: fixture
            )
            #expect(result.status == 0, Comment(rawValue: result.output))
        }

        let config = try jsonObject(at: configURL)
        let hooks = try #require(config["hooks"] as? [String: Any])
        let entries = try #require(hooks["sessionStart"] as? [[String: Any]])
        #expect(entries.count == 2)
        #expect(entries.contains { ($0["command"] as? String) == "echo user-hook" })
        #expect(entries.filter {
            ($0["command"] as? String)?.contains("hooks copilot session-start") == true
        }.count == 1)
    }

    @Test("Uninstall removes current and legacy cmux hooks")
    func uninstallRemovesCurrentAndLegacyHooks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let setup = try runCLI(
            arguments: ["hooks", "setup", "copilot", "--yes"],
            fixture: fixture
        )
        #expect(setup.status == 0, Comment(rawValue: setup.output))

        let legacyURL = fixture.home.appendingPathComponent(".copilot/config.json", isDirectory: false)
        try writeJSON([
            "hooks": [
                "Notification": [
                    ["hooks": [["type": "command", "command": "cmux hooks copilot stop"]]],
                ],
            ],
        ], to: legacyURL)

        let result = try runCLI(
            arguments: ["hooks", "uninstall", "copilot", "--yes"],
            fixture: fixture
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        let current = try jsonObject(
            at: fixture.home.appendingPathComponent(".copilot/hooks/cmux.json", isDirectory: false)
        )
        #expect((current["hooks"] as? [String: Any])?.isEmpty == true)
        let legacy = try jsonObject(at: legacyURL)
        #expect((legacy["hooks"] as? [String: Any])?.isEmpty == true)
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let bin: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-copilot-hooks-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let copilot = bin.appendingPathComponent("copilot", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: copilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copilot.path)
        return Fixture(root: root, home: home, bin: bin)
    }

    private func command(in hooks: [String: Any], event: String) -> String {
        let entries = hooks[event] as? [[String: Any]]
        for entry in entries ?? [] {
            if let command = entry["command"] as? String {
                return command
            }
            if let nested = entry["hooks"] as? [[String: Any]],
               let command = nested.first?["command"] as? String {
                return command
            }
        }
        return ""
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func runCLI(
        arguments: [String],
        fixture: Fixture,
        environmentOverrides: [String: String] = [:]
    ) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(
            fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(
                for: CopilotHookConfigBundleToken.self
            )
        )
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment.removeValue(forKey: "COPILOT_HOME")
        environment["HOME"] = fixture.home.path
        environment["PATH"] = "\(fixture.bin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment.merge(environmentOverrides) { _, override in override }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }
        try process.run()
        let timedOut = exitSignal.wait(timeout: .now() + 10) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        return ProcessResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
