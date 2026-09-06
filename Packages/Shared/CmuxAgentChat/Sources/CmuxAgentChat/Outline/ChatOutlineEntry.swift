import Foundation

/// One user-authored turn in an agent conversation outline.
public struct ChatOutlineEntry: Identifiable, Sendable, Equatable {
    /// Stable transcript message identity.
    public let id: String

    /// Transcript line sequence for this turn.
    public let seq: Int

    /// Timestamp recorded for the prompt.
    public let timestamp: Date

    /// Compact first-line summary shown in the outline.
    public let title: String

    /// Whether the turn contains an actionable question or permission request.
    public let hasAlert: Bool

    /// Creates an outline entry.
    public init(id: String, seq: Int, timestamp: Date, title: String, hasAlert: Bool) {
        self.id = id
        self.seq = seq
        self.timestamp = timestamp
        self.title = title
        self.hasAlert = hasAlert
    }
}
