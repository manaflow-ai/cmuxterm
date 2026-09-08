import AppKit

/// Replace only the bezel drawing; native search and editor geometry stay intact.
@MainActor
final class SidebarSearchFieldCell: NSSearchFieldCell {
    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7).fill()
        super.drawInterior(withFrame: frame, in: controlView)
    }
}
