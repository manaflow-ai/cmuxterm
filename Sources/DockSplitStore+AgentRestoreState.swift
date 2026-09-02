import Foundation

extension DockSplitStore {
    var restoredAgentLifecycle: RestoredAgentLifecycleCoordinator {
        terminalStartupRestoreCoordinator.lifecycle
    }

    var restoredResumeSessionWorkingDirectoriesByPanelId: [UUID: String] {
        get { restoredAgentLifecycle.resumeWorkingDirectoriesByPanelId }
        set { restoredAgentLifecycle.resumeWorkingDirectoriesByPanelId = newValue }
    }
}
