#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

/// Cache-first startup policy: which persisted credentials are still worth
/// binding with, and how a fresh mint becomes cache entries.
struct NextTransportRelayCredentialCachePolicy: Sendable {
    /// A cached token must outlive "now" by this margin to be included in
    /// the endpoint's initial relay map; anything tighter would expire
    /// during the bind/handshake and produce a silently dead relay route.
    let reuseMarginSeconds: Int64

    init(reuseMarginSeconds: Int64 = 30) {
        self.reuseMarginSeconds = reuseMarginSeconds
    }

    func usable(
        _ cached: [NextTransportCachedRelayCredential],
        now: Int64,
        marginSeconds: Int64? = nil
    ) -> [NextTransportCachedRelayCredential] {
        let marginSeconds = marginSeconds ?? reuseMarginSeconds
        return cached.filter { credential in
            guard let expiresAt = credential.expiresAt else { return true }
            return expiresAt > now + marginSeconds
        }
    }

    /// Cache entries from a fresh mint. `Credential.expiresAt` is populated
    /// whenever an expiry is knowable (server value or the token's own JWT
    /// `exp`); a credential with no visible expiry cannot be validity-checked
    /// at the next launch, so it remains cached and follows the bounded
    /// fallback cadence rather than disabling renewal permanently.
    func entries(
        from credentials: [BrokerCredentialClient.Credential]
    ) -> [NextTransportCachedRelayCredential] {
        credentials.map { credential in
            NextTransportCachedRelayCredential(
                relayUrl: credential.relayUrl, token: credential.token,
                expiresAt: credential.expiresAt)
        }
    }

    func encode(_ entries: [NextTransportCachedRelayCredential]) -> Data? {
        try? JSONEncoder().encode(entries)
    }

    func decode(_ data: Data) -> [NextTransportCachedRelayCredential] {
        (try? JSONDecoder().decode([NextTransportCachedRelayCredential].self, from: data)) ?? []
    }
}
#endif
