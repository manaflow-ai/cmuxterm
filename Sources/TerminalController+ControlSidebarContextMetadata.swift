import CmuxControlSocket
import CmuxSidebar
import Foundation

/// Sidebar workspace-loading, metadata, log, and progress context methods.
extension TerminalController {
    func controlSidebarSetWorkspaceLoading(
        tabArg: String?,
        key: String,
        on: Bool
    ) -> ControlSidebarWorkspaceLoadingState? {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return nil }
        let before = tab.hasRunningAgentLifecycle(key: key)
        if on {
            // Workspace-scoped: exactly one panel holds a manual key at a time,
            // so reasserting `on` after focus moves never duplicates the loader.
            _ = tab.clearAgentLifecycle(key: key, panelId: nil)
            // Bound distinct manual loaders per workspace so socket clients
            // can't grow lifecycle-key state without limit.
            let manualLoaderCount = tab.agentLifecycleStatesByPanelId.values.reduce(0) { partial, states in
                partial + states.keys.reduce(0) {
                    AgentHibernationLifecycleStatusKeys(rawValue: $1).isManual
                        ? $0 + 1
                        : $0
                }
            }
            guard manualLoaderCount < 32 else {
                return ControlSidebarWorkspaceLoadingState(
                    before: before,
                    after: tab.hasRunningAgentLifecycle(key: key),
                    failureReason: "Manual workspace loading limit reached"
                )
            }
            if let panelId = tab.focusedPanelId ?? tab.panels.keys.first {
                tab.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
            } else {
                return ControlSidebarWorkspaceLoadingState(
                    before: before,
                    after: false,
                    failureReason: "Workspace has no panel for manual loading"
                )
            }
        } else {
            // Workspace-scoped: clear from all panels, not just the caller's.
            _ = tab.clearAgentLifecycle(key: key, panelId: nil)
        }
        return ControlSidebarWorkspaceLoadingState(before: before, after: tab.hasRunningAgentLifecycle(key: key))
    }

    /// `nonisolated` with the settings write inside `agent_hibernation`'s
    /// single main hop: `setValues` posts the settings-did-change notification
    /// synchronously, and its observers assume the main thread (the legacy
    /// body always ran there). Keeping the hop synchronous also preserves the
    /// apply-then-reply ordering main-thread test callers rely on.
    nonisolated func controlSidebarSetAgentHibernation(enabled: Bool) {
        v2MainSync {
            AgentHibernationSettings.setValues(enabled: enabled)
        }
    }

    nonisolated func controlSidebarScheduleAgentPIDClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool,
        requireOwnedKey: Bool = false
    ) {
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            owner.clearAgentPID(
                key: key,
                panelId: panelID,
                clearStatus: clearStatus,
                requireOwnedKey: requireOwnedKey
            )
        }
    }

    nonisolated func controlSidebarScheduleMetadataBlockUpsert(
        target: ControlSidebarTabTarget,
        key: String,
        markdown: String,
        priority: Int
    ) {
        controlSidebarScheduleMutation(target: target) { _, tab in
            guard Self.shouldReplaceMetadataBlock(
                current: tab.metadataBlocks[key],
                key: key,
                markdown: markdown,
                priority: priority
            ) else {
                return
            }
            tab.metadataBlocks[key] = SidebarMetadataBlock(
                key: key,
                markdown: markdown,
                priority: priority,
                timestamp: Date()
            )
        }
    }

    // MARK: - Synchronous metadata reads / writes

    func controlSidebarStatusEntries(tabArg: String?) -> [ControlSidebarStatusEntrySnapshot]? {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return nil }
        return tab.sidebarStatusEntriesInDisplayOrder().map(Self.controlSidebarStatusEntrySnapshot)
    }

    /// Converts one app status entry to its Sendable wire snapshot.
    private static func controlSidebarStatusEntrySnapshot(_ entry: SidebarStatusEntry) -> ControlSidebarStatusEntrySnapshot {
        ControlSidebarStatusEntrySnapshot(
            key: entry.key,
            value: entry.value,
            icon: entry.icon,
            color: entry.color,
            urlAbsoluteString: entry.url?.absoluteString,
            priority: entry.priority,
            format: ControlSidebarMetadataFormat(rawValue: entry.format.rawValue) ?? .plain
        )
    }

    func controlSidebarMetadataBlocks(tabArg: String?) -> [ControlSidebarMetadataBlockSnapshot]? {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return nil }
        return tab.sidebarMetadataBlocksInDisplayOrder().map(Self.controlSidebarMetadataBlockSnapshot)
    }

    /// Converts one app metadata block to its Sendable wire snapshot.
    private static func controlSidebarMetadataBlockSnapshot(_ block: SidebarMetadataBlock) -> ControlSidebarMetadataBlockSnapshot {
        ControlSidebarMetadataBlockSnapshot(
            key: block.key,
            markdown: block.markdown,
            priority: block.priority
        )
    }

    func controlSidebarClearMetadataBlock(tabArg: String?, key: String) -> ControlSidebarClearMetaBlockResolution {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return .tabNotFound
        }
        if tab.metadataBlocks.removeValue(forKey: key) == nil {
            return .keyNotFound
        }
        return .removed
    }

    nonisolated func controlSidebarIsValidLogLevel(_ raw: String) -> Bool {
        SidebarLogLevel(rawValue: raw) != nil
    }

    func controlSidebarAppendLog(
        tabArg: String?,
        message: String,
        levelRawValue: String,
        source: String?
    ) -> Bool {
        guard let level = SidebarLogLevel(rawValue: levelRawValue) else {
            // Unreachable: the coordinator validates the level first.
            return true
        }
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        tab.logEntries.append(SidebarLogEntry(message: message, level: level, source: source, timestamp: Date()))
        let configuredLimit = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
        let limit = max(1, min(500, configuredLimit))
        if tab.logEntries.count > limit {
            tab.logEntries.removeFirst(tab.logEntries.count - limit)
        }
        return true
    }

    func controlSidebarClearLog(tabArg: String?) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        tab.logEntries.removeAll()
        return true
    }

    func controlSidebarLogEntries(tabArg: String?) -> [ControlSidebarLogEntrySnapshot]? {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return nil }
        return tab.logEntries.map(Self.controlSidebarLogEntrySnapshot)
    }

    /// Converts one app log entry to its Sendable wire snapshot.
    private static func controlSidebarLogEntrySnapshot(_ entry: SidebarLogEntry) -> ControlSidebarLogEntrySnapshot {
        ControlSidebarLogEntrySnapshot(
            levelRawValue: entry.level.rawValue,
            message: entry.message,
            source: entry.source
        )
    }

    func controlSidebarSetProgress(tabArg: String?, value: Double, label: String?) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        tab.progress = SidebarProgressState(value: value, label: label)
        return true
    }

    func controlSidebarClearProgress(tabArg: String?) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        tab.progress = nil
        return true
    }
}
