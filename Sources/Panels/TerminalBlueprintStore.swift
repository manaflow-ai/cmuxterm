import Foundation

/// Persists blueprint scenes on disk, one JSON document per stable surface id.
///
/// Documents live under
/// `~/Library/Application Support/cmux/blueprints-<bundle id>/<surface id>.excalidraw.json`
/// so tagged dev builds never overwrite the main app's blueprints. Exports
/// (PNG/SVG) written next to a document use the same id with another extension.
actor TerminalBlueprintStore: TerminalBlueprintPersisting {
    static let documentExtension = "excalidraw.json"

    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// The per-app blueprint directory, or nil under automated tests and when
    /// Application Support cannot be resolved.
    nonisolated static func defaultDirectory(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        guard !isRunningUnderAutomatedTests else { return nil }
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedBundleID = trimmed.isEmpty ? "com.cmuxterm.app" : trimmed
        let safeBundleID = resolvedBundleID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return resolvedAppSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("blueprints-\(safeBundleID)", isDirectory: true)
    }

    /// Creates the default store, or nil when there is no writable location.
    nonisolated static func makeDefault() -> TerminalBlueprintStore? {
        guard let directory = defaultDirectory() else { return nil }
        return TerminalBlueprintStore(directory: directory)
    }

    func load(surfaceID: UUID) throws -> TerminalBlueprintDocument? {
        let url = documentURL(surfaceID: surfaceID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TerminalBlueprintDocument.self, from: data)
    }

    func save(_ document: TerminalBlueprintDocument) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: documentURL(surfaceID: document.surfaceID), options: .atomic)
    }

    func delete(surfaceID: UUID) throws {
        let url = documentURL(surfaceID: surfaceID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Writes an export artifact (for example the latest PNG) next to the document.
    func writeExport(surfaceID: UUID, data: Data, fileExtension: String) throws -> URL {
        try ensureDirectory()
        let url = exportURL(surfaceID: surfaceID, fileExtension: fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    nonisolated func exportURL(surfaceID: UUID, fileExtension: String) -> URL {
        directory.appendingPathComponent(
            "\(surfaceID.uuidString).\(fileExtension)",
            isDirectory: false
        )
    }

    nonisolated func documentURL(surfaceID: UUID) -> URL {
        directory.appendingPathComponent(
            "\(surfaceID.uuidString).\(Self.documentExtension)",
            isDirectory: false
        )
    }

    private func ensureDirectory() throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
