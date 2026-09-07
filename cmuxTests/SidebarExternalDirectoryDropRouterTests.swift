import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Multi-window scoping for Finder-directory → sidebar routing.
@Suite struct SidebarExternalDirectoryDropRouterTests {
    @MainActor
    private final class StubRouter: SidebarExternalDirectoryDropRouting {
        let window: NSWindow
        private(set) var updateCount = 0
        private(set) var clearCount = 0
        private(set) var lastUpdatePoint: NSPoint?

        init(window: NSWindow) {
            self.window = window
        }

        var externalDirectoryDropHostingWindow: NSWindow? { window }

        func containsExternalDirectoryDropWindowPoint(_ windowPoint: NSPoint) -> Bool {
            true
        }

        func updateExternalDirectoryDrop(atWindowPoint windowPoint: NSPoint) -> Int? {
            updateCount += 1
            lastUpdatePoint = windowPoint
            return 0
        }

        func clearExternalDirectoryDrop() {
            clearCount += 1
        }

        func performExternalDirectoryDrop(
            directoryPath: String,
            atWindowPoint windowPoint: NSPoint
        ) -> Bool {
            true
        }
    }

    @MainActor
    @Test func resolvesRouterForMatchingWindowOnly() {
        let windowA = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let windowB = NSWindow(
            contentRect: NSRect(x: 220, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let routerA = StubRouter(window: windowA)
        let routerB = StubRouter(window: windowB)
        SidebarExternalDirectoryDropRouter.register(routerA)
        SidebarExternalDirectoryDropRouter.register(routerB)
        defer {
            SidebarExternalDirectoryDropRouter.unregister(routerA)
            SidebarExternalDirectoryDropRouter.unregister(routerB)
        }

        #expect(SidebarExternalDirectoryDropRouter.registeredRouterCountForTests == 2)
        #expect(SidebarExternalDirectoryDropRouter.router(for: windowA) === routerA)
        #expect(SidebarExternalDirectoryDropRouter.router(for: windowB) === routerB)
    }

    @MainActor
    @Test func unregisteringOneWindowDoesNotBreakTheOther() {
        let windowA = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let windowB = NSWindow(
            contentRect: NSRect(x: 220, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let routerA = StubRouter(window: windowA)
        let routerB = StubRouter(window: windowB)
        SidebarExternalDirectoryDropRouter.register(routerA)
        SidebarExternalDirectoryDropRouter.register(routerB)
        SidebarExternalDirectoryDropRouter.unregister(routerA)
        defer {
            SidebarExternalDirectoryDropRouter.unregister(routerB)
        }

        #expect(SidebarExternalDirectoryDropRouter.router(for: windowA) == nil)
        #expect(SidebarExternalDirectoryDropRouter.router(for: windowB) === routerB)
        #expect(SidebarExternalDirectoryDropRouter.registeredRouterCountForTests == 1)
    }

    @MainActor
    @Test func unknownWindowFailsClosed() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        #expect(SidebarExternalDirectoryDropRouter.router(for: window) == nil)
    }
}
