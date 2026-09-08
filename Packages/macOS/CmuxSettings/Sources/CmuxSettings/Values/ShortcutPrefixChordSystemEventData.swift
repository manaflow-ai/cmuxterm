/// Raw payload that distinguishes system-defined shortcut events from key events.
///
/// A system-defined event has no virtual key code. Keeping its complete payload
/// makes replay identity independent of keyboard-only platform accessors.
public struct ShortcutPrefixChordSystemEventData: Sendable, Equatable, Hashable {
    /// Platform subtype identifying the system event family.
    public let subtype: Int16
    /// First platform payload word, including media-key identity and state.
    public let data1: Int
    /// Second platform payload word.
    public let data2: Int

    /// Creates a complete system-event payload.
    ///
    /// - Parameters:
    ///   - subtype: Platform subtype identifying the event family.
    ///   - data1: First platform payload word.
    ///   - data2: Second platform payload word.
    public init(subtype: Int16, data1: Int, data2: Int) {
        self.subtype = subtype
        self.data1 = data1
        self.data2 = data2
    }
}
