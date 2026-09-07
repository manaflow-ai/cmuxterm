import Foundation

@MainActor
final class SessionOutlineChangeBus {
    private struct Observer {
        let surfaceID: String
        let continuation: AsyncStream<Void>.Continuation
    }

    private var observers: [UUID: Observer] = [:]

    func stream(surfaceID: String) -> AsyncStream<Void> {
        let observerID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            self?.observers[observerID] = Observer(
                surfaceID: surfaceID,
                continuation: continuation
            )
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.observers.removeValue(forKey: observerID)
                }
            }
        }
    }

    func yield(surfaceID: String?) {
        guard let surfaceID, !surfaceID.isEmpty else { return }
        for observer in observers.values where observer.surfaceID == surfaceID {
            observer.continuation.yield()
        }
    }
}
