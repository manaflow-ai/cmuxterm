#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

/// Mint-failure backoff: halve the remaining validity per retry (never a
/// hot loop — 10 s floor), and once past expiry keep trying at a bounded
/// cadence. A failed mint never tears the endpoint down.
struct NextTransportMintRetryPolicy: Sendable {
    let minimumDelaySeconds: Int64
    let expiredCadenceSeconds: Int64

    init(minimumDelaySeconds: Int64 = 10, expiredCadenceSeconds: Int64 = 60) {
        self.minimumDelaySeconds = minimumDelaySeconds
        self.expiredCadenceSeconds = expiredCadenceSeconds
    }

    func retryDelay(earliestExpiry: Int64?, now: Int64) -> Int64 {
        guard let earliestExpiry, earliestExpiry > now else {
            return expiredCadenceSeconds
        }
        return max((earliestExpiry - now) / 2, minimumDelaySeconds)
    }
}
#endif
