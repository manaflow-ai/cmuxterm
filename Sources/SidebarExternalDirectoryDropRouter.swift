import AppKit
import CmuxFoundation

/// Sidebar authority for Finder-directory → new-workspace insertion, driven by
/// the window-level ``FileDropOverlayView`` (the native NSDraggingDestination).
///
/// Spatial planning and indicator painting stay in the sidebar; the overlay only
/// owns pasteboard / drag lifecycle and delegates here when the pointer is over
/// a live workspace list in the **same** window.
@MainActor
protocol SidebarExternalDirectoryDropRouting: AnyObject {
    /// Window that owns this sidebar presentation. Used to scope Finder routing
    /// so window A's overlay never consults window B's sidebar.
    var externalDirectoryDropHostingWindow: NSWindow? { get }

    /// Whether `windowPoint` lies inside this sidebar's visible drop surface.
    func containsExternalDirectoryDropWindowPoint(_ windowPoint: NSPoint) -> Bool

    /// Updates insertion indicator for a validated directory drag at `windowPoint`.
    /// - Returns: planned complete top-level insertion slot when legal; otherwise `nil`.
    @discardableResult
    func updateExternalDirectoryDrop(atWindowPoint windowPoint: NSPoint) -> Int?

    /// Clears any painted external-directory insertion affordance.
    func clearExternalDirectoryDrop()

    /// Creates one new workspace for `directoryPath` at the current / resolved plan.
    @discardableResult
    func performExternalDirectoryDrop(
        directoryPath: String,
        atWindowPoint windowPoint: NSPoint
    ) -> Bool
}

/// Per-window registration of AppKit workspace sidebar routers.
///
/// Finder drops are owned by each window's ``FileDropOverlayView``. Resolution
/// is always keyed by that overlay's `NSWindow` so multi-window sessions cannot
/// cross-wire sidebars.
@MainActor
enum SidebarExternalDirectoryDropRouter {
    private struct WeakRouter {
        weak var value: (any SidebarExternalDirectoryDropRouting)?
    }

    private static var routersByIdentity: [ObjectIdentifier: WeakRouter] = [:]

    static func register(_ router: any SidebarExternalDirectoryDropRouting) {
        prune()
        routersByIdentity[ObjectIdentifier(router)] = WeakRouter(value: router)
    }

    static func unregister(_ router: any SidebarExternalDirectoryDropRouting) {
        routersByIdentity.removeValue(forKey: ObjectIdentifier(router))
        prune()
    }

    /// Returns the sidebar router hosted by `window`, or `nil` (fail closed).
    static func router(for window: NSWindow) -> (any SidebarExternalDirectoryDropRouting)? {
        prune()
        for entry in routersByIdentity.values {
            guard let router = entry.value,
                  router.externalDirectoryDropHostingWindow === window else {
                continue
            }
            return router
        }
        return nil
    }

    private static func prune() {
        routersByIdentity = routersByIdentity.filter { $0.value.value != nil }
    }
}
