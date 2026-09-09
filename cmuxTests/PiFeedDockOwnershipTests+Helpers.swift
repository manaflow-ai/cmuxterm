import CMUXAgentLaunch
import Combine
import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension PiFeedDockOwnershipTests {
    func withAppContext(
        _ body: @MainActor (AppDelegate, TabManager, Workspace, UUID) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            appDelegate.didAttemptStartupSessionRestore = true
            let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            let workspace = manager.addWorkspace(select: true)
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowID)
                manager.tabs.forEach { $0.teardownAllPanels() }
                appDelegate.tabManager = nil
                AppDelegate.shared = previousAppDelegate
            }

            try await body(appDelegate, manager, workspace, windowID)
        }
    }

    static func acknowledgmentPayload(
        _ result: TerminalController.V2CallResult
    ) throws -> [String: Any] {
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any] else {
            Issue.record("expected authoritative Pi Feed insertion, got \(result)")
            return [:]
        }
        return payload
    }

    static func ingestAcknowledgedOffMainActor(
        _ events: [WorkstreamEvent]
    ) async -> TerminalController.V2CallResult {
        let resultBox = PiFeedV2CallResultBox()
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                resultBox.value = TerminalController.shared.v2IngestAcknowledgedFeedEvents(events)
                continuation.resume()
            }
        }
        return resultBox.value!
    }
}
