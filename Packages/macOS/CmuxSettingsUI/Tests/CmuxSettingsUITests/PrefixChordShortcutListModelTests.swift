import Foundation
import Observation
import Testing
import CmuxSettings
@testable import CmuxSettingsUI

/// Behavior tests for prefix and chord persistence in ``ShortcutListModel``.
@MainActor
@Suite struct PrefixChordShortcutListModelTests {

    private func makeStore() -> (JSONConfigStore, SettingCatalog, SettingsErrorLog, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefix-chord-list-model-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return (
            JSONConfigStore(fileURL: tempDir.appendingPathComponent("cmux.json")),
            SettingCatalog(),
            SettingsErrorLog(),
            tempDir
        )
    }

    @Test func prefixIsDisabledByDefaultAndCanBePersisted() async throws {
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()

        #expect(model.prefix == .unbound)

        let leader = ShortcutStroke(key: "b", control: true)
        await model.assignPrefix(leader)
        #expect(await store.value(for: catalog.shortcuts.prefix) == StoredShortcut(first: leader))
        #expect(model.prefix == StoredShortcut(first: leader))

        await model.clearPrefix()
        #expect(await store.value(for: catalog.shortcuts.prefix) == .unbound)
        #expect(model.prefix.isUnbound)
    }

    @Test func chordAssignmentUsesConfiguredPrefix() async throws {
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        await model.assignPrefix(ShortcutStroke(key: "b", control: true))

        let recorded = StoredShortcut(
            first: ShortcutStroke(key: "x", command: true),
            second: ShortcutStroke(key: "n")
        )
        await model.assignChord(recorded, to: .newTab)

        let persisted = await store.value(for: catalog.shortcuts.bindings)
        #expect(
            persisted[ShortcutAction.newTab.rawValue] == StoredShortcut(
                first: ShortcutStroke(key: "b", control: true),
                second: ShortcutStroke(key: "n")
            )
        )
        #expect(model.chordModeActions.isEmpty)
    }

    @Test func changingPrefixRebasesPersistedChords() async throws {
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        let firstPrefix = ShortcutStroke(key: "b", control: true)
        let secondPrefix = ShortcutStroke(key: "c", control: true)
        await model.assignPrefix(firstPrefix)
        await model.assignChord(
            StoredShortcut(
                first: firstPrefix,
                second: ShortcutStroke(key: "n")
            ),
            to: .newTab
        )

        await model.assignPrefix(secondPrefix)

        #expect(
            await store.value(for: catalog.shortcuts.bindings)[ShortcutAction.newTab.rawValue]
                == StoredShortcut(first: secondPrefix, second: ShortcutStroke(key: "n"))
        )
    }

    @Test func changingPrefixRejectsCollidingPersistedChords() async throws {
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        let firstLeader = ShortcutStroke(key: "b", control: true)
        let secondLeader = ShortcutStroke(key: "g", control: true)
        let suffix = ShortcutStroke(key: "n")
        await model.assignChord(
            StoredShortcut(first: firstLeader, second: suffix),
            to: .newTab
        )
        await model.assignChord(
            StoredShortcut(first: secondLeader, second: suffix),
            to: .openSettings
        )

        await model.assignPrefix(ShortcutStroke(key: "x", control: true))

        #expect(model.prefix.isUnbound)
        #expect(model.prefixRejection == .chordConflict)
        // Unrelated bindings writes can republish the unchanged prefix. They
        // must not dismiss the rejection before the user can act on it.
        model.ingestPrefix(.unbound)
        #expect(model.prefixRejection == .chordConflict)
        let persistedPrefix = await store.value(for: catalog.shortcuts.prefix)
        #expect(persistedPrefix.isUnbound)
        let persisted = await store.value(for: catalog.shortcuts.bindings)
        #expect(
            persisted[ShortcutAction.newTab.rawValue]
                == StoredShortcut(first: firstLeader, second: suffix)
        )
        #expect(
            persisted[ShortcutAction.openSettings.rawValue]
                == StoredShortcut(first: secondLeader, second: suffix)
        )
    }

    @Test func changingPrefixChecksBuiltInFallbackForInvalidPersistedOverrides() async throws {
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let invalidCloseWindow = StoredShortcut(first: ShortcutStroke(key: "w"))
        let existingChord = StoredShortcut(
            first: ShortcutStroke(key: "b", control: true),
            second: ShortcutStroke(key: "n")
        )
        try await store.set(
            [
                ShortcutAction.closeWindow.rawValue: invalidCloseWindow,
                ShortcutAction.newTab.rawValue: existingChord,
            ],
            for: catalog.shortcuts.bindings
        )

        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()

        // closeWindow's malformed persisted value executes as its built-in
        // ⌘⌃W fallback. Rebasing the existing chord onto that leader must be
        // rejected even though the persisted candidate itself is invalid.
        await model.assignPrefix(
            ShortcutStroke(key: "w", command: true, control: true)
        )

        #expect(model.prefix.isUnbound)
        #expect(model.prefixRejection == .chordConflict)
        #expect(await store.value(for: catalog.shortcuts.prefix).isUnbound)
        #expect(await store.value(for: catalog.shortcuts.bindings)[ShortcutAction.newTab.rawValue] == existingChord)
    }

    @Test func stalePrefixObservationCannotRetargetAChordDuringRebase() async throws {
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        let oldPrefix = ShortcutStroke(key: "b", control: true)
        let newPrefix = ShortcutStroke(key: "g", control: true)
        await model.assignPrefix(oldPrefix)
        await model.assignChord(
            StoredShortcut(first: oldPrefix, second: ShortcutStroke(key: "n")),
            to: .newTab
        )

        // Hold the real persistence queue and wait for observable mutations,
        // not scheduler timing, before replaying the stale store observation.
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        model.shortcutWriteTail = Task { for await _ in gate.stream {} }
        let prefixChanges = AsyncStream<Void>.makeStream()
        defer { prefixChanges.continuation.finish() }
        withObservationTracking {
            _ = model.prefix
        } onChange: {
            prefixChanges.continuation.yield(())
        }
        let rebase = Task { await model.assignPrefix(newPrefix) }
        var prefixIterator = prefixChanges.stream.makeAsyncIterator()
        await prefixIterator.next()
        model.ingestPrefix(StoredShortcut(first: oldPrefix))
        #expect(model.prefix.first == newPrefix)

        let bindingChanges = AsyncStream<Void>.makeStream()
        defer { bindingChanges.continuation.finish() }
        withObservationTracking {
            _ = model.pendingBindings
        } onChange: {
            bindingChanges.continuation.yield(())
        }
        let assignment = Task {
            await model.assignChord(
                StoredShortcut(first: oldPrefix, second: ShortcutStroke(key: "s")),
                to: .openSettings
            )
        }
        var bindingIterator = bindingChanges.stream.makeAsyncIterator()
        await bindingIterator.next()
        gate.continuation.finish()
        await rebase.value
        await assignment.value

        let persistedPrefix = await store.value(for: catalog.shortcuts.prefix)
        let persisted = await store.value(for: catalog.shortcuts.bindings)
        #expect(persistedPrefix.first == newPrefix)
        #expect(persisted[ShortcutAction.newTab.rawValue]?.first == newPrefix)
        #expect(persisted[ShortcutAction.openSettings.rawValue]?.first == newPrefix)
        #expect(model.prefix.first == newPrefix)

        // Once the write completes, real external changes still take effect.
        model.ingestPrefix(StoredShortcut(first: oldPrefix))
        #expect(model.prefix.first == oldPrefix)
    }

    @Test func overlappingPrefixWritesLeaveTheNewestValuePersisted() async throws {
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        let initialPrefix = ShortcutStroke(key: "a", control: true)
        await model.assignPrefix(initialPrefix)
        await model.assignChord(
            StoredShortcut(
                first: initialPrefix,
                second: ShortcutStroke(key: "n")
            ),
            to: .newTab
        )

        async let first: Void = model.assignPrefix(ShortcutStroke(key: "b", control: true))
        async let second: Void = model.assignPrefix(ShortcutStroke(key: "c", control: true))
        _ = await (first, second)

        let persistedPrefix = await store.value(for: catalog.shortcuts.prefix)
        let persistedBindings = await store.value(for: catalog.shortcuts.bindings)
        let persistedChord = try #require(
            persistedBindings[ShortcutAction.newTab.rawValue]
        )
        #expect(persistedChord.first == persistedPrefix.first)
        #expect(persistedChord.second == ShortcutStroke(key: "n"))
        #expect(model.prefix.first == persistedPrefix.first)
    }

    @Test func malformedChordWithoutSuffixIsRejectedNotWritten() async throws {
        // A recorder teardown must not silently downgrade a requested chord to
        // a single-stroke binding at the persistence boundary.
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        await model.assignPrefix(ShortcutStroke(key: "b", control: true))

        await model.assignChord(
            StoredShortcut(first: ShortcutStroke(key: "x", command: true)),
            to: .newTab
        )

        let persisted = await store.value(for: catalog.shortcuts.bindings)
        #expect(persisted[ShortcutAction.newTab.rawValue] == nil)
        #expect(!model.chordModeActions.contains(ShortcutAction.newTab.rawValue))
    }

    @Test func configuredSpacePrefixAllowsChordForModifierOnlyAction() async throws {
        // Space is a valid shared leader even though ordinary app actions reject
        // bare single-stroke bindings.
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        await model.assignPrefix(ShortcutStroke(key: "space"))

        let suffix = ShortcutStroke(key: "n")
        await model.assignChord(
            StoredShortcut(
                first: ShortcutStroke(key: "ignored", command: true),
                second: suffix
            ),
            to: .newTab
        )

        let expected = StoredShortcut(first: ShortcutStroke(key: "space"), second: suffix)
        let persisted = await store.value(for: catalog.shortcuts.bindings)
        #expect(persisted[ShortcutAction.newTab.rawValue] == expected)
        #expect(ShortcutAction.newTab.shortcutBindingPolicyResult(for: expected) == .accepted)
        #expect(ShortcutAction.newTab.effectivePersistedShortcut(expected) == expected)
    }
}
