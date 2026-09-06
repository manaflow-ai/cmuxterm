import AppKit
import SwiftUI

/// Right-sidebar "Voice" panel: the native controls for the voice agent.
/// The audio itself runs in the hidden `VoiceAgentAudioWebView` mounted at
/// the bottom of this view while a session is requested.
struct VoiceAgentSidebarView: View {
    let chromeBackgroundColor: NSColor

    private var state: VoiceAgentSessionState { VoiceAgentSessionState.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            micControl
            if let error = state.lastError {
                errorBanner(error)
            }
            transcriptList
            if !state.recentActions.isEmpty {
                actionChips
            }
            Spacer(minLength: 0)
            footer
            if let url = state.audioPageURL {
                VoiceAgentAudioWebView(url: url, state: state)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: chromeBackgroundColor))
        .accessibilityIdentifier("VoiceAgentSidebarPanel")
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text(String(localized: "voiceAgent.panel.title", defaultValue: "Voice"))
                .font(.headline)
            Spacer()
            if state.isLive, !state.isAudioPlaying {
                Image(systemName: "speaker.slash")
                    .foregroundStyle(.orange)
                    .help(String(localized: "voiceAgent.audio.notPlaying", defaultValue: "No audio is playing yet"))
                    .accessibilityIdentifier("VoiceAgentAudioMutedIndicator")
            }
            Text(phaseLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("VoiceAgentPhaseLabel")
        }
    }

    private var micControl: some View {
        HStack(spacing: 12) {
            Button(action: toggleSession) {
                ZStack {
                    Circle()
                        .fill(micFill)
                        .frame(width: 56, height: 56)
                    Image(systemName: micSymbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(state.isBusy)
            .accessibilityLabel(state.isSessionRequested
                ? String(localized: "voiceAgent.button.stop", defaultValue: "End voice session")
                : String(localized: "voiceAgent.button.start", defaultValue: "Start voice session"))
            .accessibilityIdentifier("VoiceAgentMicButton")

            VStack(alignment: .leading, spacing: 4) {
                Text(state.isSessionRequested
                    ? String(localized: "voiceAgent.hint.live", defaultValue: "Talk to control cmux. Click to end.")
                    : String(localized: "voiceAgent.hint.idle", defaultValue: "Click to start talking."))
                    .font(.callout)
                if state.isSessionRequested {
                    Button(action: { state.setMuted(!state.isMuted) }) {
                        Label(
                            state.isMuted
                                ? String(localized: "voiceAgent.button.unmute", defaultValue: "Unmute")
                                : String(localized: "voiceAgent.button.mute", defaultValue: "Mute"),
                            systemImage: state.isMuted ? "mic.slash" : "mic"
                        )
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("VoiceAgentMuteButton")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .accessibilityIdentifier("VoiceAgentErrorBanner")
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if state.transcript.isEmpty {
                        Text(String(
                            localized: "voiceAgent.transcript.empty",
                            defaultValue: "Try: “What do I have open?”, “Go to workspace two”, “Split right”, “Run ls”."
                        ))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    ForEach(state.transcript) { line in
                        transcriptRow(line)
                            .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: state.transcript.last?.id) { _, id in
                if let id {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
        .frame(minHeight: 120)
    }

    private func transcriptRow(_ line: VoiceAgentSessionState.TranscriptLine) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(line.role == .user
                ? String(localized: "voiceAgent.transcript.you", defaultValue: "You")
                : String(localized: "voiceAgent.transcript.agent", defaultValue: "cmux"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(line.role == .user ? Color.accentColor : .secondary)
                .frame(width: 36, alignment: .trailing)
            Text(line.text)
                .font(.callout)
                .foregroundStyle(line.isFinal ? .primary : .secondary)
                .textSelection(.enabled)
        }
    }

    private var actionChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "voiceAgent.actions.title", defaultValue: "Actions"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(state.recentActions.suffix(5)) { chip in
                HStack(spacing: 6) {
                    Image(systemName: chip.isFinished ? "checkmark.circle" : "circle.dotted")
                        .foregroundStyle(chip.isFinished ? Color.green : Color.secondary)
                    Text(chip.summary ?? chip.name.replacingOccurrences(of: "_", with: " "))
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if !state.transcript.isEmpty {
                Button(String(localized: "voiceAgent.button.clear", defaultValue: "Clear")) {
                    state.clearTranscript()
                }
                .controlSize(.small)
            }
            Spacer()
            Text(String(localized: "voiceAgent.footer.beta", defaultValue: "Beta · Ultravox via Pipecat"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Derived

    private var phaseLabel: String {
        switch state.phase {
        case .off: return String(localized: "voiceAgent.phase.off", defaultValue: "Off")
        case .starting: return String(localized: "voiceAgent.phase.starting", defaultValue: "Starting…")
        case .connecting: return String(localized: "voiceAgent.phase.connecting", defaultValue: "Connecting…")
        case .listening: return state.isMuted
            ? String(localized: "voiceAgent.phase.muted", defaultValue: "Muted")
            : String(localized: "voiceAgent.phase.listening", defaultValue: "Listening")
        case .thinking: return String(localized: "voiceAgent.phase.thinking", defaultValue: "Thinking…")
        case .speaking: return String(localized: "voiceAgent.phase.speaking", defaultValue: "Speaking")
        case .error: return String(localized: "voiceAgent.phase.error", defaultValue: "Error")
        }
    }

    private var micSymbol: String {
        switch state.phase {
        case .off, .error: return "mic"
        case .starting, .connecting: return "ellipsis"
        case .listening: return state.isMuted ? "mic.slash.fill" : "mic.fill"
        case .thinking: return "waveform"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    private var micFill: Color {
        switch state.phase {
        case .off: return .gray
        case .error: return .orange
        case .starting, .connecting: return .gray.opacity(0.7)
        case .listening: return state.isMuted ? .gray : .red
        case .thinking: return .purple
        case .speaking: return .blue
        }
    }

    private func toggleSession() {
        _ = AppDelegate.shared?.performVoiceAgentToggle(preferredWindow: NSApp.keyWindow)
    }
}
