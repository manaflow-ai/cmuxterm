import Foundation
@testable import CMUXAgentLaunch

/// Runs one controlled mutation while the resolver is enumerating a team store.
final class MutatingTeamScanFileManager: ClaudeTaskFileSystem {
    private let fileManager = FileManager()
    private let mutation: () -> Void
    private var didMutate = false

    init(mutation: @escaping () -> Void) {
        self.mutation = mutation
    }

    func fileExists(
        atPath path: String,
        isDirectory: UnsafeMutablePointer<ObjCBool>?
    ) -> Bool {
        fileManager.fileExists(atPath: path, isDirectory: isDirectory)
    }

    func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = [],
        errorHandler handler: ((URL, any Error) -> Bool)? = nil
    ) -> FileManager.DirectoryEnumerator? {
        let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask,
            errorHandler: handler
        )
        if !didMutate {
            didMutate = true
            mutation()
        }
        return enumerator
    }

    func resourceValues(
        for url: URL,
        keys: Set<URLResourceKey>
    ) throws -> URLResourceValues {
        try fileManager.resourceValues(for: url, keys: keys)
    }
}
