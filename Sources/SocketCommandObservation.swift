import Foundation

/// Structured description of a completed CLI socket command.
///
/// Contains no command payload or user data; only sanitized protocol/method
/// identity, timing, routing facts, peer pid, and response size.
struct SocketCommandObservation: Sendable, Equatable {
    let protocolName: String
    let method: String
    let durationMs: Double
    let executedOnMain: Bool
    let peerPid: pid_t?
    let responseByteCount: Int

    init(
        descriptor: SocketCommandDescriptor,
        durationMs: Double,
        responseByteCount: Int
    ) {
        self.protocolName = descriptor.protocolName
        self.method = descriptor.method
        self.durationMs = durationMs
        self.executedOnMain = descriptor.executedOnMain
        self.peerPid = descriptor.peerPid
        self.responseByteCount = responseByteCount
    }

    init(
        protocolName: String,
        method: String,
        durationMs: Double,
        executedOnMain: Bool,
        peerPid: pid_t?,
        responseByteCount: Int
    ) {
        self.protocolName = protocolName
        self.method = method
        self.durationMs = durationMs
        self.executedOnMain = executedOnMain
        self.peerPid = peerPid
        self.responseByteCount = responseByteCount
    }
}
