import Darwin
import Foundation

extension CursorNativeApprovalObserverLease {
    private static let staleLeaseAge: TimeInterval = 30
    private static let maximumLeaseRecordBytes = 512
    private static let lockFileName = ".observer-leases.lock"

    static func generationDirectoryURL(
        processIdentity: AgentPIDProcessIdentity,
        rootDirectory: URL
    ) -> URL {
        rootDirectory.appendingPathComponent(
            "\(processIdentity.pid)-\(processIdentity.startSeconds)-\(processIdentity.startMicroseconds)",
            isDirectory: true
        )
    }
    static func acquireRootLock(rootDirectory: URL) -> Int32? {
        do {
            try FileManager.default.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            return nil
        }
        let lockURL = rootDirectory.appendingPathComponent(
            lockFileName,
            isDirectory: false
        )
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }
        // A POSIX file lock is required because independent hook CLI processes
        // cannot share an actor while claiming the same fixed slot table.
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }
    static func releaseRootLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
    static func isStaleLeaseFile(at url: URL) -> Bool {
        var fileInfo = stat()
        guard lstat(url.path, &fileInfo) == 0,
              fileInfo.st_mode & S_IFMT == S_IFREG else {
            return false
        }
        let modifiedAt = TimeInterval(fileInfo.st_mtimespec.tv_sec)
            + TimeInterval(fileInfo.st_mtimespec.tv_nsec) / 1_000_000_000
        return Date.now.timeIntervalSince1970 - modifiedAt >= staleLeaseAge
    }

    static func createLeaseFile(
        at url: URL,
        contents: [UInt8]
    ) -> Bool {
        let descriptor = open(
            url.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let didWrite = writeAll(contents, to: descriptor)
        if !didWrite {
            _ = unlink(url.path)
        }
        return didWrite
    }

    static func replaceLeaseFile(
        at url: URL,
        contents: [UInt8]
    ) -> Bool {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
                isDirectory: false
            )
        guard createLeaseFile(at: temporaryURL, contents: contents) else {
            return false
        }
        guard rename(temporaryURL.path, url.path) == 0 else {
            _ = unlink(temporaryURL.path)
            return false
        }
        return true
    }

    static func writeAll(
        _ bytes: [UInt8],
        to descriptor: Int32
    ) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }

    static func readLeaseRecord(
        at url: URL
    ) -> (
        leaseID: String,
        observationID: String,
        childProcessIdentity: AgentPIDProcessIdentity?
    )? {
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              fileInfo.st_mode & S_IFMT == S_IFREG,
              fileInfo.st_size > 0,
              fileInfo.st_size <= off_t(maximumLeaseRecordBytes) else {
            return nil
        }
        var bytes = [UInt8](
            repeating: 0,
            count: Int(fileInfo.st_size)
        )
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            offset += count
        }
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            return nil
        }
        let lines = value.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard lines.count >= 3,
              UUID(uuidString: lines[0]) != nil,
              let observationID = AgentAttentionOpaqueIdentifier(
                  rawValue: lines[1]
              )?.rawValue else {
            return nil
        }
        let childProcessIdentity: AgentPIDProcessIdentity?
        if lines.count >= 6,
           let pid = Int32(lines[2]),
           pid > 0,
           let startSeconds = Int64(lines[3]),
           let startMicroseconds = Int64(lines[4]) {
            childProcessIdentity = AgentPIDProcessIdentity(
                pid: pid,
                startSeconds: startSeconds,
                startMicroseconds: startMicroseconds
            )
        } else {
            childProcessIdentity = nil
        }
        return (
            leaseID: lines[0].lowercased(),
            observationID: observationID,
            childProcessIdentity: childProcessIdentity
        )
    }

    static func cancelMatchingLeases(
        processIdentity: AgentPIDProcessIdentity,
        rootDirectory: URL,
        matches: (String) -> Bool
    ) {
        guard let lockDescriptor = acquireRootLock(
            rootDirectory: rootDirectory
        ) else {
            return
        }
        var childProcessIdentities: [AgentPIDProcessIdentity] = []
        let generationDirectory = generationDirectoryURL(
            processIdentity: processIdentity,
            rootDirectory: rootDirectory
        )
        for slotIndex in 0 ..< maximumConcurrentObserversPerProcess {
            let slotURL = generationDirectory.appendingPathComponent(
                "slot-\(slotIndex)",
                isDirectory: false
            )
            guard let record = readLeaseRecord(at: slotURL),
                  matches(record.observationID) else {
                continue
            }
            _ = unlink(slotURL.path)
            if let childProcessIdentity = record.childProcessIdentity {
                childProcessIdentities.append(childProcessIdentity)
            }
        }
        _ = rmdir(generationDirectory.path)
        releaseRootLock(lockDescriptor)

        for childProcessIdentity in childProcessIdentities
        where AgentPIDProcessIdentity(
            agentTurnPID: Int(childProcessIdentity.pid)
        ) == childProcessIdentity {
            _ = Darwin.kill(childProcessIdentity.pid, SIGTERM)
        }
    }
}
