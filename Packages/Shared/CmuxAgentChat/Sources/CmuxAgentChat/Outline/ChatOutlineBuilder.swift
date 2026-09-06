import Foundation

/// Reduces parsed transcript messages to navigable user-turn summaries.
public struct ChatOutlineBuilder: Sendable {
    /// Creates an outline builder.
    public init() {}

    /// Builds user-turn entries from parsed transcript messages.
    ///
    /// - Parameter messages: Messages in transcript order.
    /// - Returns: One entry per non-empty user prose message, with actionable
    ///   agent questions and permission requests attributed to the preceding
    ///   user turn.
    public func entries(from messages: [ChatMessage]) -> [ChatOutlineEntry] {
        []
    }
}
