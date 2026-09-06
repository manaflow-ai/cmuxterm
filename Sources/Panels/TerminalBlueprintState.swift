import Foundation
import Observation
import OSLog

/// The WebKit-facing half of a blueprint: what Swift can ask the canvas page to do.
///
/// Implemented by the web renderer coordinator. Kept behind a protocol so
/// `TerminalBlueprintState` stays testable without WebKit.
@MainActor
protocol TerminalBlueprintWebControlling: AnyObject {
    /// Replaces the canvas scene and returns the live element count.
    func setScene(_ sceneJSON: String, source: TerminalBlueprintDocument.Author) async throws -> Int
    func currentSceneJSON() async throws -> String
    func summary() async throws -> String
    func requestExport(
        requestID: String,
        png: Bool,
        svg: Bool,
        mermaid: Bool,
        scale: Double,
        dark: Bool
    ) async throws
    /// Renders Mermaid source into the canvas (replace or append) and returns
    /// the live element count plus any warnings the converter raised.
    func renderMermaid(_ source: String, mode: TerminalBlueprintState.MermaidMode) async throws -> TerminalBlueprintRenderOutcome
    /// Applies targeted `upsert`/`delete`/`clear` operations; returns how many applied.
    func applyOps(_ ops: [[String: Any]]) async throws -> Int
    func setTheme(isDark: Bool) async
    func zoomToFit() async
    func clearScene() async
}

/// What the canvas reported after rendering Mermaid.
struct TerminalBlueprintRenderOutcome: Equatable, Sendable {
    var elementCount: Int
    var warnings: [String]
}

/// One accepted mutation, for event publication and UI badges.
struct TerminalBlueprintChange: Equatable, Sendable {
    var surfaceID: UUID
    var revision: Int
    var updatedBy: TerminalBlueprintDocument.Author
    var elementCount: Int
}

/// The drawer's visibility, for event publication.
struct TerminalBlueprintVisibility: Equatable, Sendable {
    var surfaceID: UUID
    var isOpen: Bool
    var isCollapsed: Bool
}

/// Persistence seam for blueprint documents; `TerminalBlueprintStore` is the
/// production implementation.
protocol TerminalBlueprintPersisting: Sendable {
    func load(surfaceID: UUID) async throws -> TerminalBlueprintDocument?
    func save(_ document: TerminalBlueprintDocument) async throws
}

enum TerminalBlueprintError: Error, Equatable, LocalizedError {
    var errorDescription: String? { TerminalBlueprintErrorText.describe(self) }

    case webViewUnavailable
    case exportTimedOut
    case exportFailed(String)
    /// The canvas page did not become ready in time (the pane may be hidden or the page failed to load).
    case canvasNotReady
    /// The caller's `base_revision` is stale: someone else changed the canvas since.
    case conflict(currentRevision: Int, updatedBy: TerminalBlueprintDocument.Author)
    case invalidScene(String)
    case invalidMermaid(String)
    case invalidOps(String)
    case renderFailed(String)
}

/// User-facing text for blueprint failures (drawer banner, CLI, MCP).
enum TerminalBlueprintErrorText {
    static func describe(_ error: any Error) -> String {
        guard let blueprintError = error as? TerminalBlueprintError else {
            return error.localizedDescription
        }
        switch blueprintError {
        case .webViewUnavailable, .canvasNotReady:
            return String(localized: "blueprint.error.canvasNotReady", defaultValue: "The blueprint canvas is not ready yet.")
        case .exportTimedOut:
            return String(localized: "blueprint.error.exportTimedOut", defaultValue: "Exporting the blueprint timed out.")
        case .exportFailed(let message):
            return String(localized: "blueprint.error.exportFailed", defaultValue: "Exporting the blueprint failed: \(message)")
        case .conflict(let revision, _):
            return String(localized: "blueprint.error.conflict", defaultValue: "The canvas changed since revision \(revision).")
        case .invalidScene(let message), .invalidMermaid(let message), .invalidOps(let message), .renderFailed(let message):
            return message
        }
    }
}

/// Single source of truth for one terminal's blueprint drawer.
///
/// Every entrypoint (drawer buttons, shortcut, palette, tab bar, menu, socket)
/// mutates the drawer through `perform(_:)` or the agent scene methods here.
/// The web page is stateless about revisions: this model owns `revision`,
/// bumps it on every accepted mutation, and persists the scene through the
/// injected store with a debounced write.
@MainActor
@Observable
final class TerminalBlueprintState {
    enum Intent: Equatable, Sendable {
        case toggle
        case open
        case close
        case collapse
        case expand
        case enlarge
        case restore
        case zoomToFit
        case clear
        /// Pushes the canvas (PNG path, Mermaid or summary) into the terminal's prompt.
        case sendToTerminal
    }

    enum MermaidMode: String, Sendable {
        case replace
        case append
    }

    private(set) var isOpen = false
    private(set) var layout: TerminalBlueprintLayout = .split(fraction: TerminalBlueprintLayout.defaultSplitFraction)
    private(set) var revision = 0
    private(set) var updatedBy: TerminalBlueprintDocument.Author = .user
    private(set) var hasUnseenAgentUpdate = false
    private(set) var isWebViewReady = false
    private(set) var sceneJSON: String?
    private(set) var mermaidSource: String?
    private(set) var elementCount = 0
    private(set) var lastAppliedDigest: String?
    private(set) var errorMessage: String?

    /// The canvas page controller. Set by the web renderer while it is mounted.
    @ObservationIgnored weak var webController: (any TerminalBlueprintWebControlling)?
    /// Called when the page asks for the terminal to take keyboard focus (Escape).
    @ObservationIgnored var onRequestTerminalFocus: (@MainActor () -> Void)?
    /// Resolves the stable surface id used as the document key. Set by the owning panel.
    @ObservationIgnored var surfaceIDProvider: @MainActor () -> UUID
    /// Asked to make the canvas page exist and load, even while the drawer is
    /// closed or its pane is off screen. The owning panel creates the web view
    /// offscreen; agents can then draw into any terminal. Set by the panel.
    @ObservationIgnored var onCanvasRequested: (@MainActor () -> Void)?
    /// Runs the `sendToTerminal` intent; the owning panel wires it because the
    /// send needs both the canvas export and the terminal input path.
    @ObservationIgnored var onSendToTerminal: (@MainActor () -> Void)?
    /// Called after every accepted mutation, whoever authored it (socket events).
    @ObservationIgnored var onChange: (@MainActor (TerminalBlueprintChange) -> Void)?
    /// Called whenever the drawer opens, closes, collapses, or expands (socket events).
    @ObservationIgnored var onVisibilityChange: (@MainActor (TerminalBlueprintVisibility) -> Void)?
    /// Called after the canvas was pasted into the terminal, with the formats sent.
    @ObservationIgnored var onSentToTerminal: (@MainActor ([String]) -> Void)?

    @ObservationIgnored private let store: (any TerminalBlueprintPersisting)?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let saveDebounce: Duration
    @ObservationIgnored private let exportTimeout: Duration
    @ObservationIgnored private let canvasReadyTimeout: Duration
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var didLoadDocument = false
    @ObservationIgnored private var lastSplitFraction = TerminalBlueprintLayout.defaultSplitFraction
    @ObservationIgnored private var pendingExports: [String: CheckedContinuation<TerminalBlueprintExportResult, any Error>] = [:]
    @ObservationIgnored private var exportTimeoutTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var readyWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    @ObservationIgnored private var readyTimeoutTasks: [UUID: Task<Void, Never>] = [:]

    init(
        surfaceIDProvider: @escaping @MainActor () -> UUID = { UUID() },
        store: (any TerminalBlueprintPersisting)?,
        clock: any Clock<Duration> = ContinuousClock(),
        saveDebounce: Duration = .milliseconds(750),
        exportTimeout: Duration = .seconds(15),
        canvasReadyTimeout: Duration = .seconds(30),
        defaults: UserDefaults = .standard
    ) {
        self.surfaceIDProvider = surfaceIDProvider
        self.store = store
        self.clock = clock
        self.saveDebounce = saveDebounce
        self.exportTimeout = exportTimeout
        self.canvasReadyTimeout = canvasReadyTimeout
        self.defaults = defaults
    }

    // MARK: - Derived state

    /// True when the drawer is open and showing the canvas (not just the header).
    var isExpanded: Bool {
        isOpen && !layout.isCollapsed
    }

    var surfaceID: UUID {
        surfaceIDProvider()
    }

    // MARK: - Shared action path

    /// The one mutation path behind every drawer entrypoint.
    ///
    /// - Returns: `false` when the intent did not apply (for example
    ///   collapsing a closed drawer), so callers can beep or report it.
    @discardableResult
    func perform(_ intent: Intent) -> Bool {
        switch intent {
        case .toggle:
            if isOpen { close() } else { open() }
            return true
        case .open:
            open()
            return true
        case .close:
            guard isOpen else { return false }
            close()
            return true
        case .collapse:
            guard isOpen, !layout.isCollapsed else { return false }
            collapse()
            return true
        case .expand:
            guard isOpen, layout.isCollapsed else { return false }
            expand()
            return true
        case .enlarge:
            guard isOpen, !layout.isEnlarged else { return false }
            enlarge()
            return true
        case .restore:
            guard isOpen, layout.isEnlarged else { return false }
            restoreSplit()
            return true
        case .zoomToFit:
            guard isExpanded, let webController else { return false }
            pushTask = Task { await webController.zoomToFit() }
            return true
        case .clear:
            guard isOpen else { return false }
            clearScene()
            return true
        case .sendToTerminal:
            guard let onSendToTerminal else { return false }
            onSendToTerminal()
            return true
        }
    }

    func open() {
        isOpen = true
        if layout.isCollapsed {
            layout = .split(fraction: lastSplitFraction)
        }
        hasUnseenAgentUpdate = false
        loadDocumentIfNeeded()
        notifyVisibility()
    }

    func close() {
        isOpen = false
        notifyVisibility()
    }

    func collapse() {
        rememberSplitFraction()
        layout = .collapsed
        notifyVisibility()
    }

    func expand() {
        layout = .split(fraction: lastSplitFraction)
        hasUnseenAgentUpdate = false
        notifyVisibility()
    }

    private func notifyVisibility() {
        onVisibilityChange?(TerminalBlueprintVisibility(
            surfaceID: surfaceID,
            isOpen: isOpen,
            isCollapsed: layout.isCollapsed
        ))
    }

    private func notifyChange() {
        onChange?(TerminalBlueprintChange(
            surfaceID: surfaceID,
            revision: revision,
            updatedBy: updatedBy,
            elementCount: elementCount
        ))
    }

    func enlarge() {
        rememberSplitFraction()
        layout = .enlarged
    }

    func restoreSplit() {
        layout = .split(fraction: lastSplitFraction)
    }

    /// Applies a drag-resize. Enlarged drawers become a plain split.
    func setSplitFraction(_ fraction: Double) {
        let clamped = TerminalBlueprintLayout.clampedFraction(fraction)
        lastSplitFraction = clamped
        layout = .split(fraction: clamped)
    }

    private func rememberSplitFraction() {
        if case .split(let fraction) = layout {
            lastSplitFraction = TerminalBlueprintLayout.clampedFraction(fraction)
        }
    }

    // MARK: - Bridge

    func handleBridgeMessage(_ message: TerminalBlueprintBridgeMessage) {
        switch message {
        case .ready:
            isWebViewReady = true
            errorMessage = nil
            loadDocumentIfNeeded()
            pushSceneToWebViewIfNeeded()
            resolveReadyWaiters(with: .success(()))
        case .sceneChanged(let sceneJSON, let elementCount, let digest):
            guard digest.isEmpty || digest != lastAppliedDigest else { return }
            self.sceneJSON = sceneJSON
            self.elementCount = elementCount
            lastAppliedDigest = digest
            revision += 1
            updatedBy = .user
            scheduleSave(author: .user)
            notifyChange()
        case .exportResult(let result):
            resolveExport(requestID: result.requestID, with: .success(result))
        case .exportFailed(let requestID, let message):
            resolveExport(requestID: requestID, with: .failure(TerminalBlueprintError.exportFailed(message)))
        case .requestTerminalFocus:
            onRequestTerminalFocus?()
        case .error(let message):
            errorMessage = message
        }
    }

    /// Surfaces a failure in the drawer's banner (send, export, or agent errors).
    func reportError(_ message: String) {
        errorMessage = message
    }

    func didSendToTerminal(formats: [String]) {
        onSentToTerminal?(formats)
    }

    /// The web renderer calls this when its page goes away (teardown or crash)
    /// so the next `ready` replays the scene.
    func webViewDidReset() {
        isWebViewReady = false
        lastAppliedDigest = nil
        for requestID in Array(pendingExports.keys) {
            resolveExport(requestID: requestID, with: .failure(TerminalBlueprintError.webViewUnavailable))
        }
    }

    private func pushSceneToWebViewIfNeeded() {
        guard isWebViewReady, let sceneJSON, let webController else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            guard let self else { return }
            do {
                let count = try await webController.setScene(sceneJSON, source: .restore)
                guard !Task.isCancelled else { return }
                self.elementCount = count
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Awaits any in-flight document load or scene replay. Used by tests and
    /// by callers that need the canvas to reflect the stored scene.
    func waitForPendingWork() async {
        await loadTask?.value
        await pushTask?.value
    }

    // MARK: - Agent / socket path

    /// Replaces the scene on behalf of an agent, CLI, or restore.
    ///
    /// Bumps the revision, persists, and pushes to the canvas when it is live;
    /// otherwise the scene is applied when the page reports `ready`.
    /// - Returns: The new revision.
    @discardableResult
    func applyScene(
        _ sceneJSON: String,
        mermaidSource: String? = nil,
        replacesMermaidSource: Bool = false,
        author: TerminalBlueprintDocument.Author,
        autoOpen: Bool? = nil
    ) async -> Int {
        self.sceneJSON = sceneJSON
        if let mermaidSource {
            self.mermaidSource = mermaidSource
        } else if replacesMermaidSource {
            self.mermaidSource = nil
        }
        revision += 1
        updatedBy = author
        didLoadDocument = true
        elementCount = TerminalBlueprintScene.liveElementCount(inSceneJSON: sceneJSON)
        if author == .agent {
            revealForAgentUpdate(autoOpen: autoOpen)
        }
        if isWebViewReady, let webController {
            do {
                elementCount = try await webController.setScene(sceneJSON, source: author)
                lastAppliedDigest = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        scheduleSave(author: author)
        notifyChange()
        return revision
    }

    /// Opens (or badges) the drawer after an agent-authored change, per the
    /// `blueprint.autoOpenOnAgentUpdate` setting or the caller's override.
    private func revealForAgentUpdate(autoOpen: Bool?) {
        let shouldOpen = autoOpen ?? TerminalBlueprintFeature.autoOpensOnAgentUpdate(defaults: defaults)
        if shouldOpen {
            if !isOpen { open() }
            if layout.isCollapsed { expand() }
        } else if !isExpanded {
            hasUnseenAgentUpdate = true
        }
    }

    // MARK: - Agent mutations with revision checks

    /// Throws `conflict` when the caller's `baseRevision` is stale.
    func checkBaseRevision(_ baseRevision: Int?) throws {
        guard let baseRevision, baseRevision != revision else { return }
        throw TerminalBlueprintError.conflict(currentRevision: revision, updatedBy: updatedBy)
    }

    /// The compact text summary of the stored scene. Computed in Swift so it
    /// works while the canvas page is not live.
    var summaryText: String {
        TerminalBlueprintScene.summary(ofSceneJSON: sceneJSON ?? Self.emptySceneJSON)
    }

    /// Replaces the scene for an agent or the CLI, after validating limits and
    /// the caller's base revision. Clears the remembered Mermaid source, like
    /// the canvas does for a non-restore `setScene`.
    @discardableResult
    func setScene(
        _ sceneJSON: String,
        baseRevision: Int?,
        author: TerminalBlueprintDocument.Author,
        autoOpen: Bool? = nil
    ) async throws -> Int {
        loadDocumentIfNeeded()
        await loadTask?.value
        try checkBaseRevision(baseRevision)
        do {
            try TerminalBlueprintScene.validateScene(sceneJSON)
        } catch {
            throw TerminalBlueprintError.invalidScene(Self.describe(error))
        }
        return await applyScene(sceneJSON, replacesMermaidSource: true, author: author, autoOpen: autoOpen)
    }

    /// Renders Mermaid into the canvas. Needs the canvas page, so the drawer is
    /// opened (or the page created offscreen) and awaited first.
    func renderMermaid(
        _ source: String,
        mode: MermaidMode,
        baseRevision: Int?,
        author: TerminalBlueprintDocument.Author = .agent,
        autoOpen: Bool? = nil
    ) async throws -> (revision: Int, outcome: TerminalBlueprintRenderOutcome) {
        loadDocumentIfNeeded()
        await loadTask?.value
        try checkBaseRevision(baseRevision)
        do {
            try TerminalBlueprintScene.validateMermaid(source)
        } catch {
            throw TerminalBlueprintError.invalidMermaid(Self.describe(error))
        }
        try await ensureCanvasReady(reveal: author == .agent, autoOpen: autoOpen)
        guard let webController else { throw TerminalBlueprintError.canvasNotReady }
        let outcome: TerminalBlueprintRenderOutcome
        let renderedScene: String
        do {
            outcome = try await webController.renderMermaid(source, mode: mode)
            renderedScene = try await webController.currentSceneJSON()
        } catch {
            Self.logger.error("renderMermaid failed: \(String(describing: error), privacy: .public)")
            if let blueprintError = error as? TerminalBlueprintError { throw blueprintError }
            throw TerminalBlueprintError.renderFailed(Self.describeUnderlying(error))
        }
        sceneJSON = renderedScene
        elementCount = outcome.elementCount
        lastAppliedDigest = nil
        switch mode {
        case .replace:
            mermaidSource = source
        case .append:
            mermaidSource = mermaidSource.map { "\($0)\n\n\(source)" } ?? source
        }
        didLoadDocument = true
        revision += 1
        updatedBy = author
        scheduleSave(author: author)
        notifyChange()
        return (revision, outcome)
    }

    /// Applies targeted operations. Uses the canvas page when it is live (so
    /// Excalidraw normalizes the elements) and the Swift fallback otherwise.
    func applyOps(
        _ ops: [[String: Any]],
        baseRevision: Int?,
        author: TerminalBlueprintDocument.Author = .agent,
        autoOpen: Bool? = nil
    ) async throws -> (revision: Int, applied: Int) {
        loadDocumentIfNeeded()
        await loadTask?.value
        try checkBaseRevision(baseRevision)
        do {
            try TerminalBlueprintScene.validateOps(ops)
        } catch {
            throw TerminalBlueprintError.invalidOps(Self.describe(error))
        }
        await pushTask?.value
        let applied: Int
        if isWebViewReady, let webController {
            do {
                applied = try await webController.applyOps(ops)
                sceneJSON = try await webController.currentSceneJSON()
            } catch {
                Self.logger.error("applyOps failed: \(String(describing: error), privacy: .public)")
                if let blueprintError = error as? TerminalBlueprintError { throw blueprintError }
                throw TerminalBlueprintError.renderFailed(Self.describeUnderlying(error))
            }
            elementCount = TerminalBlueprintScene.liveElementCount(inSceneJSON: sceneJSON ?? Self.emptySceneJSON)
            lastAppliedDigest = nil
        } else {
            let result: (sceneJSON: String, applied: Int)
            do {
                result = try TerminalBlueprintScene.applyingOps(ops, toSceneJSON: sceneJSON ?? Self.emptySceneJSON)
            } catch {
                throw TerminalBlueprintError.invalidOps(Self.describe(error))
            }
            sceneJSON = result.sceneJSON
            applied = result.applied
            elementCount = TerminalBlueprintScene.liveElementCount(inSceneJSON: result.sceneJSON)
        }
        if ops.contains(where: { ($0["op"] as? String) == "clear" }) {
            mermaidSource = nil
        }
        didLoadDocument = true
        revision += 1
        updatedBy = author
        if author == .agent {
            revealForAgentUpdate(autoOpen: autoOpen)
        }
        scheduleSave(author: author)
        notifyChange()
        return (revision, applied)
    }

    /// Makes sure the canvas page is live: with `reveal`, opens the drawer
    /// when the agent update policy allows; otherwise asks the panel for an
    /// offscreen page. Then waits (bounded) for the page's `ready`.
    func ensureCanvasReady(
        reveal: Bool = false,
        autoOpen: Bool? = nil
    ) async throws {
        if reveal {
            revealForAgentUpdate(autoOpen: autoOpen)
        }
        loadDocumentIfNeeded()
        await loadTask?.value
        if !isWebViewReady {
            onCanvasRequested?()
            try await waitForCanvasReady()
        }
        await pushTask?.value
        guard isWebViewReady, webController != nil else { throw TerminalBlueprintError.canvasNotReady }
    }

    private func waitForCanvasReady() async throws {
        guard !isWebViewReady else { return }
        let waiterID = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            readyWaiters[waiterID] = continuation
            readyTimeoutTasks[waiterID] = Task { [weak self, clock, canvasReadyTimeout] in
                // Bounded wait for the page; cancelled when `ready` arrives.
                try? await clock.sleep(for: canvasReadyTimeout)
                guard !Task.isCancelled else { return }
                self?.resolveReadyWaiter(waiterID, with: .failure(TerminalBlueprintError.canvasNotReady))
            }
        }
    }

    private func resolveReadyWaiters(with result: Result<Void, any Error>) {
        for waiterID in Array(readyWaiters.keys) {
            resolveReadyWaiter(waiterID, with: result)
        }
    }

    private func resolveReadyWaiter(_ waiterID: UUID, with result: Result<Void, any Error>) {
        readyTimeoutTasks.removeValue(forKey: waiterID)?.cancel()
        guard let continuation = readyWaiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(with: result)
    }

    private static func describe(_ error: any Error) -> String {
        if let validation = error as? TerminalBlueprintScene.ValidationError {
            switch validation {
            case .notAnObject: return "scene must be a JSON object"
            case .missingElements: return "scene needs an `elements` or `skeleton` array"
            case .sceneTooLarge(let bytes): return "scene is \(bytes) bytes; the limit is \(TerminalBlueprintScene.maxSceneBytes)"
            case .tooManyElements(let count): return "scene has \(count) elements; the limit is \(TerminalBlueprintScene.maxElements)"
            case .mermaidTooLarge(let bytes): return "Mermaid source is \(bytes) bytes; the limit is \(TerminalBlueprintScene.maxMermaidBytes)"
            case .tooManyOps(let count): return "\(count) ops; the limit is \(TerminalBlueprintScene.maxOps)"
            case .invalidOp(let index, let reason): return "op \(index): \(reason)"
            }
        }
        return error.localizedDescription
    }

    func clearScene() {
        sceneJSON = Self.emptySceneJSON
        mermaidSource = nil
        elementCount = 0
        revision += 1
        updatedBy = .user
        if isWebViewReady, let webController {
            pushTask = Task { await webController.clearScene() }
        }
        scheduleSave(author: .user)
        notifyChange()
    }

    /// Asks the live canvas for an export and waits for the page's reply.
    func requestExport(
        png: Bool = true,
        svg: Bool = false,
        mermaid: Bool = true,
        scale: Double = 2,
        dark: Bool = false
    ) async throws -> TerminalBlueprintExportResult {
        guard isWebViewReady, let webController else {
            throw TerminalBlueprintError.webViewUnavailable
        }
        let requestID = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingExports[requestID] = continuation
                exportTimeoutTasks[requestID] = Task { [weak self, clock, exportTimeout] in
                    // Bounded deadline for the page's reply; cancelled when the reply arrives.
                    try? await clock.sleep(for: exportTimeout)
                    guard !Task.isCancelled else { return }
                    self?.resolveExport(requestID: requestID, with: .failure(TerminalBlueprintError.exportTimedOut))
                }
                Task { [weak self] in
                    do {
                        try await webController.requestExport(
                            requestID: requestID,
                            png: png,
                            svg: svg,
                            mermaid: mermaid,
                            scale: scale,
                            dark: dark
                        )
                    } catch {
                        self?.resolveExport(requestID: requestID, with: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveExport(requestID: requestID, with: .failure(CancellationError()))
            }
        }
    }

    private func resolveExport(
        requestID: String,
        with result: Result<TerminalBlueprintExportResult, any Error>
    ) {
        exportTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        guard let continuation = pendingExports.removeValue(forKey: requestID) else { return }
        continuation.resume(with: result)
    }

    // MARK: - Persistence

    /// Loads the stored document for the current surface id once. A load that
    /// finds nothing does not count: session restore can run before the panel
    /// adopts its persisted stable id, so the next read or page `ready`
    /// retries under the final id (a cheap file check while no scene exists).
    func loadDocumentIfNeeded() {
        guard !didLoadDocument, loadTask == nil, let store else { return }
        let surfaceID = surfaceID
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }
            let document = try? await store.load(surfaceID: surfaceID)
            guard let self, !self.didLoadDocument else { return }
            guard let document else { return }
            self.didLoadDocument = true
            guard self.sceneJSON == nil else { return }
            self.sceneJSON = document.sceneJSON
            self.mermaidSource = document.mermaidSource
            self.revision = max(self.revision, document.revision)
            self.updatedBy = document.lastAuthor
            self.elementCount = TerminalBlueprintScene.liveElementCount(inSceneJSON: document.sceneJSON)
            self.pushSceneToWebViewIfNeeded()
        }
    }

    private func scheduleSave(author: TerminalBlueprintDocument.Author) {
        guard store != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self, clock, saveDebounce] in
            // Debounce: coalesce bursts of canvas edits into one write.
            try? await clock.sleep(for: saveDebounce)
            guard !Task.isCancelled else { return }
            await self?.saveNow(author: author)
        }
    }

    /// Writes the current scene immediately (used on close/teardown).
    func flushPendingSave() async {
        guard let saveTask else { return }
        saveTask.cancel()
        self.saveTask = nil
        await saveNow(author: updatedBy)
    }

    private func saveNow(author: TerminalBlueprintDocument.Author) async {
        guard let store, let sceneJSON else { return }
        let document = TerminalBlueprintDocument(
            surfaceID: surfaceID,
            sceneJSON: sceneJSON,
            mermaidSource: mermaidSource,
            revision: revision,
            updatedAt: Date(),
            lastAuthor: author
        )
        do {
            try await store.save(document)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Session snapshot

    func sessionSnapshot() -> SessionTerminalBlueprintSnapshot? {
        guard isOpen || revision > 0 else { return nil }
        return SessionTerminalBlueprintSnapshot(isOpen: isOpen, layout: layout, revision: revision)
    }

    func restore(from snapshot: SessionTerminalBlueprintSnapshot?) {
        guard let snapshot else { return }
        revision = max(revision, snapshot.revision)
        layout = snapshot.layout
        if case .split(let fraction) = snapshot.layout {
            lastSplitFraction = TerminalBlueprintLayout.clampedFraction(fraction)
        }
        isOpen = snapshot.isOpen
        if isOpen {
            loadDocumentIfNeeded()
        }
    }

    static let emptySceneJSON = #"{"type":"excalidraw","version":2,"source":"cmux","elements":[],"appState":{},"files":{}}"#

    nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app", category: "blueprint")

    /// WebKit wraps page exceptions in an NSError whose message lives in userInfo.
    nonisolated static func describeUnderlying(_ error: any Error) -> String {
        let nsError = error as NSError
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String, !message.isEmpty {
            return message
        }
        if let message = nsError.userInfo[NSLocalizedDescriptionKey] as? String, !message.isEmpty {
            return message
        }
        return String(describing: error)
    }
}
