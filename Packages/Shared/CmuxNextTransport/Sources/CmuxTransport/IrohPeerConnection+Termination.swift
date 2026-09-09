import Foundation
import IrohLib

extension IrohPeerConnection {
    /// The known code vocabulary, longest-first so "grant-expired" wins over
    /// its substring "expired" when parsing the rendered close cause.
    private static let knownTerminationCodes: [String] = {
        let denials = DenialCode.allCases.map(\.rawValue)
        let closes = [
            CloseReason.grantExpired.code, CloseReason.superseded.code,
            CloseReason.modeSwitched.code, CloseReason.userRequested.code,
            CloseReason.explicitRedial.code, CloseReason.admissionDenied.code,
            CloseReason.faultInjected.code,
        ]
        return (denials + closes).sorted { $0.count > $1.count }
    }()

    /// Await only after observing a lane EOF: resolves once the connection's
    /// close cause is known, and parses our reason bytes back out of it.
    public func termination() async -> ConnectionTermination? {
        if let local = localTermination { return local }
        let rendered: String
        if let reason = connection.closeReason() {
            rendered = reason
        } else if localCloseRequested {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) termination: local close \
                    with no reason recorded -> nil
                    """)
            }
            return nil
        } else {
            // A lane EOF is not proof that the QUIC connection itself closed:
            // peers can finish the control stream while retaining the session
            // for another lane. Waiting on `closed()` here would strand the
            // reconnect owner forever, so let it classify this as the
            // ordinary connection-lost case and schedule capped redial.
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    "conn \(TransportDebugLog.id(self), privacy: .public) termination: lane EOF without close cause -> nil")
            }
            return nil
        }
        for code in Self.knownTerminationCodes where Self.renderedReasonContains(rendered, code: code) {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) termination parsed \
                    code=\(code, privacy: .public) \
                    rendered=\(rendered, privacy: .public)
                    """)
            }
            // The matcher above accepts only reason-shaped boundaries, so the
            // recovered code is the structured lifecycle value exposed to the
            // reconnect owner; unrelated diagnostic substrings are ignored.
            return ConnectionTermination(code: code, authority: .authoritative)
        }
        // An unrecognized peer application close is intentionally surfaced as
        // an ambiguity marker. Reconnect policy must not redial a session that
        // may have been superseded merely because a future FFI version changed
        // the human-readable reason format. Transport timeout/reset diagnostics
        // do not match this predicate and retain automatic recovery.
        if Self.renderedPeerApplicationClose(rendered) {
            return ConnectionTermination(code: "connection-lost", authority: .ambiguous)
        }
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) termination UNPARSED \
                rendered=\(rendered, privacy: .public) -> nil
                """)
        }
        return nil
    }

    /// Matches only reason-shaped renderings, never an arbitrary substring of
    /// a transport diagnostic (for example `not-expired`). Local closes use
    /// ``localTermination`` above; this parser is solely a conservative bridge
    /// for remote FFI strings that have no structured reason accessor.
    private static func renderedReasonContains(_ rendered: String, code: String) -> Bool {
        let value = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == code || value.hasSuffix(" \(code)") || value.hasSuffix(":\(code)") {
            return true
        }
        // Current iroh-ffi renders an application close as
        // `closed by peer: <reason> (code <n>)`; future versions may quote the
        // reason or add a prefix. Extract only the token immediately following
        // a reason-labelled boundary, never an arbitrary diagnostic substring.
        for marker in [
            "closed by peer: ", "aborted by peer: ", "reason=", "reason: ",
            "reason \"", "reason='"
        ] {
            guard let range = value.range(of: marker, options: .backwards) else { continue }
            let tail = value[range.upperBound...]
            let token = tail.split(whereSeparator: {
                $0 == " " || $0 == "(" || $0 == ")" || $0 == ","
                    || $0 == "\"" || $0 == "'" || $0 == ":"
            }).first.map(String.init)
            if token == code { return true }
        }
        return false
    }

    /// Returns true for a peer application-close diagnostic without trusting
    /// any reason text inside it. This is only an ambiguity fence for retry
    /// policy; it never claims a lifecycle code.
    private static func renderedPeerApplicationClose(_ rendered: String) -> Bool {
        let value = rendered.lowercased()
        return value.hasPrefix("closed by peer")
            || value.hasPrefix("aborted by peer")
            || value.contains("connectionclosed(")
            || value.contains("applicationclosed(")
            || (value.contains("peer") && value.contains("closed")
                && (value.contains("code") || value.contains("reason")))
    }

}
