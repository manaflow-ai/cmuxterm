import Foundation

extension TransportHost {
    public struct ActiveSession: Sendable {
        public let id: String
        public let connection: any PeerConnection
        /// Kept for in-session renewal verification (3.6c): a renewal must be
        /// for the SAME key, device, and app the session was admitted with.
        public var deviceKey: Data
        public var grant: PairingGrant
        public var warnedExpiring = false
        /// The per-session service loops (control, echo, chat). Stored so
        /// every removal path can CANCEL them: on a half-open connection the
        /// lanes never EOF, and unstored loops outlive the session forever.
        var serviceTasks: [Task<Void, Never>] = []

        func cancelServices() {
            for task in serviceTasks { task.cancel() }
        }
    }

}
