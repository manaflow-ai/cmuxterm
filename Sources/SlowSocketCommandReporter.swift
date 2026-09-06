import Foundation

/// Times CLI socket commands and reports slow observations to a sink.
final class SlowSocketCommandReporter: Sendable {
    /// Commands taking at least this long are logged in release builds.
    static let slowThresholdMs: Double = 100

    private let sink: SlowSocketCommandSink

    init(sink: SlowSocketCommandSink = UnifiedLogSlowSocketCommandSink()) {
        self.sink = sink
    }

    static func isSlow(durationMs: Double) -> Bool {
        durationMs >= slowThresholdMs
    }

    func reportIfSlow(_ observation: SocketCommandObservation) {
        guard Self.isSlow(durationMs: observation.durationMs) else { return }
        sink.recordSlowCommand(observation)
    }
}
