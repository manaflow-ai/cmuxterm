import Foundation
import Observation

/// Commands the native UI can send to the hidden audio page.
@MainActor
protocol VoiceAgentAudioControlling: AnyObject {
    func setMuted(_ muted: Bool)
    func stop()
}

/// Single source of truth for the voice session as shown by the right-sidebar
/// Voice panel, the palette command, and the shortcut. Fed by the hidden
/// audio page through the `cmuxVoice` script-message bridge
/// (see `VoiceAgentAudioWebView`).
@MainActor
@Observable
final class VoiceAgentSessionState {
    static let shared = VoiceAgentSessionState()

    enum Phase: Equatable {
        case off
        case starting
        case connecting
        case listening
        case thinking
        case speaking
        case error
    }

    struct TranscriptLine: Identifiable, Equatable {
        enum Role: Equatable {
            case user
            case agent
        }

        let id: UUID
        var role: Role
        var text: String
        var isFinal: Bool
    }

    struct ActionChip: Identifiable, Equatable {
        let id: UUID
        var name: String
        var isFinished: Bool
        var summary: String?
    }

    var phase: Phase = .off
    var isMuted = false
    var lastError: String?
    var transcript: [TranscriptLine] = []
    var recentActions: [ActionChip] = []
    var uiSummary = ""
    var sidecar: VoiceAgentSidecarSession?
    /// True while the audio page should be mounted (from start until stop).
    var isSessionRequested = false
    @ObservationIgnored weak var audioController: (any VoiceAgentAudioControlling)?

    private static let transcriptLimit = 200
    private static let actionLimit = 12

    var audioPageURL: URL? {
        guard isSessionRequested else { return nil }
        return sidecar?.audioPageURL
    }

    var isLive: Bool {
        switch phase {
        case .listening, .thinking, .speaking:
            return true
        case .off, .starting, .connecting, .error:
            return false
        }
    }

    var isBusy: Bool {
        phase == .starting || phase == .connecting
    }

    // MARK: - Transitions driven by the app

    func beginStarting() {
        lastError = nil
        recentActions = []
        phase = .starting
    }

    func fail(_ message: String) {
        lastError = message
        phase = .error
        isSessionRequested = false
    }

    func reset() {
        phase = .off
        isSessionRequested = false
        isMuted = false
        finalizeOpenTranscriptLines()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        audioController?.setMuted(muted)
    }

    func clearTranscript() {
        transcript = []
        recentActions = []
    }

    // MARK: - Bridge messages from the audio page

    func handleBridgeMessage(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "status":
            handleStatus(dict["status"] as? String ?? "", message: dict["message"] as? String)
        case "transcript":
            let role: TranscriptLine.Role = (dict["role"] as? String) == "user" ? .user : .agent
            appendTranscript(role: role, text: dict["text"] as? String ?? "", isFinal: dict["final"] as? Bool ?? false)
        case "tool":
            handleTool(name: dict["name"] as? String ?? "", phase: dict["phase"] as? String ?? "", result: dict["result"])
        case "server":
            if let data = dict["data"] as? [String: Any], data["type"] as? String == "ui_state",
               let summary = data["summary"] as? String {
                uiSummary = summary
            }
        case "error":
            lastError = dict["message"] as? String ?? String(localized: "voiceAgent.error.generic", defaultValue: "Something went wrong.")
        case "mic":
            isMuted = dict["muted"] as? Bool ?? isMuted
        default:
            break
        }
    }

    private func handleStatus(_ status: String, message: String?) {
        switch status {
        case "connecting":
            if isSessionRequested { phase = .connecting }
        case "ready", "listening":
            if isSessionRequested {
                phase = .listening
                finalizeOpenTranscriptLines(role: .agent)
            }
        case "thinking":
            if isSessionRequested { phase = .thinking }
        case "speaking":
            if isSessionRequested { phase = .speaking }
        case "disconnected":
            if isSessionRequested, phase != .error {
                // The call ended from the far side (max duration, hang-up, or a crash).
                phase = .off
                isSessionRequested = false
                finalizeOpenTranscriptLines()
            }
        case "error":
            fail(message ?? lastError ?? String(localized: "voiceAgent.error.generic", defaultValue: "Something went wrong."))
        default:
            break
        }
    }

    private func appendTranscript(role: TranscriptLine.Role, text: String, isFinal: Bool) {
        guard !text.isEmpty else { return }
        if let last = transcript.last, last.role == role, !last.isFinal {
            var updated = last
            switch role {
            case .user:
                // Interim user transcripts replace each other until finalized.
                updated.text = text
            case .agent:
                // Agent output arrives in word/sentence chunks; stitch them.
                updated.text = Self.joined(updated.text, text)
            }
            updated.isFinal = isFinal
            transcript[transcript.count - 1] = updated
        } else {
            transcript.append(TranscriptLine(id: UUID(), role: role, text: text, isFinal: isFinal))
        }
        if transcript.count > Self.transcriptLimit {
            transcript.removeFirst(transcript.count - Self.transcriptLimit)
        }
    }

    private func finalizeOpenTranscriptLines(role: TranscriptLine.Role? = nil) {
        for index in transcript.indices where !transcript[index].isFinal && (role == nil || transcript[index].role == role) {
            transcript[index].isFinal = true
        }
    }

    private func handleTool(name: String, phase: String, result: Any?) {
        guard !name.isEmpty else { return }
        if phase == "started" {
            recentActions.append(ActionChip(id: UUID(), name: name, isFinished: false, summary: nil))
        } else if let index = recentActions.lastIndex(where: { $0.name == name && !$0.isFinished }) {
            recentActions[index].isFinished = true
            if let dict = result as? [String: Any], let say = dict["say"] as? String {
                recentActions[index].summary = say
            }
        }
        if recentActions.count > Self.actionLimit {
            recentActions.removeFirst(recentActions.count - Self.actionLimit)
        }
    }

    private static func joined(_ existing: String, _ chunk: String) -> String {
        guard let first = chunk.first else { return existing }
        if existing.isEmpty || existing.last?.isWhitespace == true || first.isWhitespace || first.isPunctuation {
            return existing + chunk
        }
        return existing + " " + chunk
    }
}
