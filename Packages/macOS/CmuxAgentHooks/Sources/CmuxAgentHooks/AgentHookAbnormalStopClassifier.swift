import Foundation

/// Classifies provider stop signals without depending on app or UI state.
public struct AgentHookAbnormalStopClassifier: Sendable {
    /// Creates a stateless classifier for one managed-agent stop boundary.
    public init() {}

    /// Returns the stable failure class for a provider banner, if one is
    /// present. The caller can use this predicate without choosing a UI.
    public func abnormalStopClass(signal: String, message: String) -> AgentHookAbnormalStopClass? {
        guard isStopSignal(signal) else { return nil }
        let lower = "\(signal) \(message)".lowercased()
        guard !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let normalized = lower
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let normalizedSignal = signal
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let normalizedMessage = message
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        // An explicit user abort is never promoted to a provider error, even
        // if stale text from a previous response is attached.
        guard !isUserInitiatedStop(signal: signal, message: message) else { return nil }

        // A final response can mention a transient failure while still
        // completing the requested work. Only a strong provider-banner marker
        // may override an explicit completion sentence.
        // Transcript terminal event names such as `task_complete` are part of
        // the signal, not the provider's response. Evaluate completion prose
        // against the response itself so a terminal event cannot hide a real
        // capacity/timeout banner. Conversely, a response that says a
        // transient request failed but then completed remains a normal turn.
        if Self.containsCompletionCue(normalizedMessage),
           !containsStrongProviderFailureCue(normalizedMessage) {
            return nil
        }

        let normalizedMessageTrimmed = normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasonOnlyMessage = normalizedMessageTrimmed.hasPrefix("stop ")
            ? String(normalizedMessageTrimmed.dropFirst("stop ".count))
            : normalizedMessageTrimmed
        let normalizedSignalTrimmed = normalizedSignal.trimmingCharacters(in: .whitespacesAndNewlines)
        let signalReasonOnly = normalizedSignalTrimmed.hasPrefix("stop ")
            ? String(normalizedSignalTrimmed.dropFirst("stop ".count))
            : normalizedSignalTrimmed

        let overloadCue = (normalized.contains("overloaded") || normalized.contains("overload"))
            && (
                normalized.contains("server")
                    || normalized.contains("model")
                    || normalized.contains("provider")
                    || normalized.contains("service")
                    || normalized.contains("api")
                    || normalized.contains("error")
                    || normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines) == "overloaded"
                    || normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines) == "overload"
            )
        let status529Cue = hasStatusCodeCue(
            "529",
            normalized: normalized,
            normalizedMessage: normalizedMessage
        )
        let capacityCue = normalized.contains("at capacity")
            || normalized.contains("over capacity")
            || normalized.contains("capacity reached")
            || normalized.contains("capacity error")
            || normalized.contains("model capacity")
            || normalized.contains("capacity exceeded")
            || normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines) == "capacity"
            || overloadCue
            || normalized.contains("server overloaded")
            || normalized.contains("overloaded error")
            || status529Cue
            || signalReasonOnly == "capacity"
            || signalReasonOnly == "overload"
            || signalReasonOnly == "overloaded"
            || signalReasonOnly == "529"
        let messageTokens = Self.notificationCueTokens(normalizedMessage)
        let providerCapacityQualifiers: Set<Substring> = [
            "model", "server", "provider", "service", "api", "error", "llm", "endpoint",
        ]
        let providerCapacityQualifier = messageTokens.contains {
            providerCapacityQualifiers.contains($0)
        }
        let explicitCapacityReason = [
            "capacity", "at capacity", "overload", "overloaded", "529",
            "stop capacity", "stop at capacity", "stop overload", "stop overloaded", "stop 529",
        ].contains {
            reasonOnlyMessage == $0 || signalReasonOnly == $0
        }
        if capacityCue && (providerCapacityQualifier || explicitCapacityReason) {
            return .capacity
        }
        let quotaCue = normalized.contains("usage limit")
            || normalized.contains("hit your limit")
            || normalized.contains("limit reached")
            || normalized.contains("usage exhausted")
            || normalized.contains("quota exceeded")
            || normalized.contains("quota exhausted")
            || normalized.contains("quota limit")
            || normalized.contains("credit limit")
            || normalized.contains("credits exhausted")
            || normalized.contains("no remaining credits")
            || normalized.contains("out of credits")
            || normalized.contains("insufficient credits")
            || (normalized.contains("quota") && (
                normalized.contains("error")
                    || normalized.contains("reached")
                    || normalized.contains("remaining")
                    || normalized.contains("reset")
            ))
        let explicitQuotaReason = reasonOnlyMessage == "quota exceeded"
            || reasonOnlyMessage == "quota exhausted"
            || reasonOnlyMessage == "usage limit"
            || reasonOnlyMessage == "usage exhausted"
            || reasonOnlyMessage == "limit reached"
            || reasonOnlyMessage == "quota limit"
            || reasonOnlyMessage == "credit limit"
            || reasonOnlyMessage == "credits exhausted"
            || reasonOnlyMessage == "no remaining credits"
            || reasonOnlyMessage == "out of credits"
            || reasonOnlyMessage == "insufficient credits"
            || reasonOnlyMessage.hasPrefix("you've hit your usage limit")
            || reasonOnlyMessage.hasPrefix("you have hit your usage limit")
        let quotaTokens = Self.notificationCueTokens(normalizedMessage)
        let quotaProviderQualifiers: Set<Substring> = [
            "api", "model", "provider", "service", "server", "llm", "endpoint",
            "error", "reset", "retry", "remaining", "credits", "credit",
        ]
        let quotaHasProviderContext = quotaTokens.contains { quotaProviderQualifiers.contains($0) }
        if quotaCue && (explicitQuotaReason || quotaHasProviderContext) {
            return .quota
        }
        let rateLimitCue = normalized.contains("rate limit")
            || normalized.contains("rate limited")
            || normalized.contains("too many requests")
            || (normalized.contains("throttl") && (
                normalized.contains("error")
                    || normalized.contains("request")
                    || normalized.contains("api")
                    || normalized.contains("provider")
                    || normalized.contains("rate")
            ))
            || hasStatusCodeCue(
                "429",
                normalized: normalized,
                normalizedMessage: normalizedMessage
            )
        let rateLimitReasonOnly = [
            "rate limit", "rate limited", "too many requests", "429", "429 too many requests",
        ].contains(reasonOnlyMessage)
        let rateLimitSignalReason = [
            "rate limit", "rate limited", "too many requests", "429", "429 too many requests",
        ].contains(signalReasonOnly)
        let rateLimitProviderContext: Set<Substring> = [
            "api", "endpoint", "error", "failed", "failure", "gateway", "http", "model",
            "provider", "request", "response", "server", "service", "status",
        ]
        let rateLimitHasProviderContext = messageTokens.contains {
            rateLimitProviderContext.contains($0)
        }
        if rateLimitSignalReason
            || (rateLimitCue && (rateLimitReasonOnly || rateLimitHasProviderContext)) {
            return .rateLimit
        }
        let timeoutCue = normalized.contains("request timed out")
            || normalized.contains("request timeout")
            || (normalized.contains("timed out") && (
                normalized.contains("error")
                    || normalized.contains("request")
                    || normalized.contains("connection")
                    || normalized.contains("stream")
                    || normalized.contains("api")
                    || containsStrongProviderFailureCue(normalizedMessage)
            ))
            || normalized.contains("deadline exceeded")
            || normalized.contains("gateway timeout")
            || normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines) == "timeout"
            || normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines) == "etimedout"
            || signalReasonOnly == "timeout"
            || signalReasonOnly == "etimedout"
            || (normalized.contains("timeout") && (
                normalized.contains("error")
                    || normalized.contains("failed")
                    || normalized.contains("operation")
                    || normalized.contains("connection")
                    || normalized.contains("request")
            ))
            || (normalized.contains("etimedout") && normalized.contains("error"))
        if timeoutCue {
            return .timeout
        }
        let authenticationCue = normalized.contains("authentication error")
            || normalized.contains("auth error")
            || normalized.contains("authentication token")
            || normalized.contains("unauthorized")
            || normalized.contains("invalid api key")
            || normalized.contains("expired api key")
            || normalized.contains("token expired")
            || normalized.contains("token has expired")
            || normalized.contains("expired token")
            || normalized.contains("session expired")
            || normalized.contains("auth expired")
            || normalized.contains("login required")
            || normalized.contains("sign in to continue")
        if authenticationCue {
            let authenticationReasonOnly = [
                "authentication error", "auth error", "authentication token", "unauthorized",
                "invalid api key", "expired api key", "token expired", "token has expired",
                "expired token", "session expired", "auth expired", "login required",
                "sign in to continue",
            ].contains(reasonOnlyMessage)
            let authenticationSignalReason = [
                "authentication error", "auth error", "authentication token", "unauthorized",
                "invalid api key", "expired api key", "token expired", "token has expired",
                "expired token", "session expired", "auth expired", "login required",
                "sign in to continue",
            ].contains(signalReasonOnly)
            let authenticationProviderContext: Set<Substring> = [
                "api", "endpoint", "error", "failed", "failure", "gateway", "http", "key",
                "provider", "request", "response", "server", "service", "status", "token",
            ]
            let authenticationHasProviderContext = messageTokens.contains {
                authenticationProviderContext.contains($0)
            }
            guard authenticationSignalReason
                || authenticationReasonOnly
                || authenticationHasProviderContext else {
                return nil
            }
            return .authentication
        }
        let networkCue = normalized.contains("connection refused")
            || normalized.contains("connection reset")
            || normalized.contains("stream disconnected")
            || normalized.contains("network error")
            || normalized.contains("service unavailable")
            || normalized.contains("temporarily unavailable")
            || normalized.contains("502 bad gateway")
            || normalized.contains("503 service unavailable")
            || normalized.contains("504 gateway")
        if networkCue {
            let networkReasonOnly = [
                "connection refused", "connection reset", "stream disconnected", "network error",
                "service unavailable", "temporarily unavailable", "502 bad gateway",
                "503 service unavailable", "504 gateway",
            ].contains(reasonOnlyMessage)
            let networkSignalReason = [
                "connection refused", "connection reset", "stream disconnected", "network error",
                "service unavailable", "temporarily unavailable", "502 bad gateway",
                "503 service unavailable", "504 gateway",
            ].contains(signalReasonOnly)
            let networkProviderContext: Set<Substring> = [
                "api", "connection", "endpoint", "error", "failed", "failure", "gateway", "http",
                "network", "provider", "request", "response", "server", "service", "status",
            ]
            let networkHasProviderContext = messageTokens.contains {
                networkProviderContext.contains($0)
            }
            guard networkSignalReason || networkReasonOnly || networkHasProviderContext else {
                return nil
            }
            return .network
        }

        guard !Self.containsCompletionCue(normalizedMessage) else {
            return nil
        }
        if containsExplicitGenericFailureCue(normalized) {
            return .generic
        }
        return nil
    }

    /// Identifies an explicit user cancellation without classifying it as a
    /// provider failure. Callers use this to discard stale error payloads.
    public func isUserInitiatedStop(signal: String, message: String) -> Bool {
        containsUserInitiatedStopCue(signal)
            || containsUserInitiatedStopCue(message)
    }

    /// Recognizes the terminal hook event names that can carry a provider
    /// banner. Other notification events remain fail-closed.
    public func isStopSignal(_ signal: String) -> Bool {
        let lower = signal.lowercased()
        let tokens = Self.notificationCueTokens(lower)
        if tokens.contains(where: { token in
            token == "stop"
                || token == "stopped"
                || token == "stophook"
                || token == "stopfailure"
        }) {
            return true
        }
        let compact = tokens.joined()
        return compact == "turnaborted"
            || compact == "stopfailure"
            || compact == "stophook"
            || compact == "taskcomplete"
            || compact == "turncomplete"
    }

    private static func containsCompletionCue(_ lowercasedText: String) -> Bool {
        notificationCueTokens(lowercasedText).contains { token in
            token == "done"
                || token == "succeed"
                || token == "succeeded"
                || token.hasPrefix("complet")
                || token.hasPrefix("finish")
                || token.hasPrefix("success")
        }
    }

    private static func notificationCueTokens(_ lowercasedText: String) -> [Substring] {
        lowercasedText.split { !$0.isLetter && !$0.isNumber }
    }

    /// Reports whether a provider message contains details that must stay out of UI.
    public func isSensitiveProviderDetail(_ text: String) -> Bool {
        containsSensitiveProviderDetail(text)
    }

    private func containsUserInitiatedStopCue(_ lowercasedText: String) -> Bool {
        let normalized = lowercasedText
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "=", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.contains("interrupted by user")
            || normalized.contains("cancelled by user")
            || normalized.contains("canceled by user")
            || normalized.contains("aborted by user")
            || normalized.contains("stopped by user")
            || normalized.contains("user cancelled")
            || normalized.contains("user canceled")
            || normalized.contains("user interrupt")
            || normalized.contains("user abort")
            || normalized == "user requested"
            || normalized.contains("stop user requested")
            || normalized.contains("user requested stop")
            || normalized.contains("user requested abort")
            || normalized.contains("user requested cancellation")
            || normalized.contains("stop requested by user")
            || normalized == "command /exit"
            || normalized.contains("/exit requested")
            || normalized == "/exit"
            || normalized.contains("interrupted by ctrl c")
            || normalized.contains("cancelled by ctrl c")
            || normalized.contains("canceled by ctrl c")
            || normalized.contains("stopped by ctrl c")
            || normalized.contains("received sigint")
            || normalized.contains("terminated by sigint")
            || normalized.contains("keyboard interrupt received")
            || (normalized.contains("turn aborted") && (
                normalized.contains("user")
                    || normalized.contains("interrupt")
                    || normalized.contains("cancel")
            ))
            || normalized.trimmingCharacters(in: .whitespacesAndNewlines) == "user abort"
    }

    private func containsStrongProviderFailureCue(_ lowercasedText: String) -> Bool {
        lowercasedText.contains("■")
            || lowercasedText.contains("api error")
            || lowercasedText.contains("error:")
            || lowercasedText.contains("failed:")
            || lowercasedText.contains("failure:")
            || lowercasedText.contains("overloaded error")
            || lowercasedText.contains("rate limit error")
            || lowercasedText.contains("authentication error")
            || lowercasedText.contains("server overloaded")
            || lowercasedText.contains("529")
            || lowercasedText.contains("429")
    }

    /// Matches an HTTP-like status code only when it is a standalone token
    /// with a nearby status/provider cue, or when the entire message is the
    /// concise provider reason. Identifiers such as `request-429-attempt` do
    /// not carry enough context to promote a stop into a rate-limit error.
    private func hasStatusCodeCue(
        _ code: String,
        normalized: String,
        normalizedMessage: String
    ) -> Bool {
        let messageTrimmed = normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasonOnlyMessage = messageTrimmed.hasPrefix("stop ")
            ? String(messageTrimmed.dropFirst("stop ".count))
            : messageTrimmed
        if reasonOnlyMessage == code { return true }

        let tokens = Self.notificationCueTokens(normalized)
        guard let index = tokens.firstIndex(where: { String($0) == code }) else { return false }
        let lowerBound = max(0, index - 3)
        let upperBound = min(tokens.count, index + 4)
        let contextTokens = tokens[lowerBound..<upperBound]
        let context: Set<Substring> = [
            "api", "capacity", "code", "error", "failed", "failure", "gateway",
            "http", "limit", "many", "model", "overload", "overloaded", "provider",
            "rate", "server", "service", "status", "too", "unavailable",
        ]
        return contextTokens.contains { context.contains($0) }
    }

    private func containsSensitiveProviderDetail(_ text: String) -> Bool {
        let patterns = [
            #"(?i)\b(?:authorization|proxy-authorization|cookie|set-cookie|bearer|basic|api[_ -]?key|access[_ -]?token|refresh[_ -]?token)\s*[:=]"#,
            #"(?i)\b(?:request|trace|correlation|session|turn|event)[_ -]?id\s*[:=]"#,
            #"(?i)\b(?:stack trace|traceback|private key|credential|secret|payload|headers?)\b"#,
            #"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
            #"https?://\S+"#,
            #"\{[^{}]{2,}\}"#,
            #"(?i)\bat\s+[A-Za-z0-9_./-]+\([^)]*\)"#,
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private func containsExplicitGenericFailureCue(_ lowercasedText: String) -> Bool {
        guard !lowercasedText.contains("no error"),
              !lowercasedText.contains("without error"),
              !lowercasedText.contains("error-free") else {
            return false
        }
        return lowercasedText.contains("api error")
            || lowercasedText.contains("error:")
            || lowercasedText.contains("failed:")
            || lowercasedText.contains("failure:")
            || lowercasedText.contains("exception:")
            || lowercasedText.contains("fatal:")
            || lowercasedText.contains("fatal error")
            || lowercasedText.contains("stop failure")
            || lowercasedText.contains("stopfailure")
    }

}
