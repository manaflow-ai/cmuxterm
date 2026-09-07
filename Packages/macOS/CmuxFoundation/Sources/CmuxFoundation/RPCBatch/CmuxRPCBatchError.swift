/// A machine-readable batch validation or dependency failure.
public struct CmuxRPCBatchError: Error, Sendable {
    /// Stable error identifiers; display text belongs to the calling UI or CLI.
    public enum Code: String, Sendable {
        /// The input exceeds the byte or nesting limit.
        case inputLimit = "input_limit"
        /// The input is not a nonempty array of valid request objects.
        case invalidPlan = "invalid_plan"
        /// The plan exceeds the request-count limit.
        case requestLimit = "request_limit"
        /// A request ID is invalid or repeated.
        case invalidID = "invalid_id"
        /// A method cannot use a shared request-response connection.
        case unsupportedMethod = "unsupported_method"
        /// A reference is malformed or does not target an earlier request.
        case invalidReference = "invalid_reference"
        /// A referenced request failed or its result lacks the requested path.
        case unresolvedReference = "unresolved_reference"
    }

    /// The stable failure identifier.
    public let code: Code
    /// The zero-based request index, when a particular request is responsible.
    public let index: Int?

    /// Creates a failure without including potentially sensitive request values.
    /// - Parameters:
    ///   - code: The failure identifier.
    ///   - index: The responsible request index, or nil for input-wide failures.
    public init(_ code: Code, index: Int? = nil) {
        self.code = code
        self.index = index
    }
}
