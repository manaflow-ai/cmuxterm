/// A transport adapter's classification of a failed RPC call.
public struct CmuxRPCBatchCallFailure: Error, Sendable {
    /// A stable protocol or transport error code.
    public let code: String
    /// The transport's diagnostic text.
    public let message: String
    /// True only for a complete server error response that leaves the connection reusable.
    public let canContinue: Bool

    /// Classifies a failed call without retrying it.
    /// - Parameters:
    ///   - code: A machine-readable error code.
    ///   - message: The diagnostic returned by the transport.
    ///   - canContinue: Whether another request can safely use the same connection.
    public init(code: String, message: String, canContinue: Bool) {
        self.code = code
        self.message = message
        self.canContinue = canContinue
    }
}
