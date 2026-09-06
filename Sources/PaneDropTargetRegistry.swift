import Foundation

@MainActor
final class PaneDropTargetRegistry {
    static let shared = PaneDropTargetRegistry()

    private struct Entry {
        weak var target: AnyObject?
        let reset: () -> Void
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(_ target: AnyObject, reset: @escaping () -> Void) {
        entries[ObjectIdentifier(target)] = Entry(target: target, reset: reset)
    }

    func resetAll() {
        entries = entries.filter { $0.value.target != nil }
        for entry in Array(entries.values) {
            entry.reset()
        }
    }
}
