#if DEBUG
import CmuxAuthRuntime
import CmuxNextTransport
import Foundation
import Observation
import OSLog
import Security

/// Typed session state for the dial surface. `state` (the display string)
/// is derived from this; the facade's fallback decisions consume the typed
/// value, never the string.
public enum NextTransportDialState: Equatable, Sendable {
    case idle
    case connecting
    case ready
    case degraded
    /// Session ended. `denial` is non-nil exactly when the close code was a
    /// real admission denial (`DenialCode`), nil for transport-level ends
    /// (timeouts, network loss, local closes).
    case closed(code: String, denial: DenialCode?)

    /// Short display string for the dev screen and log lines.
    public var displayDescription: String {
        switch self {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .ready: return "ready"
        case .degraded: return "degraded"
        case .closed(let code, _): return "closed (\(code))"
        }
    }
#endif
