import Foundation
import Observation

/// State for the right-sidebar Devices tab: the surface catalog as one value
/// (device machines, their terminals, and which local panes project them),
/// plus the directory's presence-connection state for the control bar. Every
/// mutation goes through the shared Cloud tree action path; this model only
/// reads and reports.
@MainActor
@Observable
final class DevicesPanelViewModel {
    private(set) var catalog: SurfaceCatalogSnapshot = .empty
    private(set) var localWorkspaces: [CloudTreeLocalWorkspace] = []
    private(set) var presenceState: DeviceDirectory.PresenceState = .stopped
    private(set) var revealRequest: CloudTreeRevealRequest?
    private(set) var registryError: String?
    private(set) var hasLoadedDirectory = false
    private(set) var isRefreshing = false
    /// Human-readable label of the tree verb running from this panel.
    private(set) var activeOperation: String?
    /// Last failure from a tree verb, shown inline until the next refresh.
    private(set) var treeErrorDescription: String?
    private(set) var isTreeDragging = false

    var localWorkspacesProvider: @MainActor () -> [CloudTreeLocalWorkspace] = {
        guard let tabManager = AppDelegate.shared?.tabManager else { return [] }
        let selected = tabManager.selectedTabId
        return tabManager.tabs.map { CloudTreeLocalWorkspace(id: $0.id, title: $0.title, isSelected: $0.id == selected) }
    }

    private let registry: DeviceSurfaceProviderRegistry
    private var catalogObserver: NSObjectProtocol?
    private var directoryObserver: NSObjectProtocol?
    private var pendingCatalogRead = false
    private var catalogReadSuppressedByDrag = false
    private var refreshTask: Task<Void, Never>?

    convenience init() {
        self.init(registry: .shared)
    }

    init(registry: DeviceSurfaceProviderRegistry) {
        self.registry = registry
        catalogObserver = NotificationCenter.default.addObserver(
            forName: SurfaceCatalog.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCatalogRead() }
        }
        directoryObserver = NotificationCenter.default.addObserver(
            forName: DeviceDirectory.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.readDirectory() }
        }
    }

    deinit {
        if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }
        if let directoryObserver { NotificationCenter.default.removeObserver(directoryObserver) }
    }

    /// Devices the directory knows, whether or not their providers have
    /// published yet; drives the empty state and the control-bar summary.
    var knownDeviceCount: Int { registry.directory?.records.count ?? 0 }
    var onlineDeviceCount: Int { registry.directory?.records.filter(\.isOnline).count ?? 0 }

    func start() {
        registry.evaluate()
        readDirectory()
        readCatalog()
        consumePendingReveal()
    }

    /// Settings › Computers "Open": expand and select the device's row.
    func consumePendingReveal() {
        guard let instance = registry.takePendingReveal() else { return }
        revealRequest = .machine(.device(instance))
    }

    func beginOperation(_ label: String) { activeOperation = label }

    func endOperation() {
        activeOperation = nil
        readCatalog()
    }

    func noteTreeFailure(_ description: String) { treeErrorDescription = description }

    func setTreeDragging(_ dragging: Bool) {
        guard isTreeDragging != dragging else { return }
        isTreeDragging = dragging
        if !dragging, catalogReadSuppressedByDrag {
            catalogReadSuppressedByDrag = false
            readCatalog()
        }
    }

    /// Catalog changes arrive in bursts; collapse them to one read per turn and
    /// none while the outline is being dragged.
    func scheduleCatalogRead() {
        guard !pendingCatalogRead else { return }
        pendingCatalogRead = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingCatalogRead = false
            if self.isTreeDragging {
                self.catalogReadSuppressedByDrag = true
                return
            }
            self.readCatalog()
        }
    }

    func readCatalog() {
        catalog = SurfaceCatalog.shared.snapshot
        localWorkspaces = localWorkspacesProvider()
    }

    func readDirectory() {
        guard let directory = registry.directory else {
            presenceState = .stopped
            registryError = nil
            hasLoadedDirectory = false
            return
        }
        presenceState = directory.presenceState
        registryError = directory.registryError
        hasLoadedDirectory = directory.hasLoadedRegistry || directory.presenceState == .live
    }

    /// The explicit Refresh verb: registry re-read plus every link's re-sync.
    func refresh() {
        guard refreshTask == nil else { return }
        isRefreshing = true
        treeErrorDescription = nil
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.registry.refresh(force: true)
            self.readDirectory()
            self.readCatalog()
            self.isRefreshing = false
            self.refreshTask = nil
        }
    }

    /// The control-bar status line: an operation in flight, else a tree
    /// failure, else the presence link's state.
    var statusText: String? {
        if let activeOperation { return activeOperation }
        if let treeErrorDescription { return treeErrorDescription }
        if let registryError, knownDeviceCount == 0 {
            return String(localized: "devices.status.registryUnreachable", defaultValue: "Device list unreachable \u{2014} retrying")
            + " (\(registryError.prefix(40)))"
        }
        switch presenceState {
        case .stopped:
            return nil
        case .connecting:
            return String(localized: "devices.status.connecting", defaultValue: "Connecting to presence\u{2026}")
        case .live:
            return String(
                format: String(localized: "devices.status.live", defaultValue: "%1$d of %2$d online"),
                onlineDeviceCount, knownDeviceCount
            )
        case .retrying(let attempt, _):
            return String(
                format: String(localized: "devices.status.retrying", defaultValue: "Presence disconnected \u{2014} reconnecting (%d)"),
                attempt
            )
        }
    }

    var statusIsWarning: Bool {
        if activeOperation != nil { return false }
        if treeErrorDescription != nil { return true }
        if registryError != nil, knownDeviceCount == 0 { return true }
        if case .retrying = presenceState { return true }
        return false
    }
}
