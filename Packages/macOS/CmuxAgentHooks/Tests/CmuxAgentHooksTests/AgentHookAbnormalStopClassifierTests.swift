import Testing
@testable import CmuxAgentHooks

@Suite("Agent hook abnormal-stop classifier")
struct AgentHookAbnormalStopClassifierTests {
    private let classifier = AgentHookAbnormalStopClassifier()

    @Test(arguments: [
        ("Selected model is at capacity. Please try again.", AgentHookAbnormalStopClass.capacity),
        ("server overloaded", .capacity),
        ("quota exceeded", .quota),
        ("429 Too Many Requests", .rateLimit),
        ("request timed out", .timeout),
        ("authentication token expired", .authentication),
        ("network error: connection reset", .network),
        ("API error: request failed", .generic),
    ] as [(String, AgentHookAbnormalStopClass)])
    func classifiesProviderStopBanners(entry: (String, AgentHookAbnormalStopClass)) {
        let (message, expected) = entry
        #expect(classifier.abnormalStopClass(signal: "Stop", message: message) == expected)
    }

    @Test func ignoresLocalAndHistoricalProse() {
        let messages = [
            "The local job queue is at capacity",
            "The report says quota exceeded for a previous run.",
            "The first request timed out, but the retry completed successfully.",
        ]
        for message in messages {
            #expect(classifier.abnormalStopClass(signal: "Stop", message: message) == nil)
        }
    }

    @Test func userCancellationWinsOverStaleProviderText() {
        #expect(classifier.isUserInitiatedStop(
            signal: "Stop",
            message: "Selected model is at capacity; interrupted by user (Ctrl+C)"
        ))
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "Selected model is at capacity; interrupted by user (Ctrl+C)"
        ) == nil)
    }

    @Test func recognizesStructuredUserRequestedReasonWithEventName() {
        #expect(classifier.isUserInitiatedStop(
            signal: "Stop user_requested task_complete",
            message: "Selected model is at capacity"
        ))
    }

    @Test func doesNotTreatInstructionalOrProviderCancellationProseAsUserAbort() {
        #expect(!classifier.isUserInitiatedStop(
            signal: "Stop",
            message: "Press Ctrl+C to stop the server"
        ))
        #expect(!classifier.isUserInitiatedStop(
            signal: "Stop",
            message: "cancelled"
        ))
        #expect(!classifier.isUserInitiatedStop(
            signal: "Stop",
            message: "The provider cancelled the request"
        ))
    }

    @Test func requiresProviderContextForAmbiguousFailureProse() {
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "The guide explains rate limit handling"
        ) == nil)
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "rate limit"
        ) == .rateLimit)
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "The API request hit a rate limit"
        ) == .rateLimit)
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "The guide explains that session expired means sign-in is needed"
        ) == nil)
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "session expired"
        ) == .authentication)
    }

    @Test func recognizesStructuredProviderReasonsWithoutMessage() {
        #expect(classifier.abnormalStopClass(signal: "Stop rate_limit", message: "") == .rateLimit)
        #expect(classifier.abnormalStopClass(signal: "Stop capacity", message: "") == .capacity)
        #expect(classifier.abnormalStopClass(signal: "Stop overload", message: "") == .capacity)
        #expect(classifier.abnormalStopClass(signal: "Stop timeout", message: "") == .timeout)
        #expect(classifier.abnormalStopClass(signal: "Stop unauthorized", message: "") == .authentication)
        #expect(classifier.abnormalStopClass(signal: "Stop connection refused", message: "") == .network)
    }

    @Test func embeddedStatusCodesAndSensitiveDetailsFailClosed() {
        #expect(classifier.abnormalStopClass(signal: "Stop", message: "request-429-attempt") == nil)
        #expect(classifier.abnormalStopClass(signal: "Stop", message: "correlation_id=abc529xyz") == nil)
        #expect(classifier.isSensitiveProviderDetail("API error request_id=abc123") == true)
        #expect(classifier.isSensitiveProviderDetail("The provider stopped unexpectedly") == false)
    }
}
