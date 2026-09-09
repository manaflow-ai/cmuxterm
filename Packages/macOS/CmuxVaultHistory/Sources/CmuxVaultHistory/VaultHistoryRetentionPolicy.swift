import Foundation

/// Memory and file-size bounds for the persisted History event log.
public struct VaultHistoryRetentionPolicy: Sendable {
    /// Maximum number of recorded events retained in memory and after compaction.
    public let maxStoredEvents: Int
    /// Maximum persisted JSONL size after an accepted append.
    public let maxFileBytes: Int
    /// Maximum number of tail bytes read while loading an existing log.
    /// Always covers the complete file budget so accepted records survive reload.
    public let maxLoadBytes: Int

    /// Production retention limits for the macOS History timeline.
    public static let `default` = VaultHistoryRetentionPolicy(
        maxStoredEvents: 2_000,
        maxFileBytes: 4 * 1_024 * 1_024,
        maxLoadBytes: 4 * 1_024 * 1_024
    )

    /// Creates a policy while enforcing nonzero operational minima.
    ///
    /// - Parameters:
    ///   - maxStoredEvents: Maximum number of retained events.
    ///   - maxFileBytes: Maximum persisted JSONL size after an accepted append.
    ///   - maxLoadBytes: Requested tail-read budget, raised to at least the file budget.
    public init(maxStoredEvents: Int, maxFileBytes: Int, maxLoadBytes: Int) {
        self.maxStoredEvents = max(1, maxStoredEvents)
        self.maxFileBytes = max(1_024, maxFileBytes)
        self.maxLoadBytes = max(self.maxFileBytes, maxLoadBytes)
    }
}
