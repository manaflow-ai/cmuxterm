import AppKit
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
}
