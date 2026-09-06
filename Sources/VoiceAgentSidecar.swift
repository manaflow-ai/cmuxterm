import Foundation
import Security

/// A running voice-agent sidecar (`voice-agent/server.py`) owned by this app.
/// Mirrors `AgentChatOwnedServerSession`: the sidecar picks an ephemeral
/// loopback port, and every route except `/healthz` lives under an
/// unguessable token prefix.
struct VoiceAgentSidecarSession: Sendable, Hashable {
    var port: Int
    var pid: Int
    var token: String

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    var healthURL: URL {
        baseURL.appendingPathComponent("healthz")
    }

    /// The hidden audio page the sidebar's WKWebView loads. `autostart=1`
    /// makes the page open the WebRTC call as soon as it loads.
    var audioPageURL: URL {
        URL(string: "http://127.0.0.1:\(port)/\(token)/audio.html?autostart=1")!
    }
}

struct VoiceAgentSidecarStateFile: Decodable, Sendable, Hashable {
    var port: Int
    var pid: Int
    var launchId: String?

    func session(token: String, launchId expectedLaunchId: String) -> VoiceAgentSidecarSession? {
        guard launchId == expectedLaunchId else { return nil }
        guard (1...65_535).contains(port), pid > 0 else { return nil }
        return VoiceAgentSidecarSession(port: port, pid: pid, token: token)
    }
}

/// Readiness handshake: the app pre-creates `state-<launchId>.json`, the
/// sidecar overwrites it with `{"port","pid","launchId"}` once listening, and
/// the app polls until it parses. Same contract as `AgentChatSidecarStateFileStore`.
struct VoiceAgentSidecarStateFileStore: Sendable {
    var directoryURL: URL

    static func live() -> VoiceAgentSidecarStateFileStore? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        return VoiceAgentSidecarStateFileStore(
            directoryURL: appSupport
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent("voice-agent", isDirectory: true)
        )
    }

    func stateFileURL(launchId: String) -> URL {
        directoryURL.appendingPathComponent("state-\(launchId).json")
    }

    func prepareStateFileURL(launchId: String, launchDate: Date) async -> URL? {
        let stateFileURL = stateFileURL(launchId: launchId)
        return await Task.detached(priority: .utility) { () -> URL? in
            let fileManager = FileManager.default
            let directoryURL = stateFileURL.deletingLastPathComponent()
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let stale = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                for fileURL in stale where fileURL != stateFileURL && Self.isStateFile(fileURL) {
                    let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                    if (values?.contentModificationDate ?? .distantPast) < launchDate {
                        try? fileManager.removeItem(at: fileURL)
                    }
                }
                try? fileManager.removeItem(at: stateFileURL)
                guard fileManager.createFile(atPath: stateFileURL.path, contents: nil) else { return nil }
                return stateFileURL
            } catch {
                return nil
            }
        }.value
    }

    func waitForSession(
        token: String,
        launchId: String,
        launchDate: Date,
        timeout: Duration = .seconds(20)
    ) async -> VoiceAgentSidecarSession? {
        let stateFileURL = stateFileURL(launchId: launchId)
        return await Task.detached(priority: .utility) { () -> VoiceAgentSidecarSession? in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !Task.isCancelled, clock.now < deadline {
                if let data = try? Data(contentsOf: stateFileURL),
                   let stateFile = try? JSONDecoder().decode(VoiceAgentSidecarStateFile.self, from: data),
                   let session = stateFile.session(token: token, launchId: launchId) {
                    try? FileManager.default.removeItem(at: stateFileURL)
                    return session
                }
                do {
                    // Bounded, cancellable polling for the sidecar readiness file.
                    try await clock.sleep(for: .milliseconds(250))
                } catch {
                    return nil
                }
            }
            return nil
        }.value
    }

    private static func isStateFile(_ fileURL: URL) -> Bool {
        let name = fileURL.lastPathComponent
        return name.hasPrefix("state-") && name.hasSuffix(".json")
    }
}

enum VoiceAgentSidecarError: Error, Equatable {
    case missingAPIKey
    case notConfigured(String)
    case launchFailed(String)
    case timedOut
    case alreadyStarting

    var message: String {
        switch self {
        case .missingAPIKey:
            return String(
                localized: "voiceAgent.error.missingAPIKey",
                defaultValue: "Add your Ultravox API key in Settings › Beta Features › Voice Agent."
            )
        case .notConfigured(let detail):
            return detail
        case .launchFailed(let detail):
            return detail
        case .timedOut:
            return String(
                localized: "voiceAgent.error.timedOut",
                defaultValue: "The voice server did not start in time. Check the voice-agent setup and try again."
            )
        case .alreadyStarting:
            return String(
                localized: "voiceAgent.error.alreadyStarting",
                defaultValue: "The voice server is still starting."
            )
        }
    }
}

enum VoiceAgentSidecarLauncher {
    /// Resolves the shell command that starts `voice-agent/server.py`.
    ///
    /// A configured `voiceAgent.startCommand` always wins. DEBUG builds fall
    /// back to the checkout's `voice-agent/.venv` so dogfood works without
    /// configuration; release builds require the setting (bundling the Python
    /// runtime is a later phase).
    nonisolated static func resolveStartCommand() -> Result<String, VoiceAgentSidecarError> {
        if let configured = VoiceAgentFeature.configuredStartCommand() {
            return .success(configured)
        }
        #if DEBUG
        let sourceURL = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceURL.deletingLastPathComponent().deletingLastPathComponent()
        let agentDir = repoRoot.appendingPathComponent("voice-agent", isDirectory: true)
        let python = agentDir.appendingPathComponent(".venv/bin/python")
        let server = agentDir.appendingPathComponent("server.py")
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: python.path), fileManager.fileExists(atPath: server.path) else {
            return .failure(.notConfigured(String(
                localized: "voiceAgent.error.venvMissing",
                defaultValue: "voice-agent is not set up. Run: cd voice-agent && python3 -m venv .venv && .venv/bin/pip install -e . (see voice-agent/README.md)."
            )))
        }
        return .success("\(shellQuoted(python.path)) \(shellQuoted(server.path))")
        #else
        return .failure(.notConfigured(String(
            localized: "voiceAgent.error.startCommandMissing",
            defaultValue: "Set voiceAgent.startCommand to the command that starts the voice-agent server."
        )))
        #endif
    }

    nonisolated static func launchDetached(
        _ command: String,
        environmentOverrides: [String: String]
    ) -> Bool {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return false }
        let environment = ProcessInfo.processInfo.environment
        let shellPath = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: (shellPath?.isEmpty == false ? shellPath! : "/bin/zsh"))
        process.arguments = ["-lc", trimmedCommand]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = environment.merging(environmentOverrides) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            NSLog("[VoiceAgent] failed to launch sidecar: %@", String(describing: error))
            return false
        }
    }

    nonisolated static func isHealthy(_ healthURL: URL, timeout: TimeInterval) async -> Bool {
        var request = URLRequest(
            url: healthURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    nonisolated static func terminate(pid: Int) {
        guard pid > 1 else { return }
        kill(pid_t(pid), SIGTERM)
    }

    nonisolated static func generateToken(byteCount: Int = 32) -> String? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
