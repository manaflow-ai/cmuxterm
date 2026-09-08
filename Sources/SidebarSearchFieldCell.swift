import AppKit
import SwiftUI

/// Replace only the bezel drawing; native search and editor geometry stay intact.
@MainActor
final class SidebarSearchFieldCell: NSSearchFieldCell {
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
