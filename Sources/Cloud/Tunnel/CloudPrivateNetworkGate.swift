import Foundation

/// The gate used only by Cloud browser navigation. Terminals and their
/// metadata use the separate user-space WireGuard hub.
protocol CloudPrivateNetworkGate: Sendable {
    /// Require a working route before a browser is allowed to navigate to a
    /// private address. This fails closed. `onStateChange` reports every
    /// tunnel state the wait passes through (the current one first), so the
    /// caller can show the person what the wait is blocked on: a start that
    /// is waiting on the system-extension approval never resolves by itself.
    func requirePrivateNetworkUse(
        _ use: CloudPrivateNetworkUse,
        onStateChange: @escaping @Sendable (CloudTunnelState) -> Void
    ) async throws
}

extension CloudPrivateNetworkGate {
    func requirePrivateNetworkUse(_ use: CloudPrivateNetworkUse) async throws {
        try await requirePrivateNetworkUse(use, onStateChange: { _ in })
    }
}

/// What is about to dial the private network, for logging and consumer
/// accounting.
