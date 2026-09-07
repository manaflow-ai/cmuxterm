import Darwin
import Foundation

/// Owns one cross-process slot for a detached Cursor approval observer.
struct CursorNativeApprovalObserverLease: Sendable {
    static let maximumConcurrentObserversPerProcess = 8


    let processIdentity: AgentPIDProcessIdentity
    let slotIndex: Int
    let leaseID: String
    let observationID: String
    private let rootDirectory: URL

    /// Claims one bounded slot before the detached observer is spawned.
    static func claim(
        processIdentity: AgentPIDProcessIdentity,
        observationID: String
    ) -> Self? {
        claim(
            processIdentity: processIdentity,
            observationID: observationID,
            rootDirectory: defaultRootDirectory
        )
    }

    /// Claims one bounded slot under an explicit root directory.
    static func claim(
        processIdentity: AgentPIDProcessIdentity,
        observationID: String,
        rootDirectory: URL
    ) -> Self? {
        guard let observationID = AgentAttentionOpaqueIdentifier(
            rawValue: observationID
        )?.rawValue else {
            return nil
        }
        let rootDirectory = rootDirectory.standardizedFileURL
        guard let lockDescriptor = acquireRootLock(
            rootDirectory: rootDirectory
        ) else {
            return nil
        }
        defer { releaseRootLock(lockDescriptor) }

        let generationDirectory = generationDirectoryURL(
            processIdentity: processIdentity,
            rootDirectory: rootDirectory
        )
        do {
            try FileManager.default.createDirectory(
                at: generationDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            return nil
        }

        for slotIndex in 0 ..< maximumConcurrentObserversPerProcess {
            let slotURL = generationDirectory.appendingPathComponent(
                "slot-\(slotIndex)",
                isDirectory: false
            )
            if let record = readLeaseRecord(at: slotURL),
               record.observationID == observationID,
               !isStaleLeaseFile(at: slotURL) {
                return nil
            }
        }
        for slotIndex in 0 ..< maximumConcurrentObserversPerProcess {
            let lease = Self(
                processIdentity: processIdentity,
                slotIndex: slotIndex,
                leaseID: UUID().uuidString.lowercased(),
                observationID: observationID,
                rootDirectory: rootDirectory
            )
            if isStaleLeaseFile(at: lease.slotURL) {
                let childProcessIdentity = readLeaseRecord(
                    at: lease.slotURL
                )?.childProcessIdentity
                if childProcessIdentity.map({
                    AgentPIDProcessIdentity(
                        agentTurnPID: Int($0.pid)
                    ) == $0
                }) != true {
                    _ = unlink(lease.slotURL.path)
                }
            }
            if createLeaseFile(
                at: lease.slotURL,
                contents: lease.serializedRecord(childProcessIdentity: nil)
            ) {
                return lease
            }
        }
        return nil
    }

    /// Reconstructs the slot identity passed to a detached observer child.
    static func existing(
        processIdentity: AgentPIDProcessIdentity,
        slotIndex: Int,
        leaseID: String,
        observationID: String
    ) -> Self? {
        existing(
            processIdentity: processIdentity,
            slotIndex: slotIndex,
            leaseID: leaseID,
            observationID: observationID,
            rootDirectory: defaultRootDirectory
        )
    }

    /// Reconstructs a slot identity under an explicit root directory.
    static func existing(
        processIdentity: AgentPIDProcessIdentity,
        slotIndex: Int,
        leaseID: String,
        observationID: String,
        rootDirectory: URL
    ) -> Self? {
        guard (0 ..< maximumConcurrentObserversPerProcess).contains(slotIndex),
              UUID(uuidString: leaseID) != nil,
              let observationID = AgentAttentionOpaqueIdentifier(
                  rawValue: observationID
              )?.rawValue else {
            return nil
        }
        return Self(
            processIdentity: processIdentity,
            slotIndex: slotIndex,
            leaseID: leaseID.lowercased(),
            observationID: observationID,
            rootDirectory: rootDirectory.standardizedFileURL
        )
    }

    /// Arguments that transfer exact lease ownership to the observer child.
    var commandArguments: [String] {
        [
            "--observer-lease-slot", String(slotIndex),
            "--observer-lease-id", leaseID,
        ]
    }

    /// Whether this value still owns its exact on-disk slot.
    var isCurrent: Bool {
        guard let lockDescriptor = Self.acquireRootLock(
            rootDirectory: rootDirectory
        ) else {
            return false
        }
        defer { Self.releaseRootLock(lockDescriptor) }
        guard let record = Self.readLeaseRecord(at: slotURL) else {
            return false
        }
        return record.leaseID == leaseID
            && record.observationID == observationID
    }

    /// Attaches the exact spawned child generation to this claimed slot.
    func activate(
        childProcessIdentity: AgentPIDProcessIdentity
    ) -> Bool {
        guard let lockDescriptor = Self.acquireRootLock(
            rootDirectory: rootDirectory
        ) else {
            return false
        }
        defer { Self.releaseRootLock(lockDescriptor) }
        guard let record = Self.readLeaseRecord(at: slotURL),
              record.leaseID == leaseID,
              record.observationID == observationID else {
            return false
        }
        return Self.replaceLeaseFile(
            at: slotURL,
            contents: serializedRecord(
                childProcessIdentity: childProcessIdentity
            )
        )
    }

    /// Releases the slot only when its exact lease identity still matches.
    func release() {
        guard let lockDescriptor = Self.acquireRootLock(
            rootDirectory: rootDirectory
        ) else {
            return
        }
        defer { Self.releaseRootLock(lockDescriptor) }
        guard let record = Self.readLeaseRecord(at: slotURL),
              record.leaseID == leaseID,
              record.observationID == observationID else {
            return
        }
        _ = unlink(slotURL.path)
        _ = rmdir(generationDirectoryURL.path)
    }

    /// Cancels the exact observation owned by one process generation.
    static func cancel(
        processIdentity: AgentPIDProcessIdentity,
        observationID: String
    ) {
        cancel(
            processIdentity: processIdentity,
            observationID: observationID,
            rootDirectory: defaultRootDirectory
        )
    }

    /// Cancels an exact observation under an explicit root directory.
    static func cancel(
        processIdentity: AgentPIDProcessIdentity,
        observationID: String,
        rootDirectory: URL
    ) {
        guard let observationID = AgentAttentionOpaqueIdentifier(
            rawValue: observationID
        )?.rawValue else {
            return
        }
        cancelMatchingLeases(
            processIdentity: processIdentity,
            rootDirectory: rootDirectory.standardizedFileURL
        ) { $0 == observationID }
    }

    /// Cancels every observer owned by one exact process generation.
    static func cancelAll(
        processIdentity: AgentPIDProcessIdentity
    ) {
        cancelMatchingLeases(
            processIdentity: processIdentity,
            rootDirectory: defaultRootDirectory
        ) { _ in true }
    }

    private static var defaultRootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cursor-approval-observers-\(getuid())",
                isDirectory: true
            )
            .standardizedFileURL
    }
    private var generationDirectoryURL: URL {
        Self.generationDirectoryURL(
            processIdentity: processIdentity,
            rootDirectory: rootDirectory
        )
    }
    private var slotURL: URL {
        generationDirectoryURL.appendingPathComponent(
            "slot-\(slotIndex)",
            isDirectory: false
        )
    }
    private func serializedRecord(
        childProcessIdentity: AgentPIDProcessIdentity?
    ) -> [UInt8] {
        var lines = [leaseID, observationID]
        if let childProcessIdentity {
            lines += [
                String(childProcessIdentity.pid),
                String(childProcessIdentity.startSeconds),
                String(childProcessIdentity.startMicroseconds),
            ]
        }
        return Array((lines.joined(separator: "\n") + "\n").utf8)
    }
}
