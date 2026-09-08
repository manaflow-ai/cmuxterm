import AppKit
import SwiftUI

/// Shared bezel and icon alignment; AppKit owns text editing and button handling.
@MainActor
final class SidebarSearchFieldCell: NSSearchFieldCell {
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        var buttonRect = super.searchButtonRect(forBounds: rect)
        let center = RightSidebarChromeMetrics.contentIconCenter - SidebarSearchField.leadingPadding
        buttonRect.origin.x = rect.minX + center - buttonRect.width / 2
        return buttonRect
    }

    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setFillColor(NSColor.labelColor.withAlphaComponent(0.06).cgColor)
            context.addPath(RoundedRectangle(
                cornerRadius: RightSidebarChromeMetrics.controlCornerRadius,
                style: .continuous
            ).path(in: frame).cgPath)
            context.fillPath()
            context.restoreGState()
        }
        super.drawInterior(withFrame: frame, in: controlView)
    }
}
