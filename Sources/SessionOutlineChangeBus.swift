import Foundation

@MainActor
final class SessionOutlineChangeBus {
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]

    func stream() -> AsyncStream<String> {
        let observerID = UUID()
        return AsyncStream { [weak self] continuation in
            self?.continuations[observerID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations.removeValue(forKey: observerID)
                }
            }
        }
    }

    func yield(surfaceID: String?) {
        guard let surfaceID, !surfaceID.isEmpty else { return }
        for continuation in continuations.values {
            continuation.yield(surfaceID)
        }
    }
}
