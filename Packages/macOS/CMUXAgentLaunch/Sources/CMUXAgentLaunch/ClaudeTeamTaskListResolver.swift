import CryptoKit
import Darwin
import Foundation

/// Resolves an automatic Claude agent team's shared task list from hook identity.
///
/// Claude's PostToolUse payload exposes `agent_id` for subagent calls but does
/// not expose the automatic team name that selects the shared task directory.
/// Team `config.json` files provide the deterministic identity mapping for both
/// exact member agents and leader sessions.
public struct ClaudeTeamTaskListResolver {
    /// Maximum visible entries inspected in Claude's team-store root.
    static let maximumTeamRootEntryCount = 512
    /// Maximum bytes read from one team configuration file.
    static let maximumTeamConfigFileByteCount = 64 * 1024

    /// The directory containing Claude's per-team directories.
    public let teamsRootURL: URL

    let taskStoreIdentity: ClaudeTaskStoreIdentity
    let fileManager: any ClaudeTaskFileSystem
    let operationDeadline: ClaudeTaskOperationDeadline

    /// Creates a resolver rooted at a specific Claude teams directory.
    ///
    /// - Parameters:
    ///   - teamsRootURL: The directory containing team `config.json` files.
    ///   - taskStoreIdentity: The sibling task store's durable namespace.
    ///   - fileManager: The filesystem implementation used to read configs.
    ///   - deadlineUptime: An optional absolute monotonic deadline for all reads.
    ///   - uptime: The injectable monotonic clock used to enforce the deadline.
    public init(
        teamsRootURL: URL,
        taskStoreIdentity: ClaudeTaskStoreIdentity? = nil,
        fileManager: any ClaudeTaskFileSystem = FileManager(),
        deadlineUptime: TimeInterval? = nil,
        uptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.teamsRootURL = teamsRootURL.canonicalClaudeTaskStoreDirectoryURL
        self.taskStoreIdentity = taskStoreIdentity ?? ClaudeTaskStoreIdentity(
            tasksRootURL: self.teamsRootURL.deletingLastPathComponent()
                .appendingPathComponent("tasks", isDirectory: true)
        )
        self.fileManager = fileManager
        operationDeadline = ClaudeTaskOperationDeadline(
            deadlineUptime: deadlineUptime,
            uptime: uptime
        )
    }

    /// Resolves the unique task-list binding owned by a hook identity.
    ///
    /// Only direct, non-symlinked team directories and regular config files
    /// participate. Malformed unrelated configs are ignored, while duplicate
    /// exact identity matches fail closed rather than choosing a neighboring
    /// team. Team-directory ownership is verified with Claude's lowercase
    /// sanitizer; the returned task-list name uses Claude's distinct task
    /// sanitizer. A previously proven binding is validated through its
    /// canonical config before the bounded team-root scan.
    ///
    /// - Parameters:
    ///   - sessionID: The hook payload's exact `session_id` value.
    ///   - agentID: The hook payload's exact `agent_id`, when present.
    ///   - previouslyBoundBinding: A team proof retained from an earlier hook.
    /// - Returns: The unique binding plus whether it came from retained cleanup
    ///   proof, or `nil` when no exact identity can be established.
    /// - Throws: A filesystem or resource-bound error while scanning configs,
    ///   including ``ClaudeTaskSnapshotLoaderError/teamConfigurationChangedDuringScan``
    ///   when the identity changes during the lookup.
    public func resolveTaskListBinding(
        sessionID: String,
        agentID: String?,
        previouslyBoundBinding: ClaudeTeamTaskListBinding? = nil
    ) throws -> ClaudeTeamTaskListResolution? {
        try operationDeadline.check()
        let normalizedSessionID = nonEmpty(sessionID) ?? ""
        let normalizedAgentID = nonEmpty(agentID)
        guard !normalizedSessionID.isEmpty || normalizedAgentID != nil else { return nil }

        let provenBinding = previouslyBoundBinding.flatMap { binding in
            (binding.taskStoreIdentity == nil || binding.taskStoreIdentity == taskStoreIdentity)
                && binding.matches(sessionID: normalizedSessionID, agentID: normalizedAgentID)
                ? binding
                : nil
        }
        var canReuseProvenBindingAfterCleanup = false
        if let provenBinding {
            try operationDeadline.check()
            switch try validateBoundTaskList(
                provenBinding,
                sessionID: normalizedSessionID,
                agentID: normalizedAgentID
            ) {
            case .matches(let refreshedBinding):
                guard let currentConfigurationGeneration = try teamConfigurationGeneration(
                    forTaskListID: provenBinding.taskListID
                ) else {
                    return ClaudeTeamTaskListResolution(
                        binding: refreshedBinding,
                        usesRetainedCleanupProof: true
                    )
                }
                if provenBinding.teamConfigurationGeneration == currentConfigurationGeneration {
                    return ClaudeTeamTaskListResolution(
                        binding: refreshedBinding.withTeamConfigurationGeneration(
                            currentConfigurationGeneration
                        ),
                        usesRetainedCleanupProof: false
                    )
                }
            case .missing:
                canReuseProvenBindingAfterCleanup = true
            case .doesNotMatch:
                break
            }
        }

        for _ in 0..<2 {
            try operationDeadline.check()
            let rootGenerationBeforeScan = try teamsRootGeneration()
            guard let generationBeforeScan = try teamConfigurationGeneration() else {
                let rootGenerationAfterMissingScan = try teamsRootGeneration()
                guard rootGenerationBeforeScan == rootGenerationAfterMissingScan else {
                    continue
                }
                guard canReuseProvenBindingAfterCleanup, let provenBinding else { return nil }
                return ClaudeTeamTaskListResolution(
                    binding: provenBinding,
                    usesRetainedCleanupProof: true
                )
            }

            var enumerationError: Error?
            let candidateEnumerator = fileManager.enumerator(
                at: teamsRootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, error in
                    if error.isClaudeTaskFilesystemItemMissing {
                        return true
                    }
                    enumerationError = error
                    return false
                }
            )
            try operationDeadline.check()
            guard let enumerator = candidateEnumerator else {
                throw ClaudeTaskSnapshotLoaderError.cannotEnumerateTeamsRoot
            }

            let decoder = JSONDecoder()
            var entryCount = 0
            var matchedBindings: [ClaudeTeamTaskListBinding] = []
            while let teamDirectory = enumerator.nextObject() as? URL {
                try operationDeadline.check()
                entryCount += 1
                guard entryCount <= Self.maximumTeamRootEntryCount else {
                    throw ClaudeTaskSnapshotLoaderError.tooManyTeamRootEntries(
                        limit: Self.maximumTeamRootEntryCount
                    )
                }
                let directoryValues: URLResourceValues
                do {
                    directoryValues = try teamDirectory.resourceValues(
                        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                    )
                } catch {
                    guard error.isClaudeTaskFilesystemItemMissing else { throw error }
                    continue
                }
                try operationDeadline.check()
                guard directoryValues.isDirectory == true,
                      directoryValues.isSymbolicLink != true else { continue }

                let configURL = teamDirectory.appendingPathComponent("config.json", isDirectory: false)
                let configValues: URLResourceValues
                do {
                    configValues = try configURL.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                    )
                } catch {
                    guard error.isClaudeTaskFilesystemItemMissing else { throw error }
                    continue
                }
                try operationDeadline.check()
                guard configValues.isRegularFile == true,
                      configValues.isSymbolicLink != true else { continue }

                let data: Data
                do {
                    data = try boundedConfigData(at: configURL)
                } catch {
                    guard error.isClaudeTaskFilesystemItemMissing else { throw error }
                    continue
                }
                try operationDeadline.check()
                let config: ClaudeTeamConfiguration
                do {
                    config = try decoder.decode(ClaudeTeamConfiguration.self, from: data)
                } catch is DecodingError {
                    continue
                }
                try operationDeadline.check()
                guard configuration(
                    config,
                    matchesSessionID: normalizedSessionID,
                    agentID: normalizedAgentID
                ) else {
                    continue
                }
                guard let binding = taskListBinding(
                    from: config,
                    teamDirectoryName: teamDirectory.lastPathComponent
                ) else {
                    throw ClaudeTaskSnapshotLoaderError.invalidTeamDirectoryBinding
                }
                matchedBindings.append(binding)
            }
            try operationDeadline.check()
            if let enumerationError { throw enumerationError }
            let generationAfterScan = try teamConfigurationGeneration()
            let rootGenerationAfterScan = try teamsRootGeneration()
            guard generationBeforeScan == generationAfterScan,
                  let stableConfigurationGeneration = generationAfterScan,
                  rootGenerationBeforeScan == rootGenerationAfterScan,
                  rootGenerationAfterScan != nil else {
                continue
            }
            guard matchedBindings.count <= 1 else {
                throw ClaudeTaskSnapshotLoaderError.ambiguousTeamMembership
            }
            if let matchedBinding = matchedBindings.first {
                let bindingGeneration = try teamConfigurationGeneration(
                    forTaskListID: matchedBinding.taskListID
                ) ?? stableConfigurationGeneration
                return ClaudeTeamTaskListResolution(
                    binding: matchedBinding.withTeamConfigurationGeneration(
                        bindingGeneration
                    ),
                    usesRetainedCleanupProof: false
                )
            }
            guard canReuseProvenBindingAfterCleanup, let provenBinding else { return nil }
            return ClaudeTeamTaskListResolution(
                binding: provenBinding,
                usesRetainedCleanupProof: true
            )
        }
        throw ClaudeTaskSnapshotLoaderError.teamConfigurationChangedDuringScan
    }

    /// Returns the current binding for a task-list name, regardless of hook identity.
    ///
    /// TeamDelete carries only the user-visible team name. This identity-only
    /// lookup lets the app distinguish a missing/deleted config from a newer
    /// team that reused the same task-list directory before clearing an old
    /// owner proof.
    ///
    /// - Parameter taskListID: The canonical task-list directory name.
    /// - Returns: The current binding, or `nil` when the team config is absent.
    /// - Throws: A filesystem or resource-bound error while scanning configs,
    ///   including ``ClaudeTaskSnapshotLoaderError/teamConfigurationChangedDuringScan``
    ///   when the identity changes during the lookup.
    public func currentTaskListBinding(
        forTaskListID taskListID: String
    ) throws -> ClaudeTeamTaskListBinding? {
        try operationDeadline.check()
        guard ClaudeTaskListDirectoryName(taskListID: taskListID)?.rawValue == taskListID,
              let rootGenerationBeforeScan = try teamsRootGeneration() else {
            return nil
        }
        let configurationGenerationBeforeScan = try teamConfigurationGeneration()
        var enumerationError: Error?
        let candidateEnumerator = fileManager.enumerator(
            at: teamsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                if error.isClaudeTaskFilesystemItemMissing { return true }
                enumerationError = error
                return false
            }
        )
        try operationDeadline.check()
        guard let enumerator = candidateEnumerator else {
            throw ClaudeTaskSnapshotLoaderError.cannotEnumerateTeamsRoot
        }
        let decoder = JSONDecoder()
        var entryCount = 0
        var matches: [ClaudeTeamTaskListBinding] = []
        while let teamDirectory = enumerator.nextObject() as? URL {
            try operationDeadline.check()
            entryCount += 1
            guard entryCount <= Self.maximumTeamRootEntryCount else {
                throw ClaudeTaskSnapshotLoaderError.tooManyTeamRootEntries(
                    limit: Self.maximumTeamRootEntryCount
                )
            }
            let directoryValues: URLResourceValues
            do {
                directoryValues = try teamDirectory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
            } catch {
                guard error.isClaudeTaskFilesystemItemMissing else { throw error }
                continue
            }
            guard directoryValues.isDirectory == true,
                  directoryValues.isSymbolicLink != true else { continue }
            let configURL = teamDirectory.appendingPathComponent("config.json", isDirectory: false)
            let configValues: URLResourceValues
            do {
                configValues = try configURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
            } catch {
                guard error.isClaudeTaskFilesystemItemMissing else { throw error }
                continue
            }
            guard configValues.isRegularFile == true,
                  configValues.isSymbolicLink != true else { continue }
            let data: Data
            do {
                data = try boundedConfigData(at: configURL)
            } catch {
                guard error.isClaudeTaskFilesystemItemMissing else { throw error }
                continue
            }
            guard let config = try? decoder.decode(ClaudeTeamConfiguration.self, from: data),
                  let binding = taskListBinding(
                      from: config,
                      teamDirectoryName: teamDirectory.lastPathComponent
                  ),
                  binding.taskListID == taskListID else { continue }
            matches.append(binding)
        }
        try operationDeadline.check()
        if let enumerationError { throw enumerationError }
        let rootGenerationAfterScan = try teamsRootGeneration()
        let configurationGenerationAfterScan = try teamConfigurationGeneration()
        guard rootGenerationBeforeScan == rootGenerationAfterScan,
              configurationGenerationBeforeScan == configurationGenerationAfterScan else {
            throw ClaudeTaskSnapshotLoaderError.teamConfigurationChangedDuringScan
        }
        guard let stableConfigurationGeneration = try teamConfigurationGeneration(
            forTaskListID: taskListID
        ) else {
            return nil
        }
        guard matches.count <= 1 else {
            throw ClaudeTaskSnapshotLoaderError.ambiguousTeamMembership
        }
        return matches.first?.withTeamConfigurationGeneration(stableConfigurationGeneration)
    }

    /// Reports whether a task-list binding now represents a newer team.
    ///
    /// A missing config is treated as deletion, not reuse. Legacy bindings
    /// without a stored generation compare their stable leader/member identity.
    public func taskListBindingWasReused(
        _ binding: ClaudeTeamTaskListBinding
    ) throws -> Bool {
        guard let current = try currentTaskListBinding(forTaskListID: binding.taskListID) else {
            return false
        }
        return taskListBindingWasReused(binding, capturedCurrentBinding: current)
    }

    /// Compares a proven binding with a current binding captured by the caller.
    ///
    /// - Parameters:
    ///   - binding: The durable owner proof being checked.
    ///   - capturedCurrentBinding: The current config binding already read under
    ///     the caller's synchronization boundary.
    /// - Returns: `true` when the current config represents a newer team.
    public func taskListBindingWasReused(
        _ binding: ClaudeTeamTaskListBinding,
        capturedCurrentBinding current: ClaudeTeamTaskListBinding
    ) -> Bool {
        guard current.leaderSessionID == binding.leaderSessionID,
              current.agentIDs == binding.agentIDs else {
            return true
        }
        guard let previousGeneration = binding.teamConfigurationGeneration else {
            return false
        }
        return current.teamConfigurationGeneration != previousGeneration
    }

    /// Validates a proven binding by reading only its canonical team config.
}
