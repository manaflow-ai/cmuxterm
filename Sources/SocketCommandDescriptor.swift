import Foundation

/// Sanitized identity and routing metadata for one CLI socket command.
struct SocketCommandDescriptor: Sendable, Equatable {
    let protocolName: String
    let method: String
    let executedOnMain: Bool
    let peerPid: pid_t?
}
