import Foundation

@MainActor
final class SessionOutlineState {
    let changeBus = SessionOutlineChangeBus()
    var cache = SessionOutlineCache()

    func invalidate(sessionID: String, surfaceID: String?) {
        cache.invalidate(sessionID: sessionID)
        changeBus.yield(surfaceID: surfaceID)
    }

    func yield(surfaceIDs: [String?]) {
        changeBus.yield(surfaceIDs: surfaceIDs)
    }

    func remove(sessionID: String, surfaceID: String?) {
        cache.remove(sessionID: sessionID)
        changeBus.yield(surfaceID: surfaceID)
    }
}
