import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileRPC
import CmuxMobileTransport
import Foundation

/// The Mac's `MobileSyncRuntime`: what the shared RPC client needs from the
/// app to dial another Mac. Tokens come through ``HiveAccountTokenSource``,
/// bound to the account generation and team scope the directory was built for
/// (the same identity the host verifies): after a sign-out or account switch
/// every token call fails instead of carrying the next account's token.
/// Transports come from the shared Network.framework factory the iOS app uses,
/// restricted to the route kinds ``DeviceRouteSelector`` admits.
struct DeviceLinkRuntime: MobileSyncRuntime {
    let transportFactory: any CmxByteTransportFactory
    let stackAccessTokenProvider: @Sendable () async throws -> String
    let stackAccessTokenForceRefresher: @Sendable () async throws -> String
    let stackAccessTokenForStatusProvider: @Sendable () async -> String?
    let supportedRouteKinds: [CmxAttachTransportKind]
    let rpcRequestTimeoutNanoseconds: UInt64
    let pairingRequestTimeoutNanoseconds: UInt64
    let now: @Sendable () -> Date
    let supportsServerPushEvents: Bool = true

    init(
        tokens: HiveAccountTokenSource,
        routeSelector: DeviceRouteSelector = DeviceRouteSelector(),
        rpcRequestTimeoutNanoseconds: UInt64 = 20_000_000_000,
        pairingRequestTimeoutNanoseconds: UInt64 = 10_000_000_000,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        transportFactory = CmxNetworkByteTransportFactory(supportedKinds: routeSelector.supportedKinds)
        stackAccessTokenProvider = { try await tokens.session().accessToken }
        stackAccessTokenForceRefresher = { try await tokens.refresh() }
        stackAccessTokenForStatusProvider = { await tokens.cachedToken() }
        supportedRouteKinds = routeSelector.supportedKinds
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.now = now
    }
}
