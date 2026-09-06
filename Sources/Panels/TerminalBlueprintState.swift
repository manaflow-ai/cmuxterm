import Foundation
import Observation

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
    func setTheme(isDark: Bool) async
    func zoomToFit() async
    func clearScene() async
}

/// Persistence seam for blueprint documents; `TerminalBlueprintStore` is the
/// production implementation.
protocol TerminalBlueprintPersisting: Sendable {
    func load(surfaceID: UUID) async throws -> TerminalBlueprintDocument?
    func save(_ document: TerminalBlueprintDocument) async throws
}

enum TerminalBlueprintError: Error, Equatable {
    case webViewUnavailable
    case exportTimedOut
    case exportFailed(String)
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

    @ObservationIgnored private let store: (any TerminalBlueprintPersisting)?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let saveDebounce: Duration
    @ObservationIgnored private let exportTimeout: Duration
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var didLoadDocument = false
    @ObservationIgnored private var lastSplitFraction = TerminalBlueprintLayout.defaultSplitFraction
    @ObservationIgnored private var pendingExports: [String: CheckedContinuation<TerminalBlueprintExportResult, any Error>] = [:]
    @ObservationIgnored private var exportTimeoutTasks: [String: Task<Void, Never>] = [:]

    init(
        surfaceIDProvider: @escaping @MainActor () -> UUID = { UUID() },
        store: (any TerminalBlueprintPersisting)?,
        clock: any Clock<Duration> = ContinuousClock(),
        saveDebounce: Duration = .milliseconds(750),
        exportTimeout: Duration = .seconds(15),
        defaults: UserDefaults = .standard
    ) {
        self.surfaceIDProvider = surfaceIDProvider
        self.store = store
        self.clock = clock
        self.saveDebounce = saveDebounce
        self.exportTimeout = exportTimeout
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
        }
    }

    func open() {
        isOpen = true
        if layout.isCollapsed {
            layout = .split(fraction: lastSplitFraction)
        }
        hasUnseenAgentUpdate = false
        loadDocumentIfNeeded()
    }

    func close() {
        isOpen = false
    }

    func collapse() {
        rememberSplitFraction()
        layout = .collapsed
    }

    func expand() {
        layout = .split(fraction: lastSplitFraction)
        hasUnseenAgentUpdate = false
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
            pushSceneToWebViewIfNeeded()
        case .sceneChanged(let sceneJSON, let elementCount, let digest):
            guard digest.isEmpty || digest != lastAppliedDigest else { return }
            self.sceneJSON = sceneJSON
            self.elementCount = elementCount
            lastAppliedDigest = digest
            revision += 1
            updatedBy = .user
            scheduleSave(author: .user)
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
        author: TerminalBlueprintDocument.Author,
        autoOpen: Bool? = nil
    ) async -> Int {
        self.sceneJSON = sceneJSON
        if let mermaidSource {
            self.mermaidSource = mermaidSource
        }
        revision += 1
        updatedBy = author
        didLoadDocument = true
        if author == .agent {
            let shouldOpen = autoOpen ?? TerminalBlueprintFeature.autoOpensOnAgentUpdate(defaults: defaults)
            if shouldOpen {
                if !isOpen { open() }
                if layout.isCollapsed { expand() }
            } else if !isExpanded {
                hasUnseenAgentUpdate = true
            }
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
        return revision
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

    func loadDocumentIfNeeded() {
        guard !didLoadDocument, loadTask == nil, let store else { return }
        let surfaceID = surfaceID
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }
            let document = try? await store.load(surfaceID: surfaceID)
            guard let self, !self.didLoadDocument else { return }
            self.didLoadDocument = true
            guard let document, self.sceneJSON == nil else { return }
            self.sceneJSON = document.sceneJSON
            self.mermaidSource = document.mermaidSource
            self.revision = max(self.revision, document.revision)
            self.updatedBy = document.lastAuthor
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
}
