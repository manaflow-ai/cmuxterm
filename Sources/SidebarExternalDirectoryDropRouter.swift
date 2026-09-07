import AppKit
import CmuxFoundation

/// Sidebar authority for Finder-directory → new-workspace insertion, driven by
/// the window-level ``FileDropOverlayView`` (the native NSDraggingDestination).
///
/// Spatial planning and indicator painting stay in the sidebar; the overlay only
/// owns pasteboard / drag lifecycle and delegates here when the pointer is over
/// a live workspace list.
@MainActor
protocol SidebarExternalDirectoryDropRouting: AnyObject {
    /// Whether `windowPoint` lies inside this sidebar's visible drop surface.
    func containsExternalDirectoryDropWindowPoint(_ windowPoint: NSPoint) -> Bool

    /// Updates insertion indicator for a validated directory drag at `windowPoint`.
    /// - Returns: planned insertion index when a legal plan is active; otherwise `nil`.
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

/// Process-local registration of the active AppKit workspace sidebar router.
@MainActor
enum SidebarExternalDirectoryDropRouter {
    private static weak var active: (any SidebarExternalDirectoryDropRouting)?

    static func register(_ router: any SidebarExternalDirectoryDropRouting) {
        active = router
    }

    static func unregister(_ router: any SidebarExternalDirectoryDropRouting) {
        if active === router {
            active = nil
        }
    }

    static var current: (any SidebarExternalDirectoryDropRouting)? { active }
}
