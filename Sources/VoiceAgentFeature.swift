import Foundation

/// Voice agent (Ultravox Realtime through a local Pipecat sidecar) beta gate
/// and settings reads for non-SwiftUI callers. The keys mirror
/// `VoiceAgentCatalogSection` and the `voiceAgent.beta.enabled` toggle in
/// `BetaFeaturesCatalogSection`; SwiftUI code should bind through the
/// settings catalog instead of reading these directly.
enum VoiceAgentFeature {
    static let enabledKey = "voiceAgent.beta.enabled"
    static let trustTerminalInputKey = "voiceAgent.trustTerminalInput"
    static let startCommandKey = "voiceAgent.startCommand"
    static let voiceKey = "voiceAgent.voice"

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// When on, `run_command` executes without a spoken confirmation.
    nonisolated static func trustsTerminalInput(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: trustTerminalInputKey)
    }

    /// A user-supplied shell command that starts the sidecar. Empty means
    /// "use the built-in default" (DEBUG builds only, see `VoiceAgentSidecarLauncher`).
    nonisolated static func configuredStartCommand(defaults: UserDefaults = .standard) -> String? {
        nonEmpty(defaults.string(forKey: startCommandKey))
    }

    /// Optional Ultravox voice id passed to the sidecar as `ULTRAVOX_VOICE`.
    nonisolated static func configuredVoice(defaults: UserDefaults = .standard) -> String? {
        nonEmpty(defaults.string(forKey: voiceKey))
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
