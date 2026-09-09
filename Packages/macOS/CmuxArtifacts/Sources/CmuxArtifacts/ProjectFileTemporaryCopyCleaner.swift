import Darwin
public import Foundation

/// Reclaims expired editor handoff copies while enforcing bounded temporary storage.
public struct ProjectFileTemporaryCopyCleaner {
    private static let maximumFileCount = 256
    private static let maximumByteCount: Int64 = 256 * 1024 * 1024

    private let fileManager: FileManager
    private let now: Date

    /// Creates a temporary-copy cleaner with injectable filesystem and clock inputs.
    ///
    /// - Parameters:
    ///   - fileManager: Filesystem used to enumerate temporary copies.
    ///   - now: Reference time used to determine whether a copy's lease expired.
    public init(fileManager: FileManager = .default, now: Date = .now) {
        self.fileManager = fileManager
        self.now = now
    }

    /// Removes expired copies beyond the bounds and evaluates a requested reservation.
    ///
    /// Fresh copies retain a 24-hour lease and are never evicted to satisfy a
    /// reservation. Only regular files whose names begin with
    /// `cmux-project-file-` are considered.
    ///
    /// - Parameters:
    ///   - directory: Directory containing editor handoff copies.
    ///   - reservingBytes: Bytes needed by the pending handoff.
    ///   - reservingFileCount: File slots needed by the pending handoff.
    /// - Returns: Whether the protected and retained copies leave room for the reservation.
    @discardableResult
    public func cleanup(
        in directory: URL,
        reservingBytes: Int64 = 0,
        reservingFileCount: Int = 0
    ) -> Bool {
        guard reservingBytes >= 0, reservingBytes <= Self.maximumByteCount else {
            return false
        }
        guard reservingFileCount >= 0, reservingFileCount <= Self.maximumFileCount else {
            return false
        }
        // LaunchServices has no completion callback for the editor that owns
        // this handoff. Treat the age threshold as a lease: fresh copies are
        // never evicted by count/bytes while an editor may still use them.
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return true }
        let directoryPath = directory.standardizedFileURL.path
        var reclaimable: [(url: URL, size: Int64, modifiedAt: Date)] = []
        var protectedCount = 0
        var protectedBytes: Int64 = 0
        var unreclaimedCount = 0
        var unreclaimedBytes: Int64 = 0

        func recordUnreclaimed(_ size: Int64) {
            unreclaimedCount += 1
            unreclaimedBytes = unreclaimedBytes > Self.maximumByteCount - size
                ? Self.maximumByteCount
                : unreclaimedBytes + size
        }

        for case let entry as URL in enumerator {
            guard entry.deletingLastPathComponent().standardizedFileURL.path == directoryPath,
                  entry.lastPathComponent.hasPrefix("cmux-project-file-") else {
                continue
            }
            var status = stat()
            guard lstat(entry.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_size >= 0 else {
                continue
            }
            let modifiedAt = Date(timeIntervalSince1970: Double(status.st_mtimespec.tv_sec))
            guard modifiedAt < cutoff else {
                // Preserve the active lease even if many editor handoffs are
                // open. A later cleanup after expiry reclaims this copy.
                protectedCount += 1
                let size = Int64(status.st_size)
                protectedBytes = protectedBytes > Self.maximumByteCount - size
                    ? Self.maximumByteCount
                    : protectedBytes + size
                continue
            }
            let candidate = (
                url: entry,
                size: Int64(status.st_size),
                modifiedAt: modifiedAt
            )
            if reclaimable.count < Self.maximumFileCount {
                reclaimable.append(candidate)
                continue
            }
            guard let oldestIndex = reclaimable.indices.min(by: { lhs, rhs in
                if reclaimable[lhs].modifiedAt != reclaimable[rhs].modifiedAt {
                    return reclaimable[lhs].modifiedAt < reclaimable[rhs].modifiedAt
                }
                return reclaimable[lhs].url.path < reclaimable[rhs].url.path
            }) else {
                continue
            }
            let oldest = reclaimable[oldestIndex]
            let candidateIsNewer = candidate.modifiedAt > oldest.modifiedAt
                || (candidate.modifiedAt == oldest.modifiedAt
                    && candidate.url.path > oldest.url.path)
            if candidateIsNewer {
                if removeExpiredCopy(at: oldest.url) {
                    reclaimable[oldestIndex] = candidate
                } else {
                    // The failed eviction still occupies capacity even when
                    // the newer candidate can be discarded successfully.
                    recordUnreclaimed(oldest.size)
                    if !removeExpiredCopy(at: candidate.url) {
                        recordUnreclaimed(candidate.size)
                    }
                }
            } else if !removeExpiredCopy(at: candidate.url) {
                recordUnreclaimed(candidate.size)
            }
        }
        guard protectedCount <= Self.maximumFileCount - reservingFileCount,
              protectedBytes <= Self.maximumByteCount,
              protectedBytes <= Self.maximumByteCount - reservingBytes else {
            return false
        }
        let availableCount = Self.maximumFileCount - protectedCount - reservingFileCount
        let availableBytes = Self.maximumByteCount - protectedBytes - reservingBytes
        reclaimable.sort {
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.url.path > $1.url.path
        }
        var retainedBytes: Int64 = 0
        var retainedCount = 0
        for entry in reclaimable {
            guard retainedCount < availableCount,
                  entry.size <= availableBytes,
                  retainedBytes <= availableBytes - entry.size else {
                if !removeExpiredCopy(at: entry.url) {
                    recordUnreclaimed(entry.size)
                }
                continue
            }
            retainedBytes += entry.size
            retainedCount += 1
        }
        // A zero-byte note/artifact still creates a leased temporary file, so
        // reserve its slot independently of the byte reservation. Failed
        // unlinks remain counted because the next open will still observe them.
        return unreclaimedCount <= availableCount - retainedCount
            && unreclaimedBytes <= availableBytes - retainedBytes
    }

    private func removeExpiredCopy(at url: URL) -> Bool {
        let result = unlink(url.path)
        return result == 0 || errno == ENOENT
    }
}
