import CmuxFoundation
import CmuxSwiftRenderUI
import Foundation
import Observation

/// Loads, watches, and evaluates the default sidebar's custom ordering file.
@MainActor
@Observable
final class SidebarWorkspaceOrderScriptModel {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/cmux/sidebar-order.js")

    private(set) var sourceRevision: UInt64 = 0
    private(set) var orderedWorkspaceIds: [UUID] = []
    private(set) var loadErrorMessage: String?
    private(set) var evaluationErrorMessage: String?

    var errorMessage: String? {
        loadErrorMessage ?? evaluationErrorMessage
    }

    @ObservationIgnored private var source: String?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    func start() {
        guard watchTask == nil else { return }
        reload()
        let watcher = FileWatcher(path: Self.fileURL.path, throttle: .milliseconds(150))
        self.watcher = watcher
        watchTask = Task { [weak self] in
            for await _ in watcher.events {
                guard let self, !Task.isCancelled else { return }
                self.reload()
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        if let watcher {
            self.watcher = nil
            Task { await watcher.stop() }
        }
    }

    func evaluate(workspaces: [SidebarWorkspaceSortScriptInput]) async {
        guard let source else { return }
        let revision = sourceRevision
        let result = await Task.detached(priority: .utility) {
            SidebarWorkspaceSortScriptEvaluator.evaluate(
                source: source,
                workspaces: workspaces
            )
        }.value
        guard !Task.isCancelled, sourceRevision == revision else { return }
        switch result {
        case .success(let ids):
            orderedWorkspaceIds = ids
            evaluationErrorMessage = nil
        case .failure(let error):
            // Keep the last valid order while the file is being edited.
            evaluationErrorMessage = error.message
        }
    }

    private func reload() {
        defer { sourceRevision &+= 1 }
        guard FileManager.default.fileExists(atPath: Self.fileURL.path) else {
            source = nil
            loadErrorMessage = "Missing \(Self.fileURL.path)"
            return
        }
        do {
            source = try String(contentsOf: Self.fileURL, encoding: .utf8)
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }
}
