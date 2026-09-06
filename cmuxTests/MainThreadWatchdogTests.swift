import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Records watchdog callbacks for deterministic state-machine assertions.
///
/// Safety: mutable records are protected by `lock`.
private final class RecordingWatchdogReporter: MainThreadSocketCommandWatchdogReporter, @unchecked Sendable {
    struct Hang: Equatable {
        let elapsedMs: Double
        let method: String
        let backtrace: [String]
    }

    struct Recovery: Equatable {
        let elapsedMs: Double
        let method: String
    }

    // Protects records captured from a Sendable reporter during synchronous tests.
    private let lock = NSLock()
    private var _hangs: [Hang] = []
    private var _recoveries: [Recovery] = []

    var hangs: [Hang] {
        lock.lock()
        defer { lock.unlock() }
        return _hangs
    }

    var recoveries: [Recovery] {
        lock.lock()
        defer { lock.unlock() }
        return _recoveries
    }

    func reportHang(_ observation: MainThreadSocketCommandWatchdogObservation) {
        lock.lock()
        _hangs.append(.init(
            elapsedMs: observation.elapsedMs,
            method: observation.descriptor.method,
            backtrace: observation.backtrace
        ))
        lock.unlock()
    }

    func reportRecovery(_ observation: MainThreadSocketCommandWatchdogObservation) {
        lock.lock()
        _recoveries.append(.init(
            elapsedMs: observation.elapsedMs,
            method: observation.descriptor.method
        ))
        lock.unlock()
    }
}

/// Fixed backtrace provider so watchdog tests do not inspect process symbols.
private struct FixedBacktraceCapturer: SocketCommandBacktraceCapturing {
    let frames: [String]

    func captureBacktrace() -> [String] {
        frames
    }
}

@Suite
struct MainThreadWatchdogTests {
    private let ms: UInt64 = 1_000_000

    private func descriptor(method: String = "browser.eval") -> SocketCommandDescriptor {
        SocketCommandDescriptor(
            protocolName: "v2",
            method: method,
            executedOnMain: true,
            peerPid: 4242
        )
    }

    private func makeTicket(
        reporter: RecordingWatchdogReporter,
        thresholdMs: Double = 1000,
        backtrace: [String] = ["frame-0", "frame-1"]
    ) -> MainThreadSocketCommandWatchdogTicket {
        MainThreadSocketCommandWatchdogTicket(
            descriptor: descriptor(),
            thresholdMs: thresholdMs,
            startNs: 0,
            reporter: reporter,
            backtraceCapturer: FixedBacktraceCapturer(frames: backtrace)
        )
    }

    @Test
    func noHangReportedBelowThreshold() {
        let reporter = RecordingWatchdogReporter()
        let ticket = makeTicket(reporter: reporter)

        ticket.fireIfNeeded(nowNs: 999 * ms)

        #expect(reporter.hangs.isEmpty)
        #expect(reporter.recoveries.isEmpty)
    }

    @Test
    func hangIncludesCommandIdentityAndBacktraceAtThreshold() {
        let reporter = RecordingWatchdogReporter()
        let ticket = makeTicket(reporter: reporter, backtrace: ["watchdog", "dispatch"])

        ticket.fireIfNeeded(nowNs: 1000 * ms)

        #expect(reporter.hangs.count == 1)
        #expect(reporter.hangs[0].method == "browser.eval")
        #expect(abs(reporter.hangs[0].elapsedMs - 1000) < 0.0001)
        #expect(reporter.hangs[0].backtrace == ["watchdog", "dispatch"])
    }

    @Test
    func sustainedHangReportsOnlyOnceForCommand() {
        let reporter = RecordingWatchdogReporter()
        let ticket = makeTicket(reporter: reporter)

        ticket.fireIfNeeded(nowNs: 1000 * ms)
        ticket.fireIfNeeded(nowNs: 2000 * ms)
        ticket.fireIfNeeded(nowNs: 4000 * ms)

        #expect(reporter.hangs.count == 1)
        #expect(reporter.recoveries.isEmpty)
    }

    @Test
    func recoveryReportedOnceAfterHangCompletes() {
        let reporter = RecordingWatchdogReporter()
        let ticket = makeTicket(reporter: reporter)

        ticket.fireIfNeeded(nowNs: 1000 * ms)
        ticket.finish(nowNs: 2500 * ms)
        ticket.finish(nowNs: 3000 * ms)

        #expect(reporter.hangs.count == 1)
        #expect(reporter.recoveries.count == 1)
        #expect(reporter.recoveries[0].method == "browser.eval")
        #expect(abs(reporter.recoveries[0].elapsedMs - 2500) < 0.0001)
    }

    @Test
    func finishingBeforeThresholdPreventsLaterHang() {
        let reporter = RecordingWatchdogReporter()
        let ticket = makeTicket(reporter: reporter)

        ticket.finish(nowNs: 250 * ms)
        ticket.fireIfNeeded(nowNs: 2000 * ms)

        #expect(reporter.hangs.isEmpty)
        #expect(reporter.recoveries.isEmpty)
    }
}
