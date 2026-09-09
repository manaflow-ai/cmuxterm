import Combine
import CmuxCore
import CMUXAgentLaunch
import Darwin
import Foundation
import Observation
import Testing

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceSidebarObservationTests {
}

// Mutable flag captured by Observation's Sendable onChange closure in this test.
final class ObservationChangeFlag: @unchecked Sendable {
    private(set) var fired = false

    func mark() {
        fired = true
    }
}

final class DemandControlledSubscriber<Input>: Subscriber {
    typealias Failure = Never

    private var subscription: Subscription?
    private(set) var received: [Input] = []
    private(set) var completionCount = 0
    private(set) var receivedValuesAtCompletion: [[Input]] = []
    var onValue: ((Input) -> Void)?

    func receive(subscription: Subscription) {
        self.subscription = subscription
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        received.append(input)
        onValue?(input)
        return .none
    }

    func receive(completion: Subscribers.Completion<Never>) {
        completionCount += 1
        receivedValuesAtCompletion.append(received)
    }

    func request(_ demand: Subscribers.Demand) {
        subscription?.request(demand)
    }

    func cancel() {
        subscription?.cancel()
        subscription = nil
    }
}
// Deterministic Combine scheduler for coalesceLatest tests: `now` only moves
// via advance(by:), and scheduled actions run only when runScheduledActions()
// is called, so overdue-timer interleavings are exact instead of wall-clock.
final class VirtualCoalesceScheduler: Scheduler {
    typealias SchedulerTimeType = RunLoop.SchedulerTimeType
    typealias SchedulerOptions = Never

    private(set) var now = SchedulerTimeType(Date(timeIntervalSinceReferenceDate: 0))
    var minimumTolerance: SchedulerTimeType.Stride { .seconds(0) }
    private var scheduledActions: [() -> Void] = []

    var scheduledActionCount: Int { scheduledActions.count }

    func advance(by seconds: TimeInterval) {
        now = SchedulerTimeType(now.date.addingTimeInterval(seconds))
    }

    func runScheduledActions() {
        let actions = scheduledActions
        scheduledActions = []
        actions.forEach { $0() }
    }

    func schedule(options: Never?, _ action: @escaping () -> Void) {
        action()
    }

    func schedule(
        after date: SchedulerTimeType,
        tolerance: SchedulerTimeType.Stride,
        options: Never?,
        _ action: @escaping () -> Void
    ) {
        scheduledActions.append(action)
    }

    func schedule(
        after date: SchedulerTimeType,
        interval: SchedulerTimeType.Stride,
        tolerance: SchedulerTimeType.Stride,
        options: Never?,
        _ action: @escaping () -> Void
    ) -> Cancellable {
        scheduledActions.append(action)
        return AnyCancellable {}
    }
}
