import Foundation
import Testing

@testable import CMUXMobileCore

@Suite struct CmxRetryAfterPolicyTests {
    @Test func parsesDeltaSecondsAndHTTPDate() throws {
        #expect(CmxRetryAfterPolicy.seconds(from: "45") == 45)
        #expect(CmxRetryAfterPolicy.seconds(from: "0") == nil)
        #expect(CmxRetryAfterPolicy.seconds(from: "invalid") == nil)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        let header = formatter.string(from: now.addingTimeInterval(45))
        #expect(CmxRetryAfterPolicy.seconds(from: header, now: now) == 45)
    }

    @Test func serverDirectiveFloorsLocalBackoff() {
        #expect(CmxRetryAfterPolicy.delay(localSeconds: 2, retryAfterSeconds: 45) == 45)
        #expect(CmxRetryAfterPolicy.delay(localSeconds: 60, retryAfterSeconds: 45) == 60)
        #expect(CmxRetryAfterPolicy.delay(localSeconds: 2, retryAfterSeconds: nil) == 2)
    }

    @Test func cooldownExtendsAndNeverShortens() async {
        let time = RetryAfterTestTime()
        let gate = CmxRetryAfterGate(
            now: { time.now },
            sleep: { delay in time.advance(by: delay) }
        )

        await gate.extend(by: 45)
        await gate.extend(by: 10)
        #expect(await gate.remainingSeconds() == 45)
        try? await gate.wait()
        #expect(time.now == 45)
        #expect(await gate.remainingSeconds() == nil)
    }
}

private final class RetryAfterTestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        lock.withLock { value }
    }

    func advance(by delay: TimeInterval) {
        lock.withLock { value += delay }
    }
}
