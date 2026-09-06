import Foundation
import Bonsplit

@MainActor
final class PaneDropTargetRegistry {
    private struct Entry {
        weak var target: AnyObject?
        let reset: () -> Void
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    nonisolated init() {}

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

@MainActor
final class NativeDragCoordinator {
    let paneDropTargetRegistry = PaneDropTargetRegistry()

    private(set) var tabDragTransferRegistry: TabDragTransferRegistry
    private var nativeDragEndObserverID: UUID?

    init() {
        self.init(tabDragTransferRegistry: TabDragTransferRegistry())
    }

    init(tabDragTransferRegistry: TabDragTransferRegistry) {
        self.tabDragTransferRegistry = tabDragTransferRegistry
        observeNativeDragEnds(on: tabDragTransferRegistry)
    }

    func adopt(tabDragTransferRegistry: TabDragTransferRegistry) {
        guard self.tabDragTransferRegistry !== tabDragTransferRegistry else { return }
        if let nativeDragEndObserverID {
            self.tabDragTransferRegistry.removeNativeDragEndObserver(nativeDragEndObserverID)
        }
        self.tabDragTransferRegistry = tabDragTransferRegistry
        observeNativeDragEnds(on: tabDragTransferRegistry)
    }

    private func observeNativeDragEnds(on registry: TabDragTransferRegistry) {
        nativeDragEndObserverID = registry.addNativeDragEndObserver { [weak self] in
            self?.paneDropTargetRegistry.resetAll()
        }
    }
}
