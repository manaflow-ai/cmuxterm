public import Foundation

/// Chooses which external-directory insertion plan to commit on drop release.
///
/// Product invariant: if the UI is still showing a painted insertion line, tiny
/// release-time pointer drift into a row center must not cancel that drop when
/// the complete root order is unchanged. Viewport / order invalidation still
/// rejects a stale painted plan.
public enum ExternalWorkspaceDropCommitResolver: Sendable {
    /// - Parameters:
    ///   - replanned: Fresh geometry plan at the release point, if any.
    ///   - painted: Last accepted plan that was painted for the user.
    ///   - paintedCompleteTopLevelIds: Complete ungrouped root order when
    ///     `painted` was accepted.
    ///   - currentCompleteTopLevelIds: Complete ungrouped root order at commit.
    public static func resolve(
        replanned: ExternalWorkspaceInsertionPlanner.Plan?,
        painted: ExternalWorkspaceInsertionPlanner.Plan?,
        paintedCompleteTopLevelIds: [UUID],
        currentCompleteTopLevelIds: [UUID]
    ) -> ExternalWorkspaceInsertionPlanner.Plan? {
        if let replanned {
            return replanned
        }
        guard let painted,
              paintedCompleteTopLevelIds == currentCompleteTopLevelIds,
              painted.insertionIndex >= 0,
              painted.insertionIndex <= currentCompleteTopLevelIds.count
        else {
            return nil
        }
        if let tabId = painted.indicator.tabId,
           !currentCompleteTopLevelIds.contains(tabId) {
            return nil
        }
        return painted
    }
}
