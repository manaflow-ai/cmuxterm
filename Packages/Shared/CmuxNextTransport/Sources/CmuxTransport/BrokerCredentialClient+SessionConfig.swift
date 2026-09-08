import Foundation

extension BrokerCredentialClient {
    /// Session-mode target: the broker origin plus this endpoint's
    /// registration coordinates. No Stack fields by design — the session
    /// token provider owns authentication.
    public struct SessionConfig: Sendable {
        public var baseUrl: String
        public var deviceId: String
        public var appInstanceId: String
        public var tag: String
        public var platform: String

        public init(
            baseUrl: String, deviceId: String, appInstanceId: String,
            tag: String, platform: String
        ) {
            self.baseUrl = baseUrl
            self.deviceId = deviceId
            self.appInstanceId = appInstanceId
            self.tag = tag
            self.platform = platform
        }
    }
}
