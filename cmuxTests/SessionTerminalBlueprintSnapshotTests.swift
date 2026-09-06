import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("SessionTerminalBlueprintSnapshot")
struct SessionTerminalBlueprintSnapshotTests {
    @Test("legacy terminal snapshots without a blueprint still decode")
    func legacyDecode() throws {
        let json = #"{"workingDirectory":"/tmp","wasAgentRunning":false}"#
        let snapshot = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.workingDirectory == "/tmp")
        #expect(snapshot.blueprint == nil)
    }

    @Test("blueprint drawer state round-trips inside the terminal snapshot")
    func roundTrip() throws {
        let original = SessionTerminalPanelSnapshot(
            workingDirectory: "/repo",
            blueprint: SessionTerminalBlueprintSnapshot(isOpen: true, layout: .split(fraction: 0.55), revision: 12)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: data)
        #expect(decoded.blueprint == original.blueprint)
        #expect(decoded.blueprint?.layout == .split(fraction: 0.55))
        #expect(decoded.blueprint?.revision == 12)
    }
}
