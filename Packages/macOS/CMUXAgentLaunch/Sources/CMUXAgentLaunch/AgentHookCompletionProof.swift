import Foundation

/// Validates the structured proof attached to an agent stop hook before the
/// app treats its assistant message as a normal completion.
///
/// Provider hooks may echo a refusal, quota banner, or transport error as the
/// last assistant message. This value keeps that boundary decision in the
/// agent-launch package so CLI integration only supplies the hook payload.
public struct AgentHookCompletionProof {
    private let classifier: AgentStallClassifier

    /// Creates a completion proof using the supplied stall classifier.
    ///
    /// - Parameter classifier: Rules used to reject known provider failures.
    public init(classifier: AgentStallClassifier = AgentStallClassifier()) {
        self.classifier = classifier
    }

    /// Returns whether a hook payload carries an explicit failure witness.
    ///
    /// This is separate from ``provesNormalCompletion`` because callers that
    /// forward terminal output to the stall classifier need to preserve the
    /// structured-evidence bit even when the assistant message is absent or
    /// itself is a provider failure banner.
    public func containsStructuredFailureEvidence(payload: [String: Any]?) -> Bool {
        agentHookPayloadContainsStructuredFailure(payload)
    }

    /// Returns whether a stop hook proves a healthy assistant response.
    ///
    /// - Parameters:
    ///   - provider: Managed provider identifier or alias.
    ///   - assistantMessage: The provider's last assistant message.
    ///   - payload: Raw structured hook payload, when one was supplied.
    /// - Returns: `true` only when the message is non-empty, has no structured
    ///   failure signal, and does not match a known stall banner.
    public func provesNormalCompletion(
        provider: String,
        assistantMessage: String?,
        payload: [String: Any]?
    ) -> Bool {
        guard let assistantMessage,
              !normalizedAgentStallOutput(assistantMessage).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let hasStructuredFailureEvidence = agentHookPayloadContainsStructuredFailure(payload)
        guard !hasStructuredFailureEvidence else {
            return false
        }
        return classifier.classify(
            provider: provider,
            output: assistantMessage,
            // Ambiguous phrases (for example, "try again later") require an
            // actual structured failure envelope. A normal hook payload, or a
            // nil payload, must not turn an ordinary assistant message into a
            // retry signal.
            hasStructuredEvidence: hasStructuredFailureEvidence
        ) == nil
    }
}

private func agentHookPayloadContainsStructuredFailure(_ value: Any?) -> Bool {
    guard let value else { return false }
    if let dictionary = value as? [String: Any] {
        for (key, child) in dictionary {
            let normalizedKey = key
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
            if [
                "error", "errorcode", "iserror", "failure", "failurecode",
                "codexerrorinfo",
            ].contains(normalizedKey),
               agentHookStructuredFailureValueIsPresent(child) {
                return true
            }
            if agentHookPayloadContainsStructuredFailure(child) {
                return true
            }
        }
        return false
    }
    if let array = value as? [Any] {
        return array.contains { agentHookPayloadContainsStructuredFailure($0) }
    }
    return false
}

private func agentHookStructuredFailureValueIsPresent(_ value: Any) -> Bool {
    if value is NSNull { return false }
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue || number.intValue != 0 }
    if let string = value as? String {
        let normalized = normalizedAgentStallOutput(string)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty
            && !["false", "null", "none", "0", "ok", "success"].contains(normalized)
    }
    if let dictionary = value as? [String: Any] { return !dictionary.isEmpty }
    if let array = value as? [Any] { return !array.isEmpty }
    return true
}
