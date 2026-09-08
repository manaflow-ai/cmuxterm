import Foundation

extension BrokerCredentialClient {
    public struct Credential: Sendable {
        public let relayUrl: String
        public let token: String
        public let expiresAt: Int64?
    }
}
