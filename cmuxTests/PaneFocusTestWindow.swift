import AppKit

/// Models a responder that temporarily cannot take focus, without replacing
/// the panel's real AppKit views or exposing production-only test hooks.
@MainActor
final class PaneFocusTestWindow: NSWindow {
    weak var rejectedFirstResponder: NSResponder?
    private(set) var rejectedFocusAttempts = 0

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let rejectedFirstResponder, responder === rejectedFirstResponder {
            rejectedFocusAttempts += 1
            return false
        }
        return super.makeFirstResponder(responder)
    }
}
