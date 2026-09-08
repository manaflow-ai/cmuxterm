import Foundation
import Testing
@testable import CmuxExtensionKit

extension CmuxPluginSystemTests {
    @Test
    func snapshotCanonicalPathsIgnoreDirectoryURLHint() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshotter = CmuxPluginExecutionSnapshotter(rootDirectoryURL: root)
        let directoryURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let fileURL = URL(fileURLWithPath: root.path, isDirectory: false)

        #expect(await snapshotter.canonicalURL(directoryURL) == await snapshotter.canonicalURL(fileURL))
    }

    @Test
    func partialDirectoryLoadIgnoresUnrelatedRootEntryBudget() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.partial-reload",
            displayName: "Partial Reload",
            entrypoint: "bin/plugin"
        )
        try Self.writePlugin(manifest, to: root)
        for index in 0 ..< CmuxPluginDirectoryLoader.maximumRootEntryCount {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("unrelated-\(index)", isDirectory: true),
                withIntermediateDirectories: false
            )
        }

        let report = await CmuxPluginDirectoryLoader(directoryURL: root).load(only: [manifest.id])

        #expect(report.failures.isEmpty)
        #expect(report.plugins.map(\.manifest.id) == [manifest.id])
    }

    @Test
    func artifactFingerprintIncludesCaseMismatchedEntrypointInterpreter() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.case-insensitive-entrypoint",
            displayName: "Case Insensitive Entrypoint",
            entrypoint: "bin/plugin"
        )
        try Self.writePlugin(manifest, to: root)
        let pluginDirectory = root.appendingPathComponent(manifest.id, isDirectory: true)
        let manifestData = try Data(
            contentsOf: pluginDirectory.appendingPathComponent("manifest.json")
        )
        let fingerprinter = CmuxPluginArtifactFingerprinter()

        let withoutOverride = try fingerprinter.fingerprint(
            manifestData: manifestData,
            pluginDirectoryURL: pluginDirectory,
            entrypointDeclaration: "BIN/PLUGIN"
        )
        let withOverride = try fingerprinter.fingerprint(
            manifestData: manifestData,
            pluginDirectoryURL: pluginDirectory,
            entrypointDeclaration: "BIN/PLUGIN",
            interpreterData: Data("different interpreter bytes".utf8)
        )

        #expect(withoutOverride != withOverride)
    }

    @Test
    func artifactFingerprintIgnoresFinderMetadata() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.finder-metadata",
            displayName: "Finder Metadata",
            entrypoint: "bin/plugin"
        )
        try Self.writePlugin(manifest, to: root)
        let pluginDirectory = root.appendingPathComponent(manifest.id, isDirectory: true)
        try Data("finder metadata".utf8).write(
            to: pluginDirectory.appendingPathComponent(".DS_Store")
        )
        try Data("resource fork".utf8).write(
            to: pluginDirectory.appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("._plugin")
        )

        let report = await CmuxPluginDirectoryLoader(directoryURL: root).load()
        #expect(report.plugins.count == 1)
        let plugin = try #require(report.plugins.first)
        try FileManager.default.removeItem(
            at: pluginDirectory.appendingPathComponent(".DS_Store")
        )
        try FileManager.default.removeItem(
            at: pluginDirectory.appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("._plugin")
        )
        let cleanReport = await CmuxPluginDirectoryLoader(directoryURL: root).load()
        let cleanPlugin = try #require(cleanReport.plugins.first)
        #expect(plugin.manifestFingerprint == cleanPlugin.manifestFingerprint)
    }

    @Test
    func directoryLoaderRejectsManifestAndEntrypointSymlinkEscapes() async throws {
        let root = try Self.makeTemporaryDirectory()
        let outside = try Self.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let entrypointManifest = CmuxExtensionManifest.plugin(
            id: "dev.example.entrypoint-link",
            displayName: "Entrypoint Link",
            entrypoint: "bin/plugin"
        )
        let entrypointDirectory = root.appendingPathComponent(
            entrypointManifest.id,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: entrypointDirectory.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(entrypointManifest).write(
            to: entrypointDirectory.appendingPathComponent("manifest.json")
        )
        let outsideExecutable = outside.appendingPathComponent("plugin")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: outsideExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: outsideExecutable.path
        )
        try FileManager.default.createSymbolicLink(
            at: entrypointDirectory.appendingPathComponent("bin/plugin"),
            withDestinationURL: outsideExecutable
        )

        let manifestDirectory = root.appendingPathComponent(
            "dev.example.manifest-link",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: manifestDirectory,
            withIntermediateDirectories: true
        )
        let outsideManifest = CmuxExtensionManifest.plugin(
            id: "dev.example.manifest-link",
            displayName: "Manifest Link",
            entrypoint: "bin/plugin"
        )
        let outsideManifestURL = outside.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(outsideManifest).write(to: outsideManifestURL)
        try FileManager.default.createSymbolicLink(
            at: manifestDirectory.appendingPathComponent("manifest.json"),
            withDestinationURL: outsideManifestURL
        )

        let linkedDirectoryID = "dev.example.directory-link"
        let outsidePluginDirectory = outside.appendingPathComponent(
            linkedDirectoryID,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsidePluginDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(
            CmuxExtensionManifest.plugin(
                id: linkedDirectoryID,
                displayName: "Directory Link",
                entrypoint: "bin/plugin"
            )
        ).write(to: outsidePluginDirectory.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(linkedDirectoryID, isDirectory: true),
            withDestinationURL: outsidePluginDirectory
        )

        let report = await CmuxPluginDirectoryLoader(directoryURL: root).load()

        #expect(report.plugins.isEmpty)
        #expect(report.failures.count == 3)
        #expect(report.failures.contains { failure in
            failure.directoryURL.lastPathComponent == linkedDirectoryID
                && failure.code == .invalidManifest
        })
        #expect(report.failures.contains { failure in
            failure.directoryURL.lastPathComponent == entrypointManifest.id
                && failure.code == .missingEntrypoint
        })
        #expect(report.failures.contains { failure in
            failure.directoryURL.lastPathComponent == outsideManifest.id
                && failure.code == .invalidManifest
        })
    }
}
