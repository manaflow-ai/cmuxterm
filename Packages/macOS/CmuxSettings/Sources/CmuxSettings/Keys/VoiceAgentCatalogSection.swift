import Foundation

/// Settings under the dotted-id prefix `voiceAgent.*` — the voice agent
/// (Ultravox Realtime through a local Pipecat sidecar). The beta gate itself
/// lives in ``BetaFeaturesCatalogSection/voiceAgent``.
public struct VoiceAgentCatalogSection: SettingCatalogSection {
    /// The Ultravox API key. Stored in its own `0600` file (never in
    /// `cmux.json`) and handed to the sidecar through its environment only.
    public let ultravoxApiKey = SecretFileKey(
        id: "voiceAgent.ultravoxApiKey",
        fileName: "ultravox-api-key"
    )

    /// When on, "run <command>" executes in the terminal without a spoken
    /// confirmation. Closing tabs and workspaces always confirms.
    public let trustTerminalInput = DefaultsKey<Bool>(
        id: "voiceAgent.trustTerminalInput",
        defaultValue: false,
        userDefaultsKey: "voiceAgent.trustTerminalInput"
    )

    /// Shell command that starts `voice-agent/server.py`. Empty uses the
    /// built-in default (DEBUG builds only).
    public let startCommand = DefaultsKey<String>(
        id: "voiceAgent.startCommand",
        defaultValue: "",
        userDefaultsKey: "voiceAgent.startCommand"
    )

    /// Optional Ultravox voice id.
    public let voice = DefaultsKey<String>(
        id: "voiceAgent.voice",
        defaultValue: "",
        userDefaultsKey: "voiceAgent.voice"
    )

    public init() {}
}
