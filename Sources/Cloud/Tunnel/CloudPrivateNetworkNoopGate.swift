import Foundation

struct CloudPrivateNetworkNoopGate: CloudPrivateNetworkGate {
    func requirePrivateNetworkUse(
        _ use: CloudPrivateNetworkUse,
        onStateChange: @escaping @Sendable (CloudTunnelState) -> Void
    ) async throws {}
}
