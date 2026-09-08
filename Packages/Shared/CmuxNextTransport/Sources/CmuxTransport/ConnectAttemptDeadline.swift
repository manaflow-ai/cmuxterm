/// Races one admission attempt against an injected deadline.
public struct ConnectAttemptDeadline: Sendable {
    /// Creates a deadline runner with no shared mutable state.
    public init() {}

    /// Runs the attempt and cancels the losing operation.
    ///
    /// The deadline operation normally waits on a cancellable clock. Both
    /// operations must respond to cancellation, including waking native I/O.
    ///
    /// ```swift
    /// let outcome = try await ConnectAttemptDeadline().run(
    ///     connect: dialAndAdmit,
    ///     timeout: { try await ContinuousClock().sleep(for: .seconds(6)) })
    /// ```
    ///
    /// - Parameters:
    ///   - connect: Dials and admits one connection, cleaning up on failure.
    ///   - timeout: Waits for the deadline; cancellation must end this wait.
    /// - Returns: The winning admission result.
    /// - Throws: The attempt error, cancellation, or ``TransportError/dialTimeout``.
    public func run(
        connect: @escaping @Sendable () async throws -> ConnectAttemptResult,
        timeout: @escaping @Sendable () async throws -> Void
    ) async throws -> ConnectAttemptResult {
        try await withThrowingTaskGroup(of: ConnectAttemptResult.self) { group in
            group.addTask { try await connect() }
            group.addTask {
                try await timeout()
                throw TransportError.dialTimeout
            }
            guard let first = try await group.next() else {
                throw TransportError.dialTimeout
            }
            group.cancelAll()
            return first
        }
    }
}
