import Foundation

extension BrokerCredentialClient {
    /// A broker-issued bearer credential scoped to one relay endpoint.
    public struct Credential: Sendable {
        /// Relay URL to which the token may be applied.
        public let relayUrl: String
        /// Secret relay admission token; never render it in diagnostics.
        public let token: String
        /// Expiry in Unix seconds, or nil when the broker supplied no usable expiry.
        public let expiresAt: Int64?
    }
}
