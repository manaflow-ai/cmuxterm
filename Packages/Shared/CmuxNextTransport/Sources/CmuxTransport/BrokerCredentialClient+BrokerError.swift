import Foundation

extension BrokerCredentialClient {
    public enum BrokerError: Error, CustomStringConvertible {
        /// An HTTP step failed. Carries only redaction-safe fields: the
        /// step name, status code, request URL path (never the query), and
        /// the short stable error code the broker returns as JSON
        /// `{"error": <code>}` (web/services/iroh/routeHandler.ts) when one
        /// parses. Raw response bodies can echo access/refresh tokens, so
        /// they are never stored, logged, or rendered.
        case http(step: String, status: Int, path: String, code: String?)
        /// A request URL could not be built from the configured base URL.
        /// Carries only a sanitized origin, or a fixed invalid-origin marker.
        case malformedURL(step: String, url: String)
        case shape(String)
        /// Session mode only: the token provider reported no signed-in
        /// session. Fail closed — never mint as a guessed account.
        case notSignedIn

        public var description: String {
            switch self {
            case .http(let step, let status, let path, let code):
                let suffix = code.map { " error=\($0)" } ?? ""
                return "\(step) failed: HTTP \(status) path=\(path)\(suffix)"
            case .malformedURL(let step, let url):
                return "\(step) failed: malformed request URL \(url)"
            case .shape(let what):
                return "unexpected response shape: \(what)"
            case .notSignedIn:
                return "no signed-in session; cannot mint relay credentials"
            }
        }
    }
}
