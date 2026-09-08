import Foundation

extension ClaudeTaskSnapshotLoader {
    func snapshot(in sessionDirectory: URL) throws -> ClaudeTaskSnapshot {
        try operationDeadline.check()
        var enumerationError: Error?
        let candidateEnumerator = fileSystem.enumerator(
            at: sessionDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
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
            throw ClaudeTaskSnapshotLoaderError.cannotEnumerateSessionDirectory
        }
        let decoder = JSONDecoder()
        var todos: [WorkstreamTaskTodo] = []
        var entryCount = 0
        var snapshotTextByteCount = 0
        while let fileURL = enumerator.nextObject() as? URL {
            try operationDeadline.check()
            entryCount += 1
            guard entryCount <= Self.maximumDirectoryEntryCount else {
                throw ClaudeTaskSnapshotLoaderError.tooManyDirectoryEntries(
                    limit: Self.maximumDirectoryEntryCount
                )
            }
            guard fileURL.pathExtension.lowercased() == "json" else { continue }
            let values: URLResourceValues
            do {
                values = try fileSystem.resourceValues(
                    for: fileURL,
                    keys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
            } catch {
                guard error.isClaudeTaskFilesystemItemMissing else { throw error }
                continue
            }
            try operationDeadline.check()
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let data: Data
            do {
                data = try boundedTaskData(
                    at: fileURL,
                    maximumByteCount: Self.maximumTaskFileByteCount
                )
            } catch {
                guard error.isClaudeTaskFilesystemItemMissing else { throw error }
                continue
            }
            try operationDeadline.check()
            guard let record = try? decoder.decode(ClaudeTaskRecord.self, from: data),
                  let taskID = validPathComponent(record.id),
                  taskID == record.id,
                  fileURL.deletingPathExtension().lastPathComponent == taskID,
                  let state = record.canonicalState else { continue }
            try validateTaskText(record.subject, field: "subject", fileURL: fileURL)
            if let activeForm = record.activeForm {
                try validateTaskText(activeForm, field: "activeForm", fileURL: fileURL)
            }
            guard let content = nonEmptyTaskText(record.subject) else { continue }
            let activeForm = nonEmptyTaskText(record.activeForm)
            let taskTextByteCount = content.utf8.count + (activeForm?.utf8.count ?? 0)
            guard taskTextByteCount <= Self.maximumSnapshotTextByteCount - snapshotTextByteCount else {
                throw ClaudeTaskSnapshotLoaderError.snapshotTextTooLarge(
                    limit: Self.maximumSnapshotTextByteCount
                )
            }
            snapshotTextByteCount += taskTextByteCount
            todos.append(WorkstreamTaskTodo(
                id: taskID,
                content: content,
                activeForm: activeForm,
                state: state
            ))
        }
        try operationDeadline.check()
        if let enumerationError { throw enumerationError }
        let sortedTodos = todos.sorted(by: taskSort)
        try operationDeadline.check()
        return ClaudeTaskSnapshot(
            directoryName: sessionDirectory.lastPathComponent,
            todos: sortedTodos
        )
    }

    func sessionDirectoryURL(sessionID: String) throws -> URL? {
        try operationDeadline.check()
        guard let trimmed = validPathComponent(sessionID) else { return nil }
        let bareID = trimmed.hasPrefix("session-")
            ? String(trimmed.dropFirst("session-".count))
            : trimmed
        let names = [trimmed, bareID, "session-\(bareID)"]
        var seen = Set<String>()
        for name in names where !name.isEmpty && seen.insert(name).inserted {
            try operationDeadline.check()
            if let candidate = try directoryURL(named: name) {
                return candidate
            }
        }
        return nil
    }

    func uniquelyMatchingDirectory(
        for identity: ClaudeTaskIdentity,
        decoder: JSONDecoder
    ) throws -> URL? {
        try operationDeadline.check()
        guard validPathComponent(identity.id) == identity.id,
              !identity.subject.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        let rootExists = fileSystem.fileExists(
            atPath: tasksRootURL.path,
            isDirectory: &isDirectory
        )
        try operationDeadline.check()
        guard rootExists,
              isDirectory.boolValue else { return nil }

        var enumerationError: Error?
        let candidateEnumerator = fileSystem.enumerator(
            at: tasksRootURL,
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
            throw ClaudeTaskSnapshotLoaderError.cannotEnumerateTasksRoot
        }

        var entryCount = 0
        var match: URL?
        while let candidate = enumerator.nextObject() as? URL {
            try operationDeadline.check()
            entryCount += 1
            guard entryCount <= Self.maximumTaskRootEntryCount else {
                throw ClaudeTaskSnapshotLoaderError.tooManyTaskRootEntries(
                    limit: Self.maximumTaskRootEntryCount
                )
            }
            let values: URLResourceValues
            do {
                values = try fileSystem.resourceValues(
                    for: candidate,
                    keys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
            } catch {
                guard error.isClaudeTaskFilesystemItemMissing else { throw error }
                continue
            }
            try operationDeadline.check()
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  try taskFile(in: candidate, matches: identity, decoder: decoder) else { continue }
            guard match == nil else { return nil }
            match = candidate
        }
        try operationDeadline.check()
        if let enumerationError { throw enumerationError }
        return match
    }

    func taskFile(
        in directory: URL,
        matches identity: ClaudeTaskIdentity,
        decoder: JSONDecoder
    ) throws -> Bool {
        try operationDeadline.check()
        guard let taskID = validPathComponent(identity.id), taskID == identity.id else { return false }
        let fileURL = directory.appendingPathComponent("\(taskID).json", isDirectory: false)
        let values: URLResourceValues
        do {
            values = try fileSystem.resourceValues(
                for: fileURL,
                keys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            guard error.isClaudeTaskFilesystemItemMissing else { throw error }
            return false
        }
        try operationDeadline.check()
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        let data: Data
        do {
            data = try boundedTaskData(
                at: fileURL,
                maximumByteCount: Self.maximumTaskFileByteCount
            )
        } catch {
            guard error.isClaudeTaskFilesystemItemMissing else { throw error }
            return false
        }
        try operationDeadline.check()
        guard let record = try? decoder.decode(ClaudeTaskRecord.self, from: data) else { return false }
        guard record.id == identity.id,
              record.subject == identity.subject,
              record.canonicalState != nil else { return false }
        try validateTaskText(record.subject, field: "subject", fileURL: fileURL)
        return true
    }

    func directoryURL(named name: String) throws -> URL? {
        try operationDeadline.check()
        guard let name = validPathComponent(name) else { return nil }
        let candidate = tasksRootURL.appendingPathComponent(name, isDirectory: true)
        let values: URLResourceValues
        do {
            values = try fileSystem.resourceValues(
                for: candidate,
                keys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            guard error.isClaudeTaskFilesystemItemMissing else { throw error }
            return nil
        }
        try operationDeadline.check()
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ClaudeTaskSnapshotLoaderError.invalidTaskDirectory(
                directoryName: name
            )
        }
        return candidate
    }

    func validPathComponent(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\0") else {
            return nil
        }
        return trimmed
    }

    func nonEmptyTaskText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func validateTaskText(
        _ value: String,
        field: String,
        fileURL: URL
    ) throws {
        guard value.utf8.count <= Self.maximumTaskTextByteCount else {
            throw ClaudeTaskSnapshotLoaderError.taskTextTooLarge(
                fileName: fileURL.lastPathComponent,
                field: field,
                limit: Self.maximumTaskTextByteCount
            )
        }
    }

    func taskSort(_ lhs: WorkstreamTaskTodo, _ rhs: WorkstreamTaskTodo) -> Bool {
        if let leftNumber = Int(lhs.id), let rightNumber = Int(rhs.id), leftNumber != rightNumber {
            return leftNumber < rightNumber
        }
        return lhs.id < rhs.id
    }

    func boundedTaskData(at fileURL: URL, maximumByteCount: Int) throws -> Data {
        try operationDeadline.check()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumByteCount + 1) ?? Data()
        try operationDeadline.check()
        guard data.count <= maximumByteCount else {
            throw ClaudeTaskSnapshotLoaderError.taskFileTooLarge(
                fileName: fileURL.lastPathComponent,
                limit: maximumByteCount
            )
        }
        return data
    }
}
