import CryptoKit
import Darwin
import Foundation

extension ClaudeTeamTaskListResolver {
    func validateBoundTaskList(
        _ binding: ClaudeTeamTaskListBinding,
        sessionID: String,
        agentID: String?
    ) throws -> ClaudeTeamTaskListBoundValidation {
        try operationDeadline.check()
        guard binding.taskStoreIdentity == nil
                || binding.taskStoreIdentity == taskStoreIdentity else {
            return .doesNotMatch
        }
        guard let teamDirectoryName = ClaudeTeamDirectoryName(
            teamName: binding.taskListID
        )?.rawValue else {
            return .doesNotMatch
        }
        let teamDirectory = teamsRootURL.appendingPathComponent(
            teamDirectoryName,
            isDirectory: true
        )
        let directoryValues: URLResourceValues
        do {
            directoryValues = try teamDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            guard error.isClaudeTaskFilesystemItemMissing else { throw error }
            return .missing
        }
        try operationDeadline.check()
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            return .doesNotMatch
        }

        let configURL = teamDirectory.appendingPathComponent("config.json", isDirectory: false)
        let configValues: URLResourceValues
        do {
            configValues = try configURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            guard error.isClaudeTaskFilesystemItemMissing else { throw error }
            return .missing
        }
        try operationDeadline.check()
        guard configValues.isRegularFile == true,
              configValues.isSymbolicLink != true else {
            return .doesNotMatch
        }

        let data: Data
        do {
            data = try boundedConfigData(at: configURL)
        } catch {
            guard error.isClaudeTaskFilesystemItemMissing else { throw error }
            return .missing
        }
        try operationDeadline.check()
        let config = try? JSONDecoder().decode(ClaudeTeamConfiguration.self, from: data)
        try operationDeadline.check()
        guard let config,
              configuration(config, matchesSessionID: sessionID, agentID: agentID),
              let refreshedBinding = taskListBinding(
                  from: config,
                  teamDirectoryName: teamDirectoryName
              ),
              refreshedBinding.taskListID == binding.taskListID else {
            return .doesNotMatch
        }
        return .matches(refreshedBinding)
    }

    func configuration(
        _ config: ClaudeTeamConfiguration,
        matchesSessionID sessionID: String,
        agentID: String?
    ) -> Bool {
        if let agentID {
            return configurationAgentIDs(config).contains(agentID)
        }
        guard let leadSessionID = nonEmpty(config.leadSessionId),
              let hookSessionID = nonEmpty(sessionID) else {
            return false
        }
        return leadSessionID == hookSessionID
    }

    func taskListBinding(
        from config: ClaudeTeamConfiguration,
        teamDirectoryName: String
    ) -> ClaudeTeamTaskListBinding? {
        guard let canonicalTeamDirectoryName = ClaudeTeamDirectoryName(
                  teamName: config.name
              )?.rawValue,
              canonicalTeamDirectoryName == teamDirectoryName,
              let taskListID = ClaudeTaskListDirectoryName(
                  taskListID: config.name
              )?.rawValue else {
            return nil
        }
        return ClaudeTeamTaskListBinding(
            taskListID: taskListID,
            taskStoreIdentity: taskStoreIdentity,
            leaderSessionID: config.leadSessionId,
            agentIDs: configurationAgentIDs(config)
        )
    }

    func configurationAgentIDs(_ config: ClaudeTeamConfiguration) -> [String] {
        config.members.map(\.agentId) + [config.leadAgentId].compactMap { $0 }
    }

    func boundedConfigData(at fileURL: URL) throws -> Data {
        try operationDeadline.check()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumTeamConfigFileByteCount + 1) ?? Data()
        try operationDeadline.check()
        guard data.count <= Self.maximumTeamConfigFileByteCount else {
            throw ClaudeTaskSnapshotLoaderError.teamConfigFileTooLarge(
                fileName: fileURL.lastPathComponent,
                limit: Self.maximumTeamConfigFileByteCount
            )
        }
        return data
    }

    /// Captures the O(1) root stamp used by retained-binding fast paths.
    func teamsRootGeneration() throws -> String? {
        try operationDeadline.check()
        return try filesystemStamp(at: teamsRootURL)
    }

    /// Captures a bounded metadata generation for every direct team config.
    func teamConfigurationGeneration() throws -> String? {
        try operationDeadline.check()
        let rootValues: URLResourceValues
        do {
            rootValues = try teamsRootURL.resourceValues(
                forKeys: [.isDirectoryKey]
            )
        } catch {
            guard error.isClaudeTaskFilesystemItemMissing else { throw error }
            return nil
        }
        try operationDeadline.check()
        guard rootValues.isDirectory == true else {
            throw ClaudeTaskSnapshotLoaderError.cannotEnumerateTeamsRoot
        }

        var enumerationError: Error?
        let candidateEnumerator = fileManager.enumerator(
            at: teamsRootURL,
            includingPropertiesForKeys: nil,
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

        var stamps: [String] = []
        stamps.reserveCapacity(Self.maximumTeamRootEntryCount)
        var entryCount = 0
        while let entry = enumerator.nextObject() as? URL {
            try operationDeadline.check()
            entryCount += 1
            guard entryCount <= Self.maximumTeamRootEntryCount else {
                throw ClaudeTaskSnapshotLoaderError.tooManyTeamRootEntries(
                    limit: Self.maximumTeamRootEntryCount
                )
            }
            guard let entryStamp = try filesystemStamp(at: entry) else { continue }
            let configURL = entry.appendingPathComponent("config.json", isDirectory: false)
            let configStamp = try filesystemStamp(at: configURL) ?? "missing"
            stamps.append("\(entry.lastPathComponent)\0\(entryStamp)\0\(configStamp)")
        }
        try operationDeadline.check()
        if let enumerationError { throw enumerationError }
        let payload = Data(stamps.sorted().joined(separator: "\0").utf8)
        return Data(SHA256.hash(data: payload)).base64EncodedString()
    }

    /// Captures a generation for one canonical team config only.
    func teamConfigurationGeneration(
        forTaskListID taskListID: String
    ) throws -> String? {
        try operationDeadline.check()
        guard let directoryName = ClaudeTeamDirectoryName(
            teamName: taskListID
        )?.rawValue else {
            return nil
        }
        let directoryURL = teamsRootURL.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
        let directoryStamp = try filesystemStamp(at: directoryURL)
        let configStamp = try filesystemStamp(
            at: directoryURL.appendingPathComponent("config.json", isDirectory: false)
        ) ?? "missing"
        guard let directoryStamp else { return nil }
        let payload = Data(
            "\(directoryName)\0\(directoryStamp)\0\(configStamp)".utf8
        )
        return Data(SHA256.hash(data: payload)).base64EncodedString()
    }

    /// Returns an `lstat` stamp that changes with type, identity, or contents.
    func filesystemStamp(at url: URL) throws -> String? {
        try operationDeadline.check()
        var metadata = stat()
        let result = lstat(url.path, &metadata)
        let errorNumber = errno
        try operationDeadline.check()
        guard result == 0 else {
            let code = POSIXErrorCode(rawValue: errorNumber) ?? .EIO
            guard code == .ENOENT || code == .ENOTDIR else { throw POSIXError(code) }
            return nil
        }
        return [
            String(metadata.st_dev),
            String(metadata.st_ino),
            String(metadata.st_mode),
            String(metadata.st_size),
            String(metadata.st_mtimespec.tv_sec),
            String(metadata.st_mtimespec.tv_nsec),
            String(metadata.st_ctimespec.tv_sec),
            String(metadata.st_ctimespec.tv_nsec),
        ].joined(separator: ":")
    }

    func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
