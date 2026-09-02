import Foundation
import CryptoKit

struct ClaudeHookSessionRecord: Codable {
    /// Persisted beside the session record because it is only meaningful as
    /// the command identity for this record's Cursor approval lifecycle.
    struct PendingCursorShellApproval: Codable, Equatable {
        private static let hexadecimal = Array("0123456789abcdef".utf8)
        let commandFingerprint: String
        let commandLength: Int
        let displayCommand: String
        let toolUseId: String?
        /// Opaque identity of the notification created for this approval.
        /// It lets completion clear one entry without scanning or clearing a
        /// newer notification on the same surface.
        let notificationCorrelationKey: String?
        let createdAt: TimeInterval
        let requiresToolUseId: Bool

        init(
            command: String,
            toolUseId: String?,
            createdAt: TimeInterval,
            requiresToolUseId: Bool = false,
            notificationCorrelationKey: String? = UUID().uuidString.lowercased()
        ) {
            let normalized = Self.normalizedCommand(command)
            self.commandFingerprint = Self.fingerprint(for: normalized)
            self.commandLength = normalized.utf8.count
            self.displayCommand = Self.redactedPreview(for: normalized)
            self.toolUseId = toolUseId
            self.notificationCorrelationKey = notificationCorrelationKey
                .flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
                ?? UUID().uuidString.lowercased()
            self.createdAt = createdAt
            self.requiresToolUseId = requiresToolUseId
        }

        static func identity(for normalizedCommand: String) -> (fingerprint: String, length: Int) {
            (
                fingerprint: fingerprint(for: normalizedCommand),
                length: normalizedCommand.utf8.count
            )
        }

        private static func normalizedCommand(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func fingerprint(for value: String) -> String {
            var encoded: [UInt8] = []
            encoded.reserveCapacity(64)
            for byte in SHA256.hash(data: Data(value.utf8)) {
                encoded.append(hexadecimal[Int(byte >> 4)])
                encoded.append(hexadecimal[Int(byte & 0x0f)])
            }
            return String(decoding: encoded, as: UTF8.self)
        }

        private static func redactedPreview(for value: String) -> String {
            _ = value
            return String(
                localized: "agent.generic.notification.body.approvalNeeded",
                defaultValue: "Approval needed"
            )
        }

        private enum CodingKeys: String, CodingKey {
            case commandFingerprint
            case commandLength
            case displayCommand
            case toolUseId
            case notificationCorrelationKey
            case createdAt
            case requiresToolUseId
            case legacyCommand = "command"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let fingerprint = try container.decodeIfPresent(String.self, forKey: .commandFingerprint),
               let length = try container.decodeIfPresent(Int.self, forKey: .commandLength) {
                commandFingerprint = fingerprint
                commandLength = length
                displayCommand = try container.decodeIfPresent(String.self, forKey: .displayCommand) ?? ""
            } else {
                let legacy = try container.decodeIfPresent(String.self, forKey: .legacyCommand) ?? ""
                let normalized = Self.normalizedCommand(legacy)
                commandFingerprint = Self.fingerprint(for: normalized)
                commandLength = normalized.utf8.count
                displayCommand = Self.redactedPreview(for: normalized)
            }
            toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
            let decodedCorrelationKey = try container.decodeIfPresent(String.self, forKey: .notificationCorrelationKey)
            notificationCorrelationKey = decodedCorrelationKey
                .flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
                ?? UUID().uuidString.lowercased()
            createdAt = try container.decodeIfPresent(TimeInterval.self, forKey: .createdAt) ?? 0
            requiresToolUseId = try container.decodeIfPresent(Bool.self, forKey: .requiresToolUseId) ?? false
        }

        /// Encodes the persisted approval fields without emitting the
        /// decode-only legacy command. The legacy key is retained only for
        /// decoding stores written by older builds.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(commandFingerprint, forKey: .commandFingerprint)
            try container.encode(commandLength, forKey: .commandLength)
            try container.encode(displayCommand, forKey: .displayCommand)
            try container.encodeIfPresent(toolUseId, forKey: .toolUseId)
            try container.encodeIfPresent(notificationCorrelationKey, forKey: .notificationCorrelationKey)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(requiresToolUseId, forKey: .requiresToolUseId)
        }
    }

    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var title: String? = nil
    var transcriptPath: String?
    var pid: Int?
    /// Exact process-generation identity captured when the hook recorded `pid`.
    var pidStartSeconds: Int64? = nil
    var pidStartMicroseconds: Int64? = nil
    var launchCommand: AgentHookLaunchCommandRecord?
    /// Last hook-observed `permission_mode`, re-applied on user-owned restore (#8066).
    var lastPermissionMode: String?
    var isRestorable: Bool?
    var agentLifecycle: AgentHibernationLifecycleState?
    /// The hook event that most recently established the persisted lifecycle.
    /// Optional so records written by older builds continue to decode.
    var hookEventName: String? = nil
    var lastSubtitle: String?
    var lastBody: String?
    var lastNotificationStatus: AgentHookNotificationStatus?
    var lastEmittedNotificationFingerprint: String?
    var lastEmittedNotificationAt: TimeInterval?
    var recentEmittedNotificationFingerprints: [String: TimeInterval]?
    var runtimeStatus: AgentHookRuntimeStatus?
    /// Monotonic hook event time persisted with runtime state.
    var runtimeStatusEventTime: TimeInterval?
    var activePromptDepth: Int?
    var activePromptTurnId: String?
    var activePromptTurnIds: [String]?
    var lastPromptTurnId: String?
    var terminalPromptTurnIds: [String]?
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
    /// Immutable age anchor for a demoted record awaiting external cleanup.
    /// Optional for compatibility with stores written before cleanup retries
    /// became durable.
    var supersededCleanupEnqueuedAt: TimeInterval? = nil
    /// Retry ordering metadata. Attempts must not rewrite `updatedAt`, because
    /// that timestamp is also the normal session-state expiry anchor.
    var supersededCleanupLastAttemptAt: TimeInterval? = nil
    var supersededCleanupAttemptCount: Int? = nil
    // Auto-naming engine state (all optional so stores written before the
    // feature decode unchanged). The durable baseline advances only after a
    // confirmed title apply; the in-flight marker dedupes concurrent Stops.
    var autoNameLastTitle: String?
    var autoNameLastLineCount: Int?
    var autoNameLastNamedAt: TimeInterval?
    var autoNameInFlightAt: TimeInterval?
    /// Last summarization attempt, including failures, for cooldown enforcement.
    var autoNameLastAttemptAt: TimeInterval?
    var autoNameRecentMessages: [AutoNamingTranscriptMessage]?
    var autoNameMessageSequence: Int?
    var hadPendingBackgroundWorkAtStop: Bool?
    /// Unsandboxed Cursor shell calls that cmux asked Cursor to gate. The
    /// after/failure hooks do not carry a native approval decision, so the
    /// command identity is the only safe completion correlation available.
    var pendingCursorShellApprovals: [PendingCursorShellApproval]? = nil
    /// Command fingerprints cleared at a turn boundary. A recently reused
    /// command requires a stable tool id on completion because Cursor's
    /// command-only callback cannot distinguish an old delayed completion from
    /// the new turn's approval.
    var recentlyClearedCursorShellCommandFingerprints: [String: TimeInterval]? = nil
    /// Once the bounded command-only fence overflows, command-only
    /// correlation remains disabled for this session; re-enabling it after
    /// eviction would let an old delayed callback consume a newer approval.
    var cursorShellCommandOnlyCorrelationDisabled: Bool? = nil
}
