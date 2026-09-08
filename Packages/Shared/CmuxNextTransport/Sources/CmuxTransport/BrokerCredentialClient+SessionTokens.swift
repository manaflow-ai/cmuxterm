import Foundation

extension BrokerCredentialClient {
    /// One coherent token pair from an already signed-in Stack session.
    public struct SessionTokens: Sendable {
        public let accessToken: String
        public let refreshToken: String

        public init(accessToken: String, refreshToken: String) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
        }
    }
}
