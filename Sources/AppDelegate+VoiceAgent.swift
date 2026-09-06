import AppKit
import CmuxFoundation
import CmuxSettings
import Foundation
import os

/// Process-wide record of the app-owned voice sidecar, mirroring
/// `AgentChatActionInFlightGate`. The sidecar outlives individual voice
/// sessions (each session is a new WebRTC call) and is terminated on quit.
struct VoiceAgentSidecarRegistry {
    private struct State {
        var isStarting = false
        var session: VoiceAgentSidecarSession?
    }

    private nonisolated static let lock = OSAllocatedUnfairLock(initialState: State())

    static func beginStarting() -> Bool {
        lock.withLock { state in
            guard !state.isStarting else { return false }
            state.isStarting = true
            return true
        }
    }

    static func endStarting() {
        lock.withLock { state in state.isStarting = false }
    }

    static func session() -> VoiceAgentSidecarSession? {
        lock.withLock { state in state.session }
    }

    static func update(_ session: VoiceAgentSidecarSession) {
        lock.withLock { state in state.session = session }
    }

    static func clear(matching candidate: VoiceAgentSidecarSession? = nil) {
        lock.withLock { state in
            if let candidate, state.session != candidate { return }
            state.session = nil
        }
    }
}

extension AppDelegate {
    /// The one shared action behind the sidebar mic button, the palette
    /// command, and the `toggleVoiceAgent` shortcut: start a voice session
    /// (launching the sidecar if needed and revealing the Voice panel), or end
    /// the running one.
    @discardableResult
    func performVoiceAgentToggle(preferredWindow: NSWindow? = nil) -> Bool {
        guard VoiceAgentFeature.isEnabled() else {
            NSSound.beep()
            return false
        }
        let state = VoiceAgentSessionState.shared
        if state.isSessionRequested || state.phase == .starting {
            stopVoiceAgentSession()
            return true
        }
        _ = focusRightSidebarInActiveMainWindow(
            mode: .voice,
            focusFirstItem: false,
            preferredWindow: preferredWindow
        )
        startVoiceAgentSession()
        return true
    }

    func startVoiceAgentSession() {
        let state = VoiceAgentSessionState.shared
        guard state.phase != .starting else { return }
        state.beginStarting()
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.ensureVoiceAgentSidecar() {
            case .success(let session):
                guard state.phase == .starting else { return }
                state.sidecar = session
                state.isSessionRequested = true
                state.phase = .connecting
            case .failure(let error):
                state.fail(error.message)
            }
        }
    }

    func stopVoiceAgentSession() {
        let state = VoiceAgentSessionState.shared
        state.audioController?.stop()
        state.reset()
    }

    /// Called from `applicationWillTerminate`; the sidecar is a detached
    /// process and would otherwise outlive the app.
    func terminateVoiceAgentSidecar() {
        guard let session = VoiceAgentSidecarRegistry.session() else { return }
        VoiceAgentSidecarLauncher.terminate(pid: session.pid)
        VoiceAgentSidecarRegistry.clear(matching: session)
    }

    private func ensureVoiceAgentSidecar() async -> Result<VoiceAgentSidecarSession, VoiceAgentSidecarError> {
        if let session = VoiceAgentSidecarRegistry.session() {
            if await VoiceAgentSidecarLauncher.isHealthy(session.healthURL, timeout: 1.5) {
                return .success(session)
            }
            VoiceAgentSidecarRegistry.clear(matching: session)
        }
        // A sidecar from a previous app run (or a stale one after a rebuild)
        // is never reused: it may be running old code, and its token is lost.
        VoiceAgentSidecarLauncher.terminateOrphans()
        guard VoiceAgentSidecarRegistry.beginStarting() else {
            return .failure(.alreadyStarting)
        }
        defer { VoiceAgentSidecarRegistry.endStarting() }

        guard let apiKey = await Self.voiceAgentAPIKey(), !apiKey.isEmpty else {
            return .failure(.missingAPIKey)
        }
        let startCommand: String
        switch VoiceAgentSidecarLauncher.resolveStartCommand() {
        case .success(let command):
            startCommand = command
        case .failure(let error):
            return .failure(error)
        }
        guard let token = VoiceAgentSidecarLauncher.generateToken(),
              let stateFileStore = VoiceAgentSidecarStateFileStore.live() else {
            return .failure(.launchFailed(String(
                localized: "voiceAgent.error.prepareFailed",
                defaultValue: "Could not prepare the voice server launch."
            )))
        }
        let launchId = UUID().uuidString
        let launchDate = Date()
        guard let stateFileURL = await stateFileStore.prepareStateFileURL(
            launchId: launchId,
            launchDate: launchDate
        ) else {
            return .failure(.launchFailed(String(
                localized: "voiceAgent.error.prepareFailed",
                defaultValue: "Could not prepare the voice server launch."
            )))
        }

        let terminalController = TerminalController.shared
        var environment = terminalController.socketClientCapabilityEnvironment()
        environment["CMUX_VOICE_AGENT_TOKEN"] = token
        environment["CMUX_VOICE_AGENT_PORT"] = "0"
        environment["CMUX_VOICE_AGENT_STATE_FILE"] = stateFileURL.path
        environment["CMUX_VOICE_AGENT_LAUNCH_ID"] = launchId
        environment["ULTRAVOX_API_KEY"] = apiKey
        let socketPath = terminalController.socketServer.currentSocketPath
        if !socketPath.isEmpty {
            environment["CMUX_SOCKET_PATH"] = socketPath
        }
        if VoiceAgentFeature.trustsTerminalInput() {
            environment["CMUX_VOICE_TRUST_TERMINAL"] = "1"
        }
        if let voice = VoiceAgentFeature.configuredVoice() {
            environment["ULTRAVOX_VOICE"] = voice
        }

        guard VoiceAgentSidecarLauncher.launchDetached(startCommand, environmentOverrides: environment) else {
            return .failure(.launchFailed(String(
                localized: "voiceAgent.error.launchFailed",
                defaultValue: "Could not start the voice server. Check voiceAgent.startCommand."
            )))
        }
        guard let session = await stateFileStore.waitForSession(
            token: token,
            launchId: launchId,
            launchDate: launchDate
        ) else {
            return .failure(.timedOut)
        }
        VoiceAgentSidecarRegistry.update(session)
        return .success(session)
    }

    /// Reads the Ultravox key from the same secret-file store the Settings UI
    /// writes (`~/.local/state/cmux/ultravox-api-key`, mode 0600).
    nonisolated private static func voiceAgentAPIKey() async -> String? {
        let baseDirectory = SocketControlPasswordStore.defaultPasswordFileURL(fileManager: .default)?
            .deletingLastPathComponent()
            ?? CmuxStateDirectory.url(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        let store = SecretFileStore(baseDirectory: baseDirectory)
        let value = try? await store.value(for: SettingCatalog().voiceAgent.ultravoxApiKey)
        return value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
