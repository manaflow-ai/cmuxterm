public import Bonsplit

/// Applies pane zoom semantics around a user-requested tab creation transaction.
///
/// Low-level surface creators are also used by session restoration and
/// focus-neutral automation, so callers explicitly choose when a request is an
/// interactive new-tab transaction. The policy owns the shared clear/restore
/// invariant while each host remains responsible for its UI reconciliation.
@MainActor
public struct NewTabPaneZoomPolicy {
    /// A pane zoom mutation performed by the policy.
    public enum Change: Equatable {
        /// The previous pane zoom was cleared before the operation.
        case cleared
        /// A cleared pane zoom was restored after the operation failed.
        case restored(PaneID)
    }

    private let keepExpanded: Bool

    /// Creates a policy for the current keep-expanded preference.
    ///
    /// - Parameter keepExpanded: Whether a new tab targeting the zoomed pane
    ///   should leave that pane zoomed.
    public init(keepExpanded: Bool) {
        self.keepExpanded = keepExpanded
    }

    /// Runs an operation with transactional pane zoom handling.
    ///
    /// The legacy behavior clears an existing zoom before the operation. When
    /// `keepExpanded` is enabled, a request targeting that same pane preserves
    /// the zoom. If the operation fails after a clear, the previous zoom is
    /// restored only while that pane is still live and no replacement zoom was
    /// established during the operation.
    ///
    /// - Parameters:
    ///   - paneId: Pane receiving the new tab.
    ///   - controller: Bonsplit controller that owns the pane zoom state.
    ///   - applyPolicy: Whether this operation is an interactive, focused tab
    ///     creation that should affect pane zoom.
    ///   - succeeded: Maps the operation result to creation success. Remote
    ///     routed terminal requests can therefore count as successful without
    ///     returning a local panel.
    ///   - onZoomChange: Called after each zoom mutation so the host can
    ///     reconcile visibility and portal state.
    ///   - operation: Tab creation operation to run.
    /// - Returns: The operation's result unchanged.
    @discardableResult
    public func perform<Result>(
        inPane paneId: PaneID,
        controller: BonsplitController,
        applyPolicy: Bool = true,
        succeeded: (Result) -> Bool,
        onZoomChange: (Change) -> Void = { _ in },
        operation: () -> Result
    ) -> Result {
        guard applyPolicy else { return operation() }

        let previousZoomedPaneId = controller.zoomedPaneId
        let preservesCurrentZoom = keepExpanded && previousZoomedPaneId == paneId
        if previousZoomedPaneId != nil,
           !preservesCurrentZoom,
           controller.clearPaneZoom() {
            onZoomChange(.cleared)
        }

        let result = operation()
        if !succeeded(result),
           let previousZoomedPaneId,
           controller.zoomedPaneId == nil,
           controller.allPaneIds.contains(previousZoomedPaneId),
           controller.togglePaneZoom(inPane: previousZoomedPaneId) {
            onZoomChange(.restored(previousZoomedPaneId))
        }
        return result
    }
}
