import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct AppDelegateFullScreenFrameRestoreTests {
    @Test(.enabled(
        if: NSScreen.screens.contains { $0.visibleFrame.maxY < $0.frame.maxY },
        "No screen with a visible menu-bar inset is available"
    ))
    func exitingNativeFullScreenFitsFullDisplayFrameBelowMenuBar() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first(where: {
            $0.visibleFrame.maxY < $0.frame.maxY
        }))

        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let windowId = appDelegate.createMainWindow(shouldActivate: false)
        let window = try #require(appDelegate.mainWindow(for: windowId) as? CmuxMainWindow)
#if DEBUG
        let previousConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
#endif
        defer {
            window.animationBehavior = .none
            window.orderOut(nil)
            window.close()
#if DEBUG
            appDelegate.debugCloseMainWindowConfirmationHandler = previousConfirmationHandler
#endif
        }

        window.setFrame(screen.frame, display: false)
        #expect(window.frame.maxY > screen.visibleFrame.maxY)

        window.delegate?.windowDidExitFullScreen?(
            Notification(name: NSWindow.didExitFullScreenNotification, object: window)
        )

        #expect(screen.visibleFrame.contains(window.frame))
        #expect(window.frame.maxY <= screen.visibleFrame.maxY)
    }

    @Test(.enabled(
        if: !NSScreen.screens.isEmpty,
        "No screen is available for fullscreen frame fitting"
    ))
    func nativeFullscreenReconnectFrameFitsTheDisplayItLandedOn() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let display = AppDelegate.SessionDisplayGeometry(
            displayID: screen.cmuxDisplayID,
            stableID: screen.cmuxStableDisplayKey ?? "test-display",
            frame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        let window = CmuxMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }

        window.styleMask.insert(.fullScreen)
        let staleFrame = NSRect(
            x: screen.frame.minX,
            y: screen.frame.minY - 286,
            width: screen.frame.width,
            height: max(200, screen.visibleFrame.height - 13)
        )
        window.setFrame(staleFrame, display: false)

        MainWindowVisibleFrameFitRescue().performFitIfNeeded(
            displays: [display],
            windows: [window]
        )

        let topInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let expectedFrame = NSRect(
            x: screen.frame.minX,
            y: screen.frame.minY,
            width: screen.frame.width,
            height: screen.frame.height - topInset
        )
        #expect(window.frame == expectedFrame)
    }
}
