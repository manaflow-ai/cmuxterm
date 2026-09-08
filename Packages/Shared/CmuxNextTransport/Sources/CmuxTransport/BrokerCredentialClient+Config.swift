import Foundation

extension BrokerCredentialClient {
    public struct Config: Sendable, Decodable {
        public var baseUrl: String
        public var stackBase: String
        public var stackProjectId: String
        public var stackPck: String
        public var email: String
        public var password: String
        public var deviceId: String
        public var appInstanceId: String
        public var tag: String
        public var platform: String

        public init(
            baseUrl: String, stackBase: String, stackProjectId: String,
            stackPck: String, email: String, password: String,
            deviceId: String, appInstanceId: String, tag: String, platform: String
        ) {
            self.baseUrl = baseUrl
            self.stackBase = stackBase
            self.stackProjectId = stackProjectId
            self.stackPck = stackPck
            self.email = email
            self.password = password
            self.deviceId = deviceId
            self.appInstanceId = appInstanceId
            self.tag = tag
            self.platform = platform
        }
    }
}
