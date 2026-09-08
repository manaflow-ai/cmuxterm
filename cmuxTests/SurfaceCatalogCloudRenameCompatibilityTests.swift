import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct SurfaceCatalogCloudRenameCompatibilityTests {
    @Test("Cursorless machine updates retain genuinely new cloud workspaces")
    func cursorlessMachineUpdateRetainsPendingWorkspaces() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = SurfaceCatalogTests.FakeProvider(machine: machine)
        catalog.register(provider)

        var canonicalInfo = provider.info
        canonicalInfo.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws", name: "canonical", index: 0, focused: true),
        ]
        #expect(catalog.replaceCloudResources(
            [],
            on: machine,
            info: canonicalInfo,
            cursor: CloudVMCursor(generation: "g1", revision: 1),
            from: provider
        ))

        var pendingInfo = provider.info
        pendingInfo.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws", name: "stale", index: 0, focused: false),
            SurfaceRemoteWorkspace(id: "pending", name: "new", index: 1, focused: false),
        ]
        catalog.updateMachine(pendingInfo, from: provider)

        #expect(catalog.machines[machine]?.remoteWorkspaces?.map(\.id) == ["ws", "pending"])
        #expect(catalog.machines[machine]?.remoteWorkspaces?.last?.name == "new")
    }

    @Test("Typed cloud state applies optimistic workspace rename overlay")
    func typedCloudStateAppliesWorkspaceRenameOverlay() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = SurfaceCatalogTests.FakeProvider(machine: machine)
        catalog.register(provider)

        let snapshot: [String: Any] = [
            "cursor": ["generation": "g1", "revision": "1"],
            "workspaces": [["id": "ws", "name": "old"]],
            "screens": [],
            "panes": [],
            "tabs": [],
            "terminals": [],
            "browsers": [],
            "agents": [],
        ]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: machine))
        var info = provider.info
        info.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws", name: "old", index: 0, focused: true),
        ]
        catalog.replaceCloudState(state, resources: [], info: info)

        let token = try catalog.beginCloudWorkspaceRename(
            machine: machine,
            workspaceID: "ws",
            name: "new"
        )
        #expect(catalog.machines[machine]?.remoteWorkspaces?.first?.name == "new")

        catalog.rollbackCloudWorkspaceRename(token)
        #expect(catalog.machines[machine]?.remoteWorkspaces?.first?.name == "old")
    }
}
