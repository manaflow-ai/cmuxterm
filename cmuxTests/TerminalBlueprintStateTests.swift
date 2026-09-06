import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class FakeBlueprintWebController: TerminalBlueprintWebControlling {
    struct SceneCall: Equatable {
        let sceneJSON: String
        let source: TerminalBlueprintDocument.Author
    }

    var sceneCalls: [SceneCall] = []
    var elementCountToReturn = 3
    var exportRequestIDs: [String] = []
    var exportResponder: ((String) -> Void)?
    var zoomToFitCalls = 0
    var clearCalls = 0
    var themes: [Bool] = []
    var sceneJSONToReturn = "{}"
    var mermaidCalls: [(source: String, mode: TerminalBlueprintState.MermaidMode)] = []
    var mermaidOutcome = TerminalBlueprintRenderOutcome(elementCount: 4, warnings: [])
    var mermaidError: (any Error)?
    var opsCalls: [[[String: Any]]] = []
    var appliedToReturn = 1

    func setScene(_ sceneJSON: String, source: TerminalBlueprintDocument.Author) async throws -> Int {
        sceneCalls.append(SceneCall(sceneJSON: sceneJSON, source: source))
        return elementCountToReturn
    }

    func currentSceneJSON() async throws -> String { sceneJSONToReturn }
    func summary() async throws -> String { "summary" }

    func requestExport(requestID: String, png: Bool, svg: Bool, mermaid: Bool, scale: Double, dark: Bool) async throws {
        exportRequestIDs.append(requestID)
        exportResponder?(requestID)
    }

    func renderMermaid(_ source: String, mode: TerminalBlueprintState.MermaidMode) async throws -> TerminalBlueprintRenderOutcome {
        mermaidCalls.append((source, mode))
        if let mermaidError { throw mermaidError }
        return mermaidOutcome
    }

    func applyOps(_ ops: [[String: Any]]) async throws -> Int {
        opsCalls.append(ops)
        return appliedToReturn
    }

    func setTheme(isDark: Bool) async { themes.append(isDark) }
    func zoomToFit() async { zoomToFitCalls += 1 }
    func clearScene() async { clearCalls += 1 }
}

private actor RecordingBlueprintStore: TerminalBlueprintPersisting {
    private(set) var saved: [TerminalBlueprintDocument] = []
    private var preloaded: [UUID: TerminalBlueprintDocument]
    private var consumed = 0
    private var waiters: [CheckedContinuation<TerminalBlueprintDocument, Never>] = []

    init(preloaded: [UUID: TerminalBlueprintDocument] = [:]) {
        self.preloaded = preloaded
    }

    func load(surfaceID: UUID) async throws -> TerminalBlueprintDocument? {
        preloaded[surfaceID]
    }

    func save(_ document: TerminalBlueprintDocument) async throws {
        saved.append(document)
        let waiting = waiters
        waiters = []
        for waiter in waiting {
            consumed += 1
            waiter.resume(returning: document)
        }
    }

    /// Returns the next save the test has not consumed yet, waiting for it if needed.
    func nextSave() async -> TerminalBlueprintDocument {
        if consumed < saved.count {
            let document = saved[consumed]
            consumed += 1
            return document
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@Suite("TerminalBlueprintState")
@MainActor
struct TerminalBlueprintStateTests {
    private let surfaceID = UUID()

    private func makeState(
        store: (any TerminalBlueprintPersisting)? = nil,
        exportTimeout: Duration = .seconds(5),
        canvasReadyTimeout: Duration = .seconds(5),
        autoOpen: Bool? = nil
    ) -> TerminalBlueprintState {
        let defaults = UserDefaults(suiteName: "TerminalBlueprintStateTests-\(UUID().uuidString)")!
        if let autoOpen {
            defaults.set(autoOpen, forKey: TerminalBlueprintFeature.autoOpenOnAgentUpdateKey)
        }
        let id = surfaceID
        return TerminalBlueprintState(
            surfaceIDProvider: { id },
            store: store,
            saveDebounce: .milliseconds(1),
            exportTimeout: exportTimeout,
            canvasReadyTimeout: canvasReadyTimeout,
            defaults: defaults
        )
    }

    @Test("toggle opens a closed drawer and closes an open one")
    func toggle() {
        let state = makeState()
        #expect(state.isOpen == false)
        #expect(state.perform(.toggle))
        #expect(state.isOpen)
        #expect(state.isExpanded)
        #expect(state.perform(.toggle))
        #expect(state.isOpen == false)
    }

    @Test("intents that do not apply report false so entrypoints can beep")
    func inapplicableIntents() {
        let state = makeState()
        #expect(state.perform(.collapse) == false)
        #expect(state.perform(.expand) == false)
        #expect(state.perform(.close) == false)
        #expect(state.perform(.restore) == false)
        #expect(state.perform(.zoomToFit) == false)
        state.open()
        #expect(state.perform(.expand) == false)
        #expect(state.perform(.restore) == false)
        #expect(state.perform(.collapse))
        #expect(state.perform(.collapse) == false)
    }

    @Test("collapse and expand remember the dragged split fraction")
    func collapseExpandRemembersFraction() {
        let state = makeState()
        state.open()
        state.setSplitFraction(0.6)
        #expect(state.layout == .split(fraction: 0.6))
        #expect(state.perform(.collapse))
        #expect(state.layout == .collapsed)
        #expect(state.isExpanded == false)
        #expect(state.isOpen)
        #expect(state.perform(.expand))
        #expect(state.layout == .split(fraction: 0.6))
    }

    @Test("enlarge and restore round-trip through the remembered split")
    func enlargeRestore() {
        let state = makeState()
        state.open()
        state.setSplitFraction(0.3)
        #expect(state.perform(.enlarge))
        #expect(state.layout == .enlarged)
        #expect(state.perform(.enlarge) == false)
        #expect(state.perform(.restore))
        #expect(state.layout == .split(fraction: 0.3))
        state.perform(.enlarge)
        state.setSplitFraction(0.5)
        #expect(state.layout == .split(fraction: 0.5))
    }

    @Test("user edits bump the revision once per digest and persist the scene")
    func sceneChangedBumpsRevisionAndSaves() async {
        let store = RecordingBlueprintStore()
        let state = makeState(store: store)
        state.open()
        state.handleBridgeMessage(.ready)
        state.handleBridgeMessage(.sceneChanged(sceneJSON: #"{"elements":[1]}"#, elementCount: 1, digest: "d1"))
        #expect(state.revision == 1)
        #expect(state.updatedBy == .user)
        #expect(state.elementCount == 1)
        state.handleBridgeMessage(.sceneChanged(sceneJSON: #"{"elements":[1]}"#, elementCount: 1, digest: "d1"))
        #expect(state.revision == 1)
        state.handleBridgeMessage(.sceneChanged(sceneJSON: #"{"elements":[1,2]}"#, elementCount: 2, digest: "d2"))
        #expect(state.revision == 2)
        let saved = await store.nextSave()
        #expect(saved.surfaceID == surfaceID)
        #expect(saved.sceneJSON == #"{"elements":[1,2]}"#)
        #expect(saved.revision == 2)
        #expect(saved.lastAuthor == .user)
    }

    @Test("a stored scene is loaded on open and replayed when the page is ready")
    func readyReplaysStoredScene() async {
        let document = TerminalBlueprintDocument(
            surfaceID: surfaceID,
            sceneJSON: #"{"elements":["stored"]}"#,
            mermaidSource: "flowchart LR",
            revision: 4,
            updatedAt: Date(),
            lastAuthor: .agent
        )
        let store = RecordingBlueprintStore(preloaded: [surfaceID: document])
        let state = makeState(store: store)
        let controller = FakeBlueprintWebController()
        state.webController = controller
        state.open()
        await state.waitForPendingWork()
        #expect(state.sceneJSON == document.sceneJSON)
        #expect(state.mermaidSource == "flowchart LR")
        #expect(state.revision == 4)
        #expect(state.updatedBy == .agent)
        state.handleBridgeMessage(.ready)
        await state.waitForPendingWork()
        #expect(state.isWebViewReady)
        #expect(controller.sceneCalls == [.init(sceneJSON: document.sceneJSON, source: .restore)])
        #expect(state.elementCount == controller.elementCountToReturn)
    }

    @Test("an agent scene auto-opens a closed drawer and reaches a live canvas")
    func agentSceneAutoOpens() async {
        let store = RecordingBlueprintStore()
        let state = makeState(store: store, autoOpen: true)
        let controller = FakeBlueprintWebController()
        controller.elementCountToReturn = 7
        state.webController = controller
        state.handleBridgeMessage(.ready)
        let revision = await state.applyScene(#"{"elements":["agent"]}"#, mermaidSource: "graph TD", author: .agent)
        #expect(revision == 1)
        #expect(state.isOpen)
        #expect(state.isExpanded)
        #expect(state.updatedBy == .agent)
        #expect(state.hasUnseenAgentUpdate == false)
        #expect(state.elementCount == 7)
        #expect(controller.sceneCalls == [.init(sceneJSON: #"{"elements":["agent"]}"#, source: .agent)])
        let saved = await store.nextSave()
        #expect(saved.lastAuthor == .agent)
        #expect(saved.mermaidSource == "graph TD")
    }

    @Test("with auto-open off, an agent scene only flags the drawer as updated")
    func agentSceneFlagsWhenAutoOpenOff() async {
        let state = makeState(autoOpen: false)
        _ = await state.applyScene(#"{"elements":[]}"#, author: .agent)
        #expect(state.isOpen == false)
        #expect(state.hasUnseenAgentUpdate)
        #expect(state.revision == 1)
        state.open()
        #expect(state.hasUnseenAgentUpdate == false)
    }

    @Test("an agent scene applied before the page is ready is replayed on ready")
    func agentSceneBeforeReadyIsReplayed() async {
        let state = makeState(autoOpen: true)
        let controller = FakeBlueprintWebController()
        state.webController = controller
        _ = await state.applyScene(#"{"elements":["early"]}"#, author: .agent)
        #expect(controller.sceneCalls.isEmpty)
        state.handleBridgeMessage(.ready)
        await state.waitForPendingWork()
        #expect(controller.sceneCalls == [.init(sceneJSON: #"{"elements":["early"]}"#, source: .restore)])
    }

    @Test("export resolves with the page's reply")
    func exportRoundTrip() async throws {
        let state = makeState()
        let controller = FakeBlueprintWebController()
        state.webController = controller
        state.handleBridgeMessage(.ready)
        controller.exportResponder = { requestID in
            state.handleBridgeMessage(.exportResult(TerminalBlueprintExportResult(
                requestID: requestID,
                pngBase64: Data([1, 2, 3]).base64EncodedString(),
                svg: nil,
                mermaid: "flowchart LR",
                sceneJSON: "{}",
                width: 10,
                height: 20
            )))
        }
        let result = try await state.requestExport()
        #expect(result.pngData == Data([1, 2, 3]))
        #expect(result.mermaid == "flowchart LR")
        #expect(controller.exportRequestIDs.count == 1)
        #expect(result.requestID == controller.exportRequestIDs[0])
    }

    @Test("export surfaces the page's failure")
    func exportFailure() async {
        let state = makeState()
        let controller = FakeBlueprintWebController()
        state.webController = controller
        state.handleBridgeMessage(.ready)
        controller.exportResponder = { requestID in
            state.handleBridgeMessage(.exportFailed(requestID: requestID, message: "canvas busy"))
        }
        await #expect(throws: TerminalBlueprintError.exportFailed("canvas busy")) {
            try await state.requestExport()
        }
    }

    @Test("export times out when the page never replies")
    func exportTimeout() async {
        let state = makeState(exportTimeout: .milliseconds(20))
        let controller = FakeBlueprintWebController()
        state.webController = controller
        state.handleBridgeMessage(.ready)
        await #expect(throws: TerminalBlueprintError.exportTimedOut) {
            try await state.requestExport()
        }
    }

    @Test("export without a live page fails immediately")
    func exportWithoutPage() async {
        let state = makeState()
        await #expect(throws: TerminalBlueprintError.webViewUnavailable) {
            try await state.requestExport()
        }
    }

    @Test("a page reset fails pending exports and replays the scene on the next ready")
    func webViewReset() async {
        let state = makeState()
        let controller = FakeBlueprintWebController()
        state.webController = controller
        state.handleBridgeMessage(.ready)
        state.handleBridgeMessage(.sceneChanged(sceneJSON: #"{"elements":["u"]}"#, elementCount: 1, digest: "x"))
        state.webViewDidReset()
        #expect(state.isWebViewReady == false)
        state.handleBridgeMessage(.ready)
        await state.waitForPendingWork()
        #expect(controller.sceneCalls == [.init(sceneJSON: #"{"elements":["u"]}"#, source: .restore)])
    }

    @Test("clear empties the scene, bumps the revision, and tells the page")
    func clear() async {
        let state = makeState()
        let controller = FakeBlueprintWebController()
        state.webController = controller
        state.open()
        state.handleBridgeMessage(.ready)
        state.handleBridgeMessage(.sceneChanged(sceneJSON: #"{"elements":["u"]}"#, elementCount: 1, digest: "x"))
        #expect(state.perform(.clear))
        #expect(state.revision == 2)
        #expect(state.elementCount == 0)
        #expect(state.sceneJSON == TerminalBlueprintState.emptySceneJSON)
        await state.waitForPendingWork()
        #expect(controller.clearCalls == 1)
    }

    @Test("escape from the page asks the terminal for focus")
    func requestTerminalFocus() {
        let state = makeState()
        var calls = 0
        state.onRequestTerminalFocus = { calls += 1 }
        state.handleBridgeMessage(.requestTerminalFocus)
        #expect(calls == 1)
    }

    @Test("session snapshots capture and restore drawer state")
    func sessionSnapshot() {
        let state = makeState()
        #expect(state.sessionSnapshot() == nil)
        state.open()
        state.setSplitFraction(0.7)
        state.handleBridgeMessage(.sceneChanged(sceneJSON: "{}", elementCount: 0, digest: "a"))
        let snapshot = state.sessionSnapshot()
        #expect(snapshot == SessionTerminalBlueprintSnapshot(isOpen: true, layout: .split(fraction: 0.7), revision: 1))

        let restored = makeState()
        restored.restore(from: snapshot)
        #expect(restored.isOpen)
        #expect(restored.layout == .split(fraction: 0.7))
        #expect(restored.revision == 1)
        restored.perform(.collapse)
        restored.perform(.expand)
        #expect(restored.layout == .split(fraction: 0.7))

        let untouched = makeState()
        untouched.restore(from: nil)
        #expect(untouched.isOpen == false)
    }

    // MARK: - Agent mutations (phase 2)

    private let sceneWithOneBox = #"{"type":"excalidraw","version":2,"elements":[{"id":"box00001","type":"rectangle","x":0,"y":0,"width":100,"height":40}],"appState":{},"files":{}}"#

    @Test("set with a stale base revision fails with conflict and leaves the scene alone")
    func setSceneConflict() async {
        let state = makeState()
        state.handleBridgeMessage(.sceneChanged(sceneJSON: "{}", elementCount: 0, digest: "u1"))
        #expect(state.revision == 1)

        await #expect(throws: TerminalBlueprintError.conflict(currentRevision: 1, updatedBy: .user)) {
            try await state.setScene(sceneWithOneBox, baseRevision: 0, author: .agent)
        }
        #expect(state.revision == 1)
        #expect(state.sceneJSON == "{}")

        let revision = try? await state.setScene(sceneWithOneBox, baseRevision: 1, author: .agent)
        #expect(revision == 2)
        #expect(state.elementCount == 1)
        #expect(state.updatedBy == .agent)
    }

    @Test("set validates the scene before touching state")
    func setSceneValidation() async {
        let state = makeState()
        await #expect(throws: TerminalBlueprintError.invalidScene("scene needs an `elements` or `skeleton` array")) {
            try await state.setScene(#"{"appState":{}}"#, baseRevision: nil, author: .agent)
        }
        #expect(state.revision == 0)
    }

    @Test("set clears the remembered Mermaid source like the canvas does")
    func setSceneClearsMermaid() async {
        let state = makeState()
        _ = await state.applyScene("{}", mermaidSource: "graph TD", author: .agent)
        #expect(state.mermaidSource == "graph TD")
        _ = try? await state.setScene(sceneWithOneBox, baseRevision: nil, author: .agent)
        #expect(state.mermaidSource == nil)
    }

    @Test("mutations report changes through the hook, and drawer verbs report visibility")
    func hooks() async {
        let state = makeState()
        var changes: [TerminalBlueprintChange] = []
        var visibility: [TerminalBlueprintVisibility] = []
        state.onChange = { changes.append($0) }
        state.onVisibilityChange = { visibility.append($0) }

        state.handleBridgeMessage(.sceneChanged(sceneJSON: "{}", elementCount: 2, digest: "u1"))
        _ = try? await state.setScene(sceneWithOneBox, baseRevision: 1, author: .agent, autoOpen: false)
        state.perform(.open)
        state.perform(.collapse)

        #expect(changes.map(\.revision) == [1, 2])
        #expect(changes.map(\.updatedBy) == [.user, .agent])
        #expect(changes.last?.elementCount == 1)
        #expect(changes.allSatisfy { $0.surfaceID == surfaceID })
        #expect(visibility.map(\.isOpen) == [true, true])
        #expect(visibility.map(\.isCollapsed) == [false, true])
    }

    @Test("render mermaid asks for the canvas, waits for ready, then renders and persists")
    func renderMermaid() async throws {
        let store = RecordingBlueprintStore()
        let state = makeState(store: store, autoOpen: true)
        let web = FakeBlueprintWebController()
        web.sceneJSONToReturn = sceneWithOneBox
        web.mermaidOutcome = TerminalBlueprintRenderOutcome(elementCount: 1, warnings: ["w"])
        var canvasRequests = 0
        state.onCanvasRequested = {
            canvasRequests += 1
            // The panel creates the page; it reports ready a moment later.
            state.webController = web
            Task { @MainActor in state.handleBridgeMessage(.ready) }
        }

        let result = try await state.renderMermaid("flowchart LR; A-->B", mode: .replace, baseRevision: 0)

        #expect(canvasRequests == 1)
        #expect(state.isOpen)
        #expect(web.mermaidCalls.count == 1)
        #expect(web.mermaidCalls.first?.mode == .replace)
        #expect(result.revision == 1)
        #expect(result.outcome.warnings == ["w"])
        #expect(state.sceneJSON == sceneWithOneBox)
        #expect(state.elementCount == 1)
        #expect(state.mermaidSource == "flowchart LR; A-->B")
        #expect(state.updatedBy == .agent)
        let saved = await store.nextSave()
        #expect(saved.mermaidSource == "flowchart LR; A-->B")
        #expect(saved.revision == 1)

        _ = try await state.renderMermaid("sequenceDiagram", mode: .append, baseRevision: 1)
        #expect(state.mermaidSource == "flowchart LR; A-->B\n\nsequenceDiagram")
        #expect(state.revision == 2)
    }

    @Test("render mermaid fails with canvasNotReady when no page ever reports ready")
    func renderMermaidTimesOut() async {
        let state = makeState(canvasReadyTimeout: .milliseconds(20), autoOpen: false)
        state.onCanvasRequested = {}
        await #expect(throws: TerminalBlueprintError.canvasNotReady) {
            try await state.renderMermaid("flowchart LR; A-->B", mode: .replace, baseRevision: nil)
        }
        #expect(state.revision == 0)
        #expect(state.isOpen == false)
    }

    @Test("apply ops uses the Swift fallback without a page and the page when it is live")
    func applyOps() async throws {
        let state = makeState(autoOpen: false)
        _ = try await state.setScene(sceneWithOneBox, baseRevision: nil, author: .agent)

        let fallback = try await state.applyOps(
            [["op": "upsert", "element": ["id": "note0001", "type": "text", "x": 0, "y": 100, "width": 10, "height": 10, "text": "hi"]]],
            baseRevision: 1
        )
        #expect(fallback.applied == 1)
        #expect(fallback.revision == 2)
        #expect(state.elementCount == 2)
        #expect(state.hasUnseenAgentUpdate)

        let web = FakeBlueprintWebController()
        web.sceneJSONToReturn = TerminalBlueprintState.emptySceneJSON
        web.appliedToReturn = 1
        state.webController = web
        state.handleBridgeMessage(.ready)
        await state.waitForPendingWork()

        let live = try await state.applyOps([["op": "clear"]], baseRevision: 2)
        #expect(live.applied == 1)
        #expect(live.revision == 3)
        #expect(web.opsCalls.count == 1)
        #expect(state.elementCount == 0)
        #expect(state.mermaidSource == nil)

        await #expect(throws: TerminalBlueprintError.invalidOps("op 0: unknown op move")) {
            try await state.applyOps([["op": "move"]], baseRevision: 3)
        }
    }

    @Test("the send-to-terminal intent runs the panel hook")
    func sendToTerminalIntent() {
        let state = makeState()
        #expect(state.perform(.sendToTerminal) == false)
        var sends = 0
        state.onSendToTerminal = { sends += 1 }
        #expect(state.perform(.sendToTerminal))
        #expect(sends == 1)
    }

    @Test("summary is computed from the stored scene without a page")
    func summaryWithoutPage() async throws {
        let state = makeState()
        #expect(state.summaryText == "(empty blueprint)")
        _ = try await state.setScene(sceneWithOneBox, baseRevision: nil, author: .agent, autoOpen: false)
        #expect(state.summaryText == "#box00001 rectangle \"\" (0,0 100x40)")
    }

    @Test("a restore that ran before the stable surface id was adopted still finds the stored scene")
    func loadRetriesAfterSurfaceIDChanges() async {
        // Session restore calls restore(from:) before the panel adopts its
        // persisted stable id, so the first load looks under a throwaway id.
        let persistedID = UUID()
        let store = RecordingBlueprintStore(preloaded: [persistedID: TerminalBlueprintDocument(
            surfaceID: persistedID,
            sceneJSON: sceneWithOneBox,
            mermaidSource: "flowchart LR",
            revision: 4,
            updatedAt: Date(),
            lastAuthor: .agent
        )])
        let defaults = UserDefaults(suiteName: "TerminalBlueprintStateTests-\(UUID().uuidString)")!
        var currentID = UUID()
        let state = TerminalBlueprintState(
            surfaceIDProvider: { currentID },
            store: store,
            saveDebounce: .milliseconds(1),
            defaults: defaults
        )
        state.restore(from: SessionTerminalBlueprintSnapshot(isOpen: true, layout: .split(fraction: 0.4), revision: 4))
        await state.waitForPendingWork()
        #expect(state.sceneJSON == nil)

        currentID = persistedID
        state.loadDocumentIfNeeded()
        await state.waitForPendingWork()

        #expect(state.sceneJSON == sceneWithOneBox)
        #expect(state.elementCount == 1)
        #expect(state.mermaidSource == "flowchart LR")
        #expect(state.revision == 4)
        #expect(state.summaryText.contains("#box00001"))
    }
}
