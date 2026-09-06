/// Legacy default sidebar tint values.
public struct WindowChromeSidebarTintDefaults: Sendable {
    /// Default tint hex value.
    public let hex: String

    /// Default tint opacity.
    public let opacity: Double

    /// Creates sidebar tint defaults.
    public init(
        hex: String = "#2a2e35",
        opacity: Double = 0.44
    ) {
        self.hex = hex
        self.opacity = opacity
    }
}
