import CmuxVaultHistory
import Foundation
import Observation

/// Main-actor owner that coordinates lifecycle recording and History refreshes.
///
/// The app composition root constructs exactly one instance and injects it into
/// every lifecycle producer and History consumer. ``phase`` is the single gate
/// for launch, restore, and termination suppression; accepted events serialize
/// through the actor-backed store before ``revision`` changes.
@MainActor
@Observable
final class VaultHistoryEventLog {
    private(set) var revision: UInt64 = 0
    private(set) var phase: VaultHistoryRecordingPhase

    private let store: any VaultHistoryEventStoring
    private var pendingRecordTask: Task<Void, Never>?
    private var pendingRecordCount = 0
    /// Uncommitted window operations cannot publish an open or any child event.
    private var pendingWindowEvents: [UUID: [VaultHistoryEvent]] = [:]
    /// A retained window can finish construction before startup recording is active.
    /// Keep its committed events until the lifecycle gate opens instead of dropping them.
    private var pendingLaunchCommittedEvents: [VaultHistoryEvent] = []

    /// Whether accepted records are still queued or being persisted.
    var hasPendingRecords: Bool {
        pendingRecordCount > 0 || !pendingLaunchCommittedEvents.isEmpty
    }

    init(
        store: any VaultHistoryEventStoring,
        phase: VaultHistoryRecordingPhase = .launching
    ) {
        self.store = store
        self.phase = phase
    }

    func transition(to phase: VaultHistoryRecordingPhase) {
        self.phase = phase
        guard phase == .active || phase == .terminating else { return }
        let events = pendingLaunchCommittedEvents
        pendingLaunchCommittedEvents.removeAll(keepingCapacity: true)
        for event in events {
            // These snapshots were accepted when their windows committed.
            // Termination closes the gate to new events, not to this queue.
            enqueueAcceptedRecord(event)
        }
    }

    func record(_ event: VaultHistoryEvent) {
        if let windowId = event.subject.windowId, pendingWindowEvents[windowId] != nil {
            pendingWindowEvents[windowId, default: []].append(event)
            return
        }
        guard phase == .active else { return }
        enqueueAcceptedRecord(event)
    }

    private func enqueueAcceptedRecord(_ event: VaultHistoryEvent) {
        let store = store
        let previous = pendingRecordTask
        pendingRecordCount += 1
        pendingRecordTask = Task(priority: .utility) { [weak self] in
            await previous?.value
            let didAppend: Bool
            if Task.isCancelled {
                didAppend = false
            } else {
                didAppend = await store.append(event)
            }
            guard let self else { return }
            if didAppend {
                self.revision &+= 1
            }
            self.pendingRecordCount -= 1
            if self.pendingRecordCount == 0 {
                self.pendingRecordTask = nil
            }
        }
    }

    func beginWindowCreation(windowId: UUID) {
        pendingWindowEvents[windowId] = []
    }

    /// Publishes the original event snapshots exactly once after the window is retained.
    ///
    /// A deferred startup restore may need to suppress only the initial
    /// bootstrap open/create pair while retaining user actions that happened
    /// before the readiness callback completed.
    func commitWindowCreation(windowId: UUID, excludingBootstrapWorkspaceId: UUID? = nil) {
        guard let events = pendingWindowEvents.removeValue(forKey: windowId) else { return }
        let retainedEvents = events.filter { event in
            if let excludingBootstrapWorkspaceId,
               (event.kind == .windowOpened
                || (event.kind == .workspaceCreated
                    && event.subject.workspaceId == excludingBootstrapWorkspaceId)) {
                return false
            }
            return true
        }
        if phase == .launching {
            pendingLaunchCommittedEvents.append(contentsOf: retainedEvents)
        } else {
            for event in retainedEvents {
                record(event)
            }
        }
    }

    /// Failed bootstrap operations never enter the append-only store.
    func discardWindowCreation(windowId: UUID) {
        pendingWindowEvents.removeValue(forKey: windowId)
        pendingLaunchCommittedEvents.removeAll { $0.subject.windowId == windowId }
    }

    func recentEvents(limit: Int = Int.max) async -> [VaultHistoryEvent] {
        await store.recentEvents(limit: limit)
    }

    /// Drains all scheduled appends, including ones accepted during suspension.
    /// Launch commits stay staged until recording becomes active or terminates.
    func flushPendingRecords() async {
        while let task = pendingRecordTask {
            await task.value
        }
    }
}
