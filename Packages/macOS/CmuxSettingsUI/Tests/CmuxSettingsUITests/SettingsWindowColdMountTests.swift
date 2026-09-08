import AppKit
import CmuxSettings
import Foundation
import SwiftUI
import Testing
@testable import CmuxSettingsUI

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/12134:
/// opening Settings beachballed for seconds on Intel Macs because the
/// first synchronous layout pass — the one `NSWindow(contentViewController:)`
/// runs before the window is ordered front — materialized every section's
/// AppKit-backed controls at once.
///
/// Hosts ``SettingsWindowRoot`` exactly the way the app's window factory
/// does and compares the controls present after that synchronous pass with
/// the controls present once the run loop has been allowed to finish
/// mounting. The synchronous pass must be a small fraction of the full
/// tree, and the full tree must still arrive on its own.
@MainActor
@Suite(.serialized) struct SettingsWindowColdMountTests {
    static func makeRuntime() -> SettingsRuntime {
        let suiteName = "SettingsWindowColdMountTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return SettingsRuntime(
            catalog: SettingCatalog(),
            userDefaultsStore: UserDefaultsSettingsStore(defaults: defaults),
            jsonStore: JSONConfigStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
            ),
            secretStore: SecretFileStore(
                baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            ),
            errorLog: SettingsErrorLog()
        )
    }

    /// AppKit-backed controls (`NSSwitch`, `NSPopUpButton`, `NSStepper`,
    /// `NSColorWell`, `NSButton`, …) currently attached under `view`.
    static func controlCount(in view: NSView?) -> Int {
        guard let view else { return 0 }
        return (view is NSControl ? 1 : 0) + view.subviews.reduce(0) { $0 + controlCount(in: $1) }
    }

    /// Hosts `root` the way `SettingsWindowFactory.makeSettingsWindow` does:
    /// `NSWindow(contentViewController:)` runs the first layout pass
    /// synchronously, before any run-loop turn.
    static func hostSynchronously(_ root: SettingsWindowRoot) -> NSWindow {
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 980, height: 680))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// Pumps the main run loop until `condition` or a bounded deadline
    /// (deterministic test scaffolding, not runtime synchronization).
    static func pump(seconds: Double = 20, until condition: () -> Bool) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition(), ContinuousClock.now < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Pumps until the hosted control count stops growing for a full
    /// second, i.e. progressive mounting (if any) has finished.
    static func pumpUntilSettled(_ window: NSWindow) -> Int {
        var last = controlCount(in: window.contentView)
        var stableSince = ContinuousClock.now
        pump(seconds: 30) {
            let current = controlCount(in: window.contentView)
            if current != last {
                last = current
                stableSince = ContinuousClock.now
            }
            return ContinuousClock.now - stableSince > .seconds(1)
        }
        return last
    }

    @Test func synchronousColdHostMountsOnlyAFractionOfTheControls() {
        let runtime = Self.makeRuntime()
        let window = Self.hostSynchronously(SettingsWindowRoot(runtime: runtime))
        defer { window.orderOut(nil) }

        let synchronousControls = Self.controlCount(in: window.contentView)
        let settledControls = Self.pumpUntilSettled(window)

        // The complete tree carries a couple of hundred AppKit-backed
        // controls; the pass that blocks window creation may hold only the
        // sidebar plus the section the window opens on.
        #expect(settledControls > 100, "progressive mounting must still deliver every section (\(settledControls) controls)")
        #expect(
            synchronousControls * 4 < settledControls,
            "window creation materialized \(synchronousControls) of \(settledControls) controls synchronously"
        )
    }
}
