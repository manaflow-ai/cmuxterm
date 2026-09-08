#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

/// One persisted last-good relay credential: enough to re-attach the relay
/// on next launch without a broker round trip. Stored (JSON array) in a
/// macOS Keychain generic-password item; never in UserDefaults.
struct NextTransportCachedRelayCredential: Codable, Sendable, Equatable {
    var relayUrl: String
    var token: String
    /// Epoch seconds at which the relay stops honoring the token, when the
    /// broker exposed a claim. `nil` credentials remain in the cache and use
    /// the bounded fallback renewal cadence.
    var expiresAt: Int64?
}
#endif
