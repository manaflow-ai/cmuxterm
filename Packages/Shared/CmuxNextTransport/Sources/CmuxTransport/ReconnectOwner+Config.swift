import Foundation

extension ReconnectOwner {
    public struct Config: Sendable {
        public var initialBackoff: Duration
        public var maxBackoff: Duration

        public init(
            initialBackoff: Duration = .milliseconds(400),
            maxBackoff: Duration = .seconds(30)
        ) {
            self.initialBackoff = initialBackoff
            self.maxBackoff = maxBackoff
        }
    }

}
