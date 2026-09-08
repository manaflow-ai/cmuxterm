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
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let catalog = SettingCatalog()
        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let policyStream = store.valuesIfPresent(for: catalog.terminal.newSurfaceWorkingDirectoryPolicy)
        var policyIterator = policyStream.makeAsyncIterator()
        let modeStream = store.values(for: catalog.terminal.shellStartupMode)
        var modeIterator = modeStream.makeAsyncIterator()
        let model = DeclarativeTerminalConfigurationModel(
            jsonStore: store,
            userDefaultsStore: makeTestUserDefaultsStore(suiteName: suiteName),
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

    @Test func fixedPathChangesFailClosedUntilInitialValidation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("declarative-terminal-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "DeclarativeTerminalConfigurationModelTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let catalog = SettingCatalog()
        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let model = DeclarativeTerminalConfigurationModel(
            jsonStore: store,
            userDefaultsStore: makeTestUserDefaultsStore(suiteName: suiteName),
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )

        model.startObserving()
        await model.waitForInitialSnapshot()

        model.setWorkingDirectoryPolicy(.fixedPath)
        model.setWorkingDirectoryPath(directory.path)

        #expect(!model.values.fixedPathIsUsable)
        await waitUntil { model.values.fixedPathIsUsable }
        #expect(model.values.fixedPathIsUsable)

        let missingPath = directory.appendingPathComponent("missing", isDirectory: true).path
        model.setWorkingDirectoryPath(missingPath)

        #expect(!model.values.fixedPathIsUsable)
        await waitUntil { model.values.expandedWorkingDirectoryPath == missingPath }
        #expect(!model.values.fixedPathIsUsable)
    }

    @Test func externalSnapshotSupersedesCompletedPendingWrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("declarative-terminal-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "DeclarativeTerminalConfigurationModelTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let catalog = SettingCatalog()
        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let model = DeclarativeTerminalConfigurationModel(
            jsonStore: store,
            userDefaultsStore: makeTestUserDefaultsStore(suiteName: suiteName),
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )

        model.startObserving()
        await model.waitForInitialSnapshot()

        let shellStartupModeKey = catalog.terminal.shellStartupMode
        let externalEdit = Task.detached {
            var iterator = store.snapshots().makeAsyncIterator()
            _ = await iterator.next()
            _ = await iterator.next()
            try? await store.set(.login, for: shellStartupModeKey)
        }

        model.setShellStartupMode(.nonLogin)
        await externalEdit.value
        await waitUntil { model.values.shellStartupMode == .login }

        #expect(model.values.shellStartupMode == .login)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
    }
}

private func makeTestUserDefaultsStore(suiteName: String) -> UserDefaultsSettingsStore {
    UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
}
