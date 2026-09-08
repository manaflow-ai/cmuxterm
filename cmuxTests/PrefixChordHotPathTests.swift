import AppKit
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Prefix chord hot-path matching")
@MainActor
struct PrefixChordHotPathTests {
    @Test(arguments: [NSEvent.EventType.systemDefined, .applicationDefined], [Int16(0), 8])
    func nonKeyEventsPassThroughWithoutReadingKeyboardOnlyFields(
        eventType: NSEvent.EventType,
        subtype: Int16
    ) throws {
        _ = NSApplication.shared
        let owner = AppDelegate()
        let coordinator = ShortcutPrefixChordCoordinator(owner: owner)
        let event = try #require(NSEvent.otherEvent(
            with: eventType,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            subtype: subtype,
            data1: (16 << 16) | (0xA << 8),
            data2: 0
        ))

        // The coordinator holds its owner weakly; retain it through dispatch
        // so this exercises the event adapter instead of the missing-owner guard.
        let result = withExtendedLifetime(owner) { coordinator.offer(event) }
        if case .passThrough = result {
            // An unarmed layer must leave media and unrelated system events alone.
        } else {
            Issue.record("An unarmed prefix consumed a non-key event")
        }
    }

    @Test func customMatcherSeesChordSuffixWithDifferentModifiers() {
        let chord = StoredShortcut(
            first: ShortcutStroke(key: "b", control: true),
            second: ShortcutStroke(key: "n", command: true)
        )
        let matcher = RightSidebarModeShortcutMatcher(
            shortcutProvider: { action in
                action == .switchRightSidebarToFiles ? chord : .unbound
            },
            availability: { _ in true },
            layoutCharacterProvider: { _, _ in nil }
        )
        let event = makeKeyEvent(characters: "n", modifiers: [.command], keyCode: 45)

        let mode = matcher.modeShortcut(
            for: event,
            allowingAction: { _ in true },
            matching: { action, shortcut, event in
                guard action == .switchRightSidebarToFiles,
                      let suffix = shortcut.second else {
                    return false
                }
                return suffix.matches(event: event, layoutCharacterProvider: { _, _ in nil })
            }
        )

        #expect(mode == .files)
    }

    private func makeKeyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
