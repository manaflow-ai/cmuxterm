import Testing
@testable import CmuxAgentJournal

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

    @Test func embeddedStatusCodesAndSensitiveDetailsFailClosed() {
        #expect(classifier.abnormalStopClass(signal: "Stop", message: "request-429-attempt") == nil)
        #expect(classifier.abnormalStopClass(signal: "Stop", message: "correlation_id=abc529xyz") == nil)
        #expect(classifier.isSensitiveProviderDetail("API error request_id=abc123") == true)
        #expect(classifier.isSensitiveProviderDetail("The provider stopped unexpectedly") == false)
    }
}
