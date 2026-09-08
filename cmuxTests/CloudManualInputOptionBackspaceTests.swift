import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import CmuxTerminal
import GhosttyKit
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Diagnostic coverage for Option+Backspace (backward word delete) on a
/// manual-I/O mirror surface, the surface kind a cloud terminal pane uses.
///
/// A cloud pane owns no PTY: Ghostty encodes the key and hands the bytes to
/// `manualInputHandler`, which forwards them to the remote shell. The remote
/// shell's word-delete binding is `ESC DEL` (0x1B 0x7F), so that is exactly
/// what this surface must emit.
@MainActor
@Suite(.serialized)
struct CloudManualInputOptionBackspaceTests {
    @Test
    func manualMirrorSurfaceEncodesOptionBackspaceAsEscDelete() async throws {
        _ = NSApplication.shared

        let (inputs, continuation) = AsyncStream<TerminalManualInput>.makeStream()
        defer { continuation.finish() }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            ioMode: .manualMirror,
            manualInputHandler: { input in continuation.yield(input) }
        )
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        // Real macOS produces "∂" (U+2202) for Option+Delete on a US layout.
        #expect(hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
            characters: "\u{2202}",
            charactersIgnoringModifiers: "\u{7F}",
            keyCode: UInt16(kVK_Delete),
            modifierFlags: [.option]
        ))

        var collected = Data()
        var iterator = inputs.makeAsyncIterator()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            guard let next = await iterator.next() else { break }
            switch next {
            case .bytes(let data): collected.append(data)
            case .namedKey(let name): Issue.record("unexpected named key \(name)")
            }
            if !collected.isEmpty { break }
        }

        #expect(
            Array(collected) == [0x1B, 0x7F],
            "Option+Backspace must reach a cloud pane as ESC DEL, got \(Array(collected).map { String(format: "0x%02X", $0) })"
        )
    }
}
