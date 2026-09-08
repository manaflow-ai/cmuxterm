import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite struct DeclarativeTerminalConfigurationModelTests {
    @Test func pickerWritesPublishImmediatelyAndReconcileWithJSON() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("declarative-terminal-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "DeclarativeTerminalConfigurationModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let catalog = SettingCatalog()
        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let policyStream = store.valuesIfPresent(for: catalog.terminal.newSurfaceWorkingDirectoryPolicy)
        var policyIterator = policyStream.makeAsyncIterator()
        let modeStream = store.values(for: catalog.terminal.shellStartupMode)
        var modeIterator = modeStream.makeAsyncIterator()
        let model = DeclarativeTerminalConfigurationModel(
            jsonStore: store,
            userDefaultsStore: UserDefaultsSettingsStore(defaults: defaults),
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )

        model.startObserving()
        await model.waitForInitialSnapshot()
        #expect(await policyIterator.next() == nil)
        #expect(await modeIterator.next() == .login)

        model.setWorkingDirectoryPolicy(.fixedPath)
        model.setShellStartupMode(.nonLogin)

        #expect(model.values.effectiveWorkingDirectoryPolicy() == .fixedPath)
        #expect(model.values.shellStartupMode == .nonLogin)
        #expect(await policyIterator.next() == .fixedPath)
        #expect(await modeIterator.next() == .nonLogin)
    }
}
