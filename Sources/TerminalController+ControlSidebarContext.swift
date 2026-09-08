import CmuxControlSocket
import Foundation
import CmuxSidebar

/// The live-app half of the v1 sidebar metadata commands (`set_status` /
/// `report_meta` / `report_meta_block` / agent PID + lifecycle / `log` /
/// `set_progress` and their clears + listings): the exact mutation/read bodies
/// the former `TerminalController` v1 handlers ran, minus the parsing and
/// reply formatting that moved into `ControlCommandCoordinator`.
extension TerminalController: ControlSidebarContext {
    // MARK: - Availability

    func controlSidebarTabManagerAvailable() -> Bool {
        tabManager != nil
    }

    // MARK: - Scheduled sidebar mutations (status / agent / blocks)

    nonisolated func controlSidebarScheduleStatusUpsert(
        target: ControlSidebarTabTarget,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: ControlSidebarMetadataFormat,
        panelID: UUID?,
        pid: Int32?,
        processGeneration: ControlSidebarAgentProcessGeneration? = nil
    ) {
        let appFormat = SidebarMetadataFormat(rawValue: format.rawValue) ?? .plain
        let exactProcessIdentity = processGeneration.map {
            AgentPIDProcessIdentity(
                pid: $0.pid,
                startSeconds: $0.startSeconds,
                startMicroseconds: $0.startMicroseconds
            )
        }
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            if let pid {
                let usesRemoteProcessNamespace =
                    owner.usesRemoteAgentProcessNamespace(panelId: panelID)
                // A custom PID received through a relay belongs to the remote
                // host. Never probe that numeric value against this Mac before
                // the owner namespace is known; keep it opaque instead.
                let reconstructedProcessIdentity = usesRemoteProcessNamespace
                    ? nil
                    : AgentPIDProcessIdentity(pid: pid)
                let keyIsBuiltIn = AgentHibernationLifecycleStatusKeys(
                    rawValue: key
                ).isBuiltInNamespace
                let acceptedProcessIdentity: AgentPIDProcessIdentity?
                if keyIsBuiltIn {
                    if usesRemoteProcessNamespace {
                        // Status-only relay metadata may omit the generation;
                        // when present, retain it as opaque ordering evidence.
                        acceptedProcessIdentity = exactProcessIdentity
                    } else {
                        guard let exactProcessIdentity,
                              exactProcessIdentity.pid == pid else {
                            return
                        }
                        acceptedProcessIdentity = exactProcessIdentity
                    }
                } else {
                    acceptedProcessIdentity =
                        exactProcessIdentity ?? reconstructedProcessIdentity
                }
                if let acceptedProcessIdentity {
                    guard owner.recordAgentPID(
                        key: key,
                        pid: pid,
                        panelId: panelID,
                        acceptedProcessIdentity: acceptedProcessIdentity,
                        observeProcessExit: !usesRemoteProcessNamespace
                    ).accepted else {
                        return
                    }
                } else if !usesRemoteProcessNamespace {
                    return
                }
            } else if AgentHibernationLifecycleStatusKeys(
                rawValue: key
            ).isAllowed,
                      !owner.usesRemoteAgentProcessNamespace(
                          panelId: panelID
                      ),
                      !owner.hasLiveAgentProcess(
                          statusKey: key,
                          panelId: panelID
                      ) {
                return
            }
            guard Self.shouldReplaceStatusEntry(
                current: owner.statusEntry(key: key, panelId: panelID),
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: url,
                priority: priority,
                format: appFormat
            ) else {
                return
            }
            owner.setStatusEntry(SidebarStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: url,
                priority: priority,
                format: appFormat,
                timestamp: Date()
            ), key: key, panelId: panelID)
        }
    }

    nonisolated func controlSidebarScheduleStatusClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?
    ) {
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            owner.clearStatusEntry(key: key, panelId: panelID)
            _ = owner.clearAgentLifecycle(key: key, panelId: panelID)
            owner.clearAgentPID(
                key: key,
                panelId: panelID,
                clearStatus: false,
                requireOwnedKey: true
            )
        }
    }

    nonisolated func controlSidebarScheduleAgentPIDRecord(
        target: ControlSidebarTabTarget,
        key: String,
        pid: Int32,
        processGeneration: ControlSidebarAgentProcessGeneration?,
        panelID: UUID?
    ) {
        let exactProcessIdentity = processGeneration.map {
            AgentPIDProcessIdentity(
                pid: $0.pid,
                startSeconds: $0.startSeconds,
                startMicroseconds: $0.startMicroseconds
            )
        }
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            // The coordinator rejects missing generations for built-ins. Keep
            // the same invariant at the mutation boundary so a queued command
            // cannot reconstruct ownership from a recycled numeric PID.
            let usesRemoteProcessNamespace =
                owner.usesRemoteAgentProcessNamespace(panelId: panelID)
            let reconstructedProcessIdentity = usesRemoteProcessNamespace
                ? nil
                : AgentPIDProcessIdentity(pid: pid)
            let acceptedProcessIdentity: AgentPIDProcessIdentity?
            if let exactProcessIdentity {
                acceptedProcessIdentity = exactProcessIdentity
            } else if AgentHibernationLifecycleStatusKeys(
                rawValue: key
            ).isBuiltInNamespace {
                return
            } else {
                acceptedProcessIdentity = reconstructedProcessIdentity
            }
            let result = owner.recordAgentPID(
                key: key,
                pid: pid,
                panelId: panelID,
                acceptedProcessIdentity: acceptedProcessIdentity,
                observeProcessExit: !usesRemoteProcessNamespace
            )
            if result.replacedOtherRuntime, let panelID {
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: owner.id,
                    surfaceId: panelID,
                    discardQueuedNotifications: false
                )
            }
        }
    }

    nonisolated func controlSidebarParseAgentLifecycle(_ raw: String) -> String? {
        AgentHibernationLifecycleState(cliValue: raw)?.rawValue
    }

    nonisolated func controlSidebarAgentStrings() -> ControlSidebarAgentStrings {
        ControlSidebarAgentStrings(
            usageErrorFormat: String(
                localized: "socket.sidebar.agent.usageError",
                defaultValue: "ERROR: Usage: %@"
            ),
            setAgentPIDUsage: String(
                localized: "socket.sidebar.agent.setPIDUsage",
                defaultValue: "set_agent_pid <key> <pid> [--tab=<id>] [--panel=<id>] [--pid=<pid> --pid-start-seconds=<seconds> --pid-start-microseconds=<microseconds>]"
            ),
            setAgentLifecycleUsage: String(
                localized: "socket.sidebar.agent.setLifecycleUsage",
                defaultValue: "set_agent_lifecycle <key> <unknown|running|idle|needsInput> [--tab=<id>] [--panel=<id>] [--pid=<pid> --pid-start-seconds=<seconds> --pid-start-microseconds=<microseconds>]"
            ),
            processGenerationPIDMismatch: String(
                localized:
                    "socket.sidebar.agent.processGenerationPIDMismatch",
                defaultValue:
                    "ERROR: Agent process generation PID does not match <pid>"
            ),
            invalidLifecycleFormat: String(
                localized: "socket.sidebar.agent.invalidLifecycle",
                defaultValue:
                    "ERROR: Invalid agent lifecycle '%1$@' — usage: %2$@"
            ),
            unsupportedLifecycleKeyFormat: String(
                localized: "socket.sidebar.agent.unsupportedLifecycleKey",
                defaultValue:
                    "ERROR: Unsupported agent lifecycle key '%@'"
            ),
            processGenerationRequired: String(
                localized: "socket.sidebar.agent.processGenerationRequired",
                defaultValue:
                    "ERROR: Agent process generation is required for this agent."
            ),
            invalidProcessGenerationFormat: String(
                localized: "socket.sidebar.agent.invalidProcessGeneration",
                defaultValue:
                    "ERROR: Invalid agent process generation — usage: %@"
            )
        )
    }

    /// `nonisolated` so the vault-registry disk IO runs on the calling
    /// (socket-worker) thread; only the tab resolution + panel-directory
    /// candidate snapshot crosses to the main actor, as `set_agent_lifecycle`'s
    /// single hop. The legacy body resolved the tab before the registration-id
    /// syntax check; both are side-effect-free reads, so checking the pure
    /// syntax first (to skip the hop for non-registry keys) cannot change the
    /// result.
    nonisolated func controlSidebarIsAllowedAgentLifecycleKey(
        _ key: String,
        target: ControlSidebarTabTarget,
        panelID: UUID?
    ) -> Bool {
        if AgentHibernationLifecycleStatusKeys(rawValue: key).isAllowed {
            return true
        }
        // The manual namespace is reserved for workspace_loading; a custom
        // vault agent must not claim it (hibernation ignores manual keys).
        guard !AgentHibernationLifecycleStatusKeys(rawValue: key).isManual else {
            return false
        }
        guard CmuxVaultAgentRegistration.isValidID(key) else {
            return false
        }
        let scope: ControlSidebarAgentLifecycleRegistryScope? = v2MainSync {
            guard let owner = self.controlSidebarResolvePanelOwner(
                target: target,
                panelID: panelID
            ) else {
                return nil
            }
            return owner.agentLifecycleRegistryScope(panelId: panelID)
        }
        guard let scope else { return false }
        let registry = scope.loadRegistry()
        return registry.registration(id: key) != nil
    }

    nonisolated func controlSidebarRequiresAgentProcessGeneration(
        _ key: String,
        target: ControlSidebarTabTarget,
        panelID: UUID?
    ) -> Bool {
        // Never reconstruct a missing generation from the current numeric PID:
        // local and relayed hooks can both arrive after that PID was recycled
        // in their respective process namespaces.
        guard AgentHibernationLifecycleStatusKeys(
            rawValue: key
        ).isBuiltInNamespace else {
            return false
        }
        // A relay's PID is meaningful only on the remote host, but its
        // start-time tuple is still required to fence delayed/reused remote
        // processes. The tuple is stored as opaque generation evidence; only
        // local owners use it for process-table probing.
        return v2MainSync {
            guard let owner = self.controlSidebarResolvePanelOwner(
                target: target,
                panelID: panelID
            ) else {
                return true
            }
            return true
        }
    }

    nonisolated func controlSidebarScheduleAgentLifecycle(
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        processGeneration: ControlSidebarAgentProcessGeneration?,
        panelID: UUID?
    ) {
        guard let lifecycle = AgentHibernationLifecycleState(rawValue: lifecycleRawValue) else {
            // Unreachable: the coordinator only forwards a value this app produced.
            return
        }
        let exactProcessGeneration = processGeneration.map {
            AgentPIDProcessIdentity(
                pid: $0.pid,
                startSeconds: $0.startSeconds,
                startMicroseconds: $0.startMicroseconds
            )
        }
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            if AgentHibernationLifecycleStatusKeys(rawValue: key).isAllowed {
                // The parser rejects missing generations for built-ins; keep
                // this mutation-boundary guard for queued replacement races.
                guard let exactProcessGeneration else {
                    return
                }
                if !owner.usesRemoteAgentProcessNamespace(panelId: panelID) {
                    guard
                      owner.hasLiveAgentProcess(
                          statusKey: key,
                          panelId: panelID,
                          matching: exactProcessGeneration
                      ) else {
                        return
                    }
                }
            }
            owner.setAgentLifecycle(
                key: key,
                panelId: panelID,
                lifecycle: lifecycle,
                processGeneration: exactProcessGeneration
            )
        }
    }

}
