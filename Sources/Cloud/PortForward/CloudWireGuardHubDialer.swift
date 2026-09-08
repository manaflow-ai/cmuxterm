import Foundation

/// ``CloudHubDialing`` over the app's one ``CloudWireGuardHub``: each claim is
/// one hub lease, so the hub stays up exactly while forwarded connections are
/// live (plus its own idle grace).
struct CloudWireGuardHubDialer: CloudHubDialing {
    let hub: CloudWireGuardHub

    func claimHubSocket() async throws -> CloudHubSocketClaim {
        let claim = try await hub.acquire()
        let hub = self.hub
        let lease = claim.lease
        return CloudHubSocketClaim(endpoint: .unix(path: claim.ready.socketPath)) {
            await hub.release(lease)
        }
    }
}
