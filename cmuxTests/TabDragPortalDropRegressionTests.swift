import AppKit
import Bonsplit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TabDragPortalDropRegressionTests: XCTestCase {
    func testLiveTabDragRoutesTerminalPortalMouseUpWithoutPaneLatch() {
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .leftMouseUp,
                hasActiveDropDrag: false,
                hasLiveTabTransfer: true
            ),
            "A live tab tear-out must reach the pane target even when the target missed drag entry"
        )
    }

    func testNativeDragEndObserverResetsRegisteredTargets() throws {
        let registry = TabDragTransferRegistry()
        let targetRegistry = PaneDropTargetRegistry()
        let target = ResettableTarget()
        targetRegistry.register(target) {
            target.resetCount += 1
        }
        var observerCalls = 0
        let observerID = registry.addNativeDragEndObserver {
            targetRegistry.resetAll()
            observerCalls += 1
        }
        defer { registry.removeNativeDragEndObserver(observerID) }

        let transfer = TabDragTransfer(
            tab: Tab(
                id: TabID(),
                title: "dragged",
                icon: "terminal.fill",
                kind: "terminal"
            ),
            sourcePaneId: PaneID()
        )
        let registration = try XCTUnwrap(registry.register(transfer))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.issue-11156.test"))
        XCTAssertTrue(registration.write(to: pasteboard))

        registry.endNativeDrag(registration)

        XCTAssertEqual(observerCalls, 1)
        XCTAssertEqual(target.resetCount, 1)
        XCTAssertNil(registry.resolve(from: pasteboard))
    }

    func testAcceptedDropDoesNotLookLikeNativeDragEnd() throws {
        let registry = TabDragTransferRegistry()
        var observerCalls = 0
        let observerID = registry.addNativeDragEndObserver {
            observerCalls += 1
        }
        defer { registry.removeNativeDragEndObserver(observerID) }

        let transfer = TabDragTransfer(
            tab: Tab(title: "dragged", icon: "terminal.fill", kind: "terminal"),
            sourcePaneId: PaneID()
        )
        let registration = try XCTUnwrap(registry.register(transfer))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.issue-11156.accepted"))
        XCTAssertTrue(registration.write(to: pasteboard))

        registry.finish(from: pasteboard)

        XCTAssertEqual(observerCalls, 0)
        XCTAssertNil(registry.resolve(from: pasteboard))
    }

    private final class ResettableTarget {
        var resetCount = 0
    }
}
