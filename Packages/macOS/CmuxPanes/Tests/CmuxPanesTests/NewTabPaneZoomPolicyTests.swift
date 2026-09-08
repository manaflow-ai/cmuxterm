import Bonsplit
import Testing
@testable import CmuxPanes

@MainActor
@Suite("NewTabPaneZoomPolicy")
struct NewTabPaneZoomPolicyTests {
    @Test("keeps the target pane zoomed when enabled")
    func keepsTargetPaneZoomed() throws {
        let controller = BonsplitController()
        let targetPane = try #require(controller.focusedPaneId)
        _ = try #require(controller.splitPane(targetPane, orientation: .horizontal))
        #expect(controller.togglePaneZoom(inPane: targetPane))

        let result = NewTabPaneZoomPolicy(keepExpanded: true).perform(
            inPane: targetPane,
            controller: controller,
            succeeded: { $0 }
        ) {
            true
        }

        #expect(result)
        #expect(controller.zoomedPaneId == targetPane)
    }

    @Test("retains the legacy clear behavior by default")
    func clearsZoomForSuccessfulCreation() throws {
        let controller = BonsplitController()
        let targetPane = try #require(controller.focusedPaneId)
        _ = try #require(controller.splitPane(targetPane, orientation: .horizontal))
        #expect(controller.togglePaneZoom(inPane: targetPane))

        let result = NewTabPaneZoomPolicy(keepExpanded: false).perform(
            inPane: targetPane,
            controller: controller,
            succeeded: { $0 }
        ) {
            true
        }

        #expect(result)
        #expect(controller.zoomedPaneId == nil)
    }

    @Test("clears zoom when an enabled request targets another pane")
    func clearsZoomForDifferentTargetPane() throws {
        let controller = BonsplitController()
        let zoomedPane = try #require(controller.focusedPaneId)
        let targetPane = try #require(controller.splitPane(zoomedPane, orientation: .horizontal))
        #expect(controller.togglePaneZoom(inPane: zoomedPane))

        _ = NewTabPaneZoomPolicy(keepExpanded: true).perform(
            inPane: targetPane,
            controller: controller,
            succeeded: { $0 }
        ) {
            true
        }

        #expect(controller.zoomedPaneId == nil)
    }

    @Test("restores the previous zoom after failed creation")
    func restoresZoomAfterFailure() throws {
        let controller = BonsplitController()
        let targetPane = try #require(controller.focusedPaneId)
        _ = try #require(controller.splitPane(targetPane, orientation: .horizontal))
        #expect(controller.togglePaneZoom(inPane: targetPane))
        var changes: [NewTabPaneZoomPolicy.Change] = []

        let result = NewTabPaneZoomPolicy(keepExpanded: false).perform(
            inPane: targetPane,
            controller: controller,
            succeeded: { $0 },
            onZoomChange: { changes.append($0) }
        ) {
            false
        }

        #expect(!result)
        #expect(controller.zoomedPaneId == targetPane)
        #expect(changes == [.cleared, .restored(targetPane)])
    }

    @Test("leaves zoom untouched for focus-neutral creation")
    func skipsPolicyWhenRequested() throws {
        let controller = BonsplitController()
        let targetPane = try #require(controller.focusedPaneId)
        _ = try #require(controller.splitPane(targetPane, orientation: .horizontal))
        #expect(controller.togglePaneZoom(inPane: targetPane))

        _ = NewTabPaneZoomPolicy(keepExpanded: false).perform(
            inPane: targetPane,
            controller: controller,
            applyPolicy: false,
            succeeded: { $0 }
        ) {
            true
        }

        #expect(controller.zoomedPaneId == targetPane)
    }
}
