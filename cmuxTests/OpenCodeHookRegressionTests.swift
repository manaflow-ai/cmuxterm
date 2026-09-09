import Darwin
import Foundation
import Testing

@Suite final class OpenCodeHookRegressionTests {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    @Test func testOpenCodeFeedPluginEmitsCompletionForBothIdleEventShapes() throws {
        let fileManager = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pluginURL = repoRoot.appendingPathComponent("Resources/opencode-plugin.js", isDirectory: false)
        #expect(fileManager.fileExists(atPath: pluginURL.path))

        // Darwin's Unix-domain socket path must fit in sun_path. The runner's
        // /var/folders temporary root plus the old fixture name exceeded it.
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "cmux-oc-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: root) }

        let socketPath = root.appendingPathComponent("cmux.sock").path
        try #require(socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path))
        let harnessURL = root.appendingPathComponent("harness.js")
        try Self.openCodeFeedEventHarness.write(to: harnessURL, atomically: true, encoding: .utf8)
        let bunURL = try Self.bunExecutableURL()

        let result = runProcess(
            executablePath: bunURL.path,
            arguments: [harnessURL.path, pluginURL.path, socketPath],
            environment: ProcessInfo.processInfo.environment,
            timeout: 5
        )
        #expect(!result.timedOut, "\(result.stderr)")
        #expect(result.status == 0, "\(result.stderr)")

        let data = try #require(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8))
        let frames = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let stopEvents = frames.compactMap { frame -> [String: Any]? in
            guard frame["method"] as? String == "feed.push",
                  let params = frame["params"] as? [String: Any],
                  let event = params["event"] as? [String: Any],
                  event["hook_event_name"] as? String == "Stop" else { return nil }
            return event
        }
        #expect(stopEvents.count == 3, "Expected all OpenCode idle forms to emit Stop: \(frames)")
        #expect(stopEvents.allSatisfy { $0["session_id"] as? String == "opencode-ses-feed-shape" })
        let requestIDs = frames.compactMap { $0["id"] as? String }
        #expect(requestIDs.count == Set(requestIDs).count, "OpenCode telemetry request IDs must not collide: \(frames)")
    }

    @Test func testOpenCodeInstallHooksIsIdempotentForLegacySetupAlias() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-opencode-hooks-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("opencode", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let configURL = configDir.appendingPathComponent("opencode.json", isDirectory: false)
        try #"{"plugin":["other-plugin","./plugins/cmux-session.js"]}"#.write(to: configURL, atomically: true, encoding: .utf8)
        let fakeOpenCodeURL = binDir.appendingPathComponent("opencode", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: fakeOpenCodeURL, atomically: true, encoding: .utf8)
        chmod(fakeOpenCodeURL.path, 0o755)

        var environment = ProcessInfo.processInfo.environment
        environment["OPENCODE_CONFIG_DIR"] = configDir.path
        environment["PATH"] = "\(binDir.path):\(environment["PATH"] ?? "/usr/bin")"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(executablePath: cliPath, arguments: ["hooks", "opencode", "install", "--yes"], environment: environment, timeout: 5)

        #expect(!result.timedOut, "\(result.stderr)")
        #expect(result.status == 0, "\(result.stderr)")
        let pluginURL = configDir.appendingPathComponent("plugins", isDirectory: true).appendingPathComponent("cmux-session.js", isDirectory: false)
        let pluginSource = try String(contentsOf: pluginURL, encoding: .utf8)
        #expect(pluginSource.contains("cmux-opencode-session-plugin-marker"))
        #expect(pluginSource.contains("\"hooks\", \"opencode\""))

        let secondResult = runProcess(executablePath: cliPath, arguments: ["setup-hooks", "--agent", "opencode"], environment: environment, timeout: 5)
        #expect(!secondResult.timedOut, "\(secondResult.stderr)")
        #expect(secondResult.status == 0, "\(secondResult.stderr)")
        #expect(!secondResult.stdout.contains("Will write OpenCode cmux plugin"), "\(secondResult.stdout)")
        #expect(secondResult.stdout.contains("OpenCode hooks already up to date"), "\(secondResult.stdout)")
        let feedPluginSource = try String(contentsOf: configDir.appendingPathComponent("plugins/cmux-feed.js"), encoding: .utf8)
        #expect(feedPluginSource.contains("cmux-feed-plugin-marker"))

        let json = try #require(JSONSerialization.jsonObject(with: try Data(contentsOf: configURL), options: []) as? [String: Any])
        let plugins = try #require(json["plugin"] as? [String])
        #expect(plugins == ["other-plugin", "./plugins/cmux-session.js"])
    }

    @Test func testLegacyHookAliasesAreHiddenFromHelp() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(executablePath: cliPath, arguments: ["help"], environment: environment, timeout: 5)

        #expect(!result.timedOut, "\(result.stderr)")
        #expect(result.status == 0, "\(result.stderr)")
        #expect(!result.stdout.contains("codex <install-hooks|uninstall-hooks>"), "\(result.stdout)")
        #expect(!result.stdout.contains("claude-hook <session-start|stop|notification>"), "\(result.stdout)")
        #expect(!result.stdout.contains("codex-hook"), "\(result.stdout)")
        #expect(!result.stdout.contains("feed-hook"), "\(result.stdout)")
        #expect(!result.stdout.contains("setup-hooks"), "\(result.stdout)")
        #expect(!result.stdout.contains("uninstall-hooks"), "\(result.stdout)")
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    private static func bunExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [String] = []
        if let install = ProcessInfo.processInfo.environment["BUN_INSTALL"], !install.isEmpty {
            candidates.append(URL(fileURLWithPath: install).appendingPathComponent("bin/bun").path)
        }
        candidates += [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin/bun").path,
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
        ]
        // CI isolates HOME but forwards the installed tool PATH into the host.
        // Do not require the Bun installation to live inside the fixture home.
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("bun").path }
        let path = try #require(
            candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }),
            "Bun runtime is required for the OpenCode plugin harness"
        )
        return URL(fileURLWithPath: path)
    }

    private static let openCodeFeedEventHarness = #"""
const net = require("node:net");
const fs = require("node:fs");

(async () => {
  const [pluginPath, socketPath] = process.argv.slice(2);
  try { fs.unlinkSync(socketPath); } catch (_) {}
  const frames = [];
  let resolveFrames;
  const framesReady = new Promise((resolve) => { resolveFrames = resolve; });
  const sockets = new Set();
  const server = net.createServer((conn) => {
    sockets.add(conn);
    conn.setEncoding("utf8");
    let buffered = "";
    conn.on("data", (chunk) => {
      buffered += chunk;
      let index;
      while ((index = buffered.indexOf("\n")) >= 0) {
        const line = buffered.slice(0, index);
        buffered = buffered.slice(index + 1);
        if (!line.trim()) continue;
        const frame = JSON.parse(line);
        frames.push(frame);
        if (frames.length === 4) resolveFrames();
        conn.write(JSON.stringify({ id: frame.id, ok: true, result: { status: "acknowledged" } }) + "\n");
      }
    });
  });
  let activeSocketPath = socketPath;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      await new Promise((resolve, reject) => {
        const onError = (error) => { server.off("error", onError); reject(error); };
        server.once("error", onError);
        server.listen(activeSocketPath, () => { server.off("error", onError); resolve(); });
      });
      break;
    } catch (error) {
      if (error?.code !== "EADDRINUSE" || attempt === 2) throw error;
      activeSocketPath = `${socketPath}.${process.pid}.${attempt + 1}`;
      try { fs.unlinkSync(activeSocketPath); } catch (_) {}
    }
  }

  process.env.CMUX_SOCKET_PATH = activeSocketPath;
  const source = fs.readFileSync(pluginPath, "utf8")
    .replace("export const CMUXFeed = async", "globalThis.CMUXFeed = async");
  eval(source);
  const hooks = await globalThis.CMUXFeed({ directory: "/tmp/opencode-project" });
  await hooks.event({ event: {
    type: "session.created",
    properties: { info: { id: "ses-feed-shape", directory: "/tmp/opencode-project" } }
  } });
  await hooks.event({ event: {
    type: "session.idle",
    properties: { sessionId: "ses-feed-shape" }
  } });
  await hooks.event({ event: {
    type: "session.status",
    properties: { info: { id: "ses-feed-shape" }, status: { type: "idle" } }
  } });
  await hooks.event({ event: {
    type: "session.status",
    properties: { session_id: "ses-feed-shape", status: "idle" }
  } });
  await framesReady;
  for (const socket of sockets) socket.destroy();
  await new Promise((resolve) => server.close(resolve));
  try { fs.unlinkSync(activeSocketPath); } catch (_) {}
  console.log(JSON.stringify(frames));
})().catch((error) => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
"""#

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
