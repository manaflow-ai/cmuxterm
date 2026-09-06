import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("TerminalBlueprintStore")
struct TerminalBlueprintStoreTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-blueprint-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("documents round-trip through disk")
    func roundTrip() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalBlueprintStore(directory: directory)
        let surfaceID = UUID()
        let document = TerminalBlueprintDocument(
            surfaceID: surfaceID,
            sceneJSON: #"{"elements":[{"id":"a"}]}"#,
            mermaidSource: "flowchart LR; A-->B",
            revision: 7,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastAuthor: .agent
        )
        try await store.save(document)
        let loaded = try #require(try await store.load(surfaceID: surfaceID))
        #expect(loaded.surfaceID == surfaceID)
        #expect(loaded.sceneJSON == document.sceneJSON)
        #expect(loaded.mermaidSource == document.mermaidSource)
        #expect(loaded.revision == 7)
        #expect(loaded.lastAuthor == .agent)
        #expect(abs(loaded.updatedAt.timeIntervalSince(document.updatedAt)) < 1)
        #expect(loaded.version == TerminalBlueprintDocument.currentVersion)
    }

    @Test("a missing document loads as nil and delete is idempotent")
    func missingAndDelete() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalBlueprintStore(directory: directory)
        let surfaceID = UUID()
        #expect(try await store.load(surfaceID: surfaceID) == nil)
        try await store.delete(surfaceID: surfaceID)
        try await store.save(TerminalBlueprintDocument(
            surfaceID: surfaceID,
            sceneJSON: "{}",
            revision: 1,
            updatedAt: Date(),
            lastAuthor: .user
        ))
        #expect(try await store.load(surfaceID: surfaceID) != nil)
        try await store.delete(surfaceID: surfaceID)
        #expect(try await store.load(surfaceID: surfaceID) == nil)
    }

    @Test("the store creates its directory on first save")
    func createsDirectory() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("nested/blueprints", isDirectory: true)
        let store = TerminalBlueprintStore(directory: directory)
        try await store.save(TerminalBlueprintDocument(
            surfaceID: UUID(),
            sceneJSON: "{}",
            revision: 1,
            updatedAt: Date(),
            lastAuthor: .user
        ))
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("exports are written next to the document")
    func writesExports() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalBlueprintStore(directory: directory)
        let surfaceID = UUID()
        let url = try await store.writeExport(surfaceID: surfaceID, data: Data([0x89, 0x50]), fileExtension: "png")
        #expect(url.lastPathComponent == "\(surfaceID.uuidString).png")
        #expect(try Data(contentsOf: url) == Data([0x89, 0x50]))
    }

    @Test("the default directory is scoped per bundle id and disabled under automated tests")
    func defaultDirectory() {
        let appSupport = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)
        let url = TerminalBlueprintStore.defaultDirectory(
            bundleIdentifier: "com.cmuxterm.app.dev.my-tag",
            appSupportDirectory: appSupport,
            isRunningUnderAutomatedTests: false
        )
        #expect(url?.path == "/tmp/app-support/cmux/blueprints-com.cmuxterm.app.dev.my-tag")
        let weird = TerminalBlueprintStore.defaultDirectory(
            bundleIdentifier: "com.cmux/odd id",
            appSupportDirectory: appSupport,
            isRunningUnderAutomatedTests: false
        )
        #expect(weird?.lastPathComponent == "blueprints-com.cmux_odd_id")
        #expect(TerminalBlueprintStore.defaultDirectory(
            bundleIdentifier: "com.cmuxterm.app",
            appSupportDirectory: appSupport,
            isRunningUnderAutomatedTests: true
        ) == nil)
    }
}
