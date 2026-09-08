import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #12084: a restore must not give up on the first
/// `busy` answer from the app's ownership scan.
///
/// Right after a relaunch several restored panes fire their session-start
/// hooks at once, so the app's ownership-sensitive process scan cannot settle
/// for a few seconds and answers `busy` with `retryable`. Aborting on that
/// answer left a bare shell whose binding then retired, so resumes only worked
/// once. The CLI now waits through a bounded delay budget.
@Suite struct RestoreAdmissionRetryPolicyTests {
    private struct AdmissionFailure: Error {
        let retryable: Bool
    }

    private static func isRetryable(_ error: Error) -> Bool {
        (error as? AdmissionFailure)?.retryable == true
    }

    @Test
    func retryableBusyIsRetriedUntilAdmitted() throws {
        var sends = 0
        var slept: [TimeInterval] = []
        var retriesAnnounced: [Int] = []

        let response = try AgentRestoreAdmissionRetry.response(
            delays: [0.5, 1, 2],
            sleep: { slept.append($0) },
            onRetry: { retriesAnnounced.append($0) },
            isRetryable: Self.isRetryable
        ) { () throws -> [String: Bool] in
            sends += 1
            if sends < 3 { throw AdmissionFailure(retryable: true) }
            return ["admitted": true]
        }

        #expect(response["admitted"] == true)
        #expect(sends == 3)
        #expect(slept == [0.5, 1])
        #expect(retriesAnnounced == [0, 1])
    }

    @Test
    func exhaustedBudgetPropagatesTheLastBusyAnswer() {
        var sends = 0
        var slept: [TimeInterval] = []

        #expect(throws: AdmissionFailure.self) {
            try AgentRestoreAdmissionRetry.response(
                delays: [0.5, 1],
                sleep: { slept.append($0) },
                isRetryable: Self.isRetryable
            ) { () throws -> Bool in
                sends += 1
                throw AdmissionFailure(retryable: true)
            }
        }
        #expect(sends == 3)
        #expect(slept == [0.5, 1])
    }

    @Test
    func nonRetryableFailuresAreNotRetried() {
        var sends = 0
        var slept: [TimeInterval] = []

        #expect(throws: AdmissionFailure.self) {
            try AgentRestoreAdmissionRetry.response(
                delays: [0.5, 1],
                sleep: { slept.append($0) },
                isRetryable: Self.isRetryable
            ) { () throws -> Bool in
                sends += 1
                throw AdmissionFailure(retryable: false)
            }
        }
        #expect(sends == 1)
        #expect(slept.isEmpty)
    }

    @Test
    func defaultBudgetWaitsLongEnoughForAHookStormToSubside() {
        let total = AgentRestoreAdmissionRetry.delaysSeconds.reduce(0, +)
        #expect(total >= 30)
        #expect(total <= 60)
        #expect(AgentRestoreAdmissionRetry.delaysSeconds.first.map { $0 <= 1 } == true)
    }
}

/// Deferred restores wait for the ownership scan to settle instead of
/// cancelling every restore on the first unsettled pass (#12084).
@Suite struct LiveAgentIndexSettleTests {
    @Test
    func settledIndexRetriesUntilTheScanSettles() async {
        var refreshes = 0
        var pauses = 0

        let index = await SharedLiveAgentIndex.settledIndex(
            attempts: 4,
            pause: { pauses += 1 },
            refresh: {
                refreshes += 1
                return refreshes == 3 ? RestorableAgentSessionIndex.empty : nil
            }
        )

        #expect(index != nil)
        #expect(refreshes == 3)
        #expect(pauses == 2)
    }

    @Test
    func settledIndexGivesUpAfterTheAttemptBudget() async {
        var refreshes = 0
        var pauses = 0

        let index = await SharedLiveAgentIndex.settledIndex(
            attempts: 3,
            pause: { pauses += 1 },
            refresh: {
                refreshes += 1
                return nil
            }
        )

        #expect(index == nil)
        #expect(refreshes == 3)
        #expect(pauses == 2)
    }

    @Test
    func settledIndexTreatsNonPositiveAttemptsAsOne() async {
        var refreshes = 0

        let index = await SharedLiveAgentIndex.settledIndex(
            attempts: 0,
            pause: {},
            refresh: {
                refreshes += 1
                return nil
            }
        )

        #expect(index == nil)
        #expect(refreshes == 1)
        #expect(SharedLiveAgentIndex.deferredRestoreSettleAttempts > 1)
    }
}
