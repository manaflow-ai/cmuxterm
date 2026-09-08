import AppKit
import Foundation
import GhosttyKit

extension GhosttyConfig {
    func parseGhosttyColor(_ value: String) -> NSColor? {
        var color = ghostty_config_color_s()
        let parsed = value.withCString { valuePointer in
            ghostty_config_color_parse(
                valuePointer,
                UInt(value.lengthOfBytes(using: .utf8)),
                &color
            )
        }
        guard parsed else { return nil }

        return NSColor(
            srgbRed: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1
        )
    }
}
