public import Foundation

/// Validates Finder-style file URL payloads for creating a new sidebar workspace.
///
/// A successful result is exactly one local directory URL. Workspace identity is
/// never derived from this path — the directory is only the initial working
/// context for a newly created workspace.
public struct ExternalWorkspaceDirectoryDropValidator: Sendable {
    /// One accepted local directory ready to become a workspace working directory.
    public struct AcceptedDirectory: Equatable, Sendable {
        /// Standardized file URL for the directory.
        public let url: URL

        /// Path spelling used as the workspace working directory.
        ///
        /// Matches Finder / Dock external-open normalization: standardized path
        /// with trailing slashes stripped, without resolving symlinks for identity.
        public let path: String

        /// Creates an accepted directory snapshot.
        ///
        /// - Parameters:
        ///   - url: Standardized file URL for the directory.
        ///   - path: Working-directory path spelling to hand to workspace creation.
        public init(url: URL, path: String) {
            self.url = url
            self.path = path
        }
    }

    /// Why a Finder payload cannot create a workspace.
    public enum RejectionReason: Error, Equatable, Sendable {
        /// The pasteboard carried no file URLs.
        case emptyPayload
        /// More than one item was dragged; v1 accepts exactly one directory.
        case multipleItems
        /// The URL is not a local `file:` URL.
        case notLocalFileURL
        /// The path does not exist on disk at validation time.
        case missingPath
        /// The path exists but is not a directory.
        case notDirectory
    }

    /// Result of probing one URL against the filesystem.
    public enum DirectoryProbeResult: Equatable, Sendable {
        /// Nothing exists at the path.
        case missing
        /// A non-directory file exists at the path.
        case file
        /// A directory exists at the path (including macOS packages, matching
        /// current Finder / Dock external-open directory acceptance).
        case directory
    }

    /// Filesystem probe used by the validator.
    public typealias DirectoryProbe = @Sendable (URL) -> DirectoryProbeResult

    private let probe: DirectoryProbe

    /// Creates a validator.
    ///
    /// - Parameter probe: Filesystem classification for one URL. Defaults to
    ///   ``fileManagerProbe(_:)``, which mirrors AppDelegate external-open
    ///   directory detection (`hasDirectoryPath` / `isDirectory` resource values).
    public init(probe: @escaping DirectoryProbe = Self.fileManagerProbe) {
        self.probe = probe
    }

    /// Validates Finder file URLs for a single-directory workspace drop.
    ///
    /// - Parameter urls: Already-normalized file URLs (for example from
    ///   `PasteboardFileURLReader.fileURLs(from:)`).
    /// - Returns: The accepted directory, or a rejection reason.
    public func validate(_ urls: [URL]) -> Result<AcceptedDirectory, RejectionReason> {
        guard !urls.isEmpty else {
            return .failure(.emptyPayload)
        }
        guard urls.count == 1 else {
            return .failure(.multipleItems)
        }
        let url = urls[0]
        guard url.isFileURL else {
            return .failure(.notLocalFileURL)
        }

        let standardized = url.standardizedFileURL
        switch probe(standardized) {
        case .missing:
            return .failure(.missingPath)
        case .file:
            return .failure(.notDirectory)
        case .directory:
            let path = Self.canonicalDirectoryPath(
                standardized.path(percentEncoded: false)
            )
            guard !path.isEmpty else {
                return .failure(.missingPath)
            }
            return .success(AcceptedDirectory(url: standardized, path: path))
        }
    }

    /// Default probe aligned with `AppDelegate.externalOpenURLIsDirectory`.
    public static func fileManagerProbe(_ url: URL) -> DirectoryProbeResult {
        if url.hasDirectoryPath {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return .missing
            }
            return isDirectory.boolValue ? .directory : .file
        }
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
           let isDirectory = values.isDirectory {
            return isDirectory ? .directory : .file
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .directory : .file
    }

    private static func canonicalDirectoryPath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var canonical = path
        while canonical.count > 1 && canonical.hasSuffix("/") {
            canonical.removeLast()
        }
        return canonical
    }
}
