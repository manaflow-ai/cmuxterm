import CmuxFoundation
import CmuxSettings
import Foundation

/// Owns one ``CmuxTuiSurfaceProvider`` per cloud machine and keeps the catalog's machine
/// list in step with the control plane: registers a provider for every machine the
/// account can see, unregisters deleted ones, and drives refreshes on the same 45 s
/// cadence the Machines panel uses. Signing out tears everything down.
@MainActor
final class CmuxTuiSurfaceProviderRegistry {
    static let shared = CmuxTuiSurfaceProviderRegistry()

    private var catalog: SurfaceCatalog?
    private var providers: [String: CmuxTuiSurfaceProvider] = [:]
    private let links: CloudMachineLinkManager
    /// The app's one WireGuard hub for private-network machines; nil when no cmux-tui
    /// client is bundled (then no link can be made at all).
    let wireGuardHub: CloudWireGuardHub?
    private var pollTask: Task<Void, Never>?
    private var accessObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var refreshInFlight: Task<Bool, Never>?
    /// A forced refresh waits for an existing pass instead of starting a second
    /// fleet read. This prevents an older page from unregistering a machine that
    /// a newer page just added.
    private var refreshGeneration: UInt64 = 0
    /// Same cadence as the Machines panel's list refresh.
    private let pollInterval: Duration = .seconds(45)

    init(links: CloudMachineLinkManager, wireGuardHub: CloudWireGuardHub?) {
        self.links = links
        self.wireGuardHub = wireGuardHub
    }

    /// The production registry: one hub over the bundled client, shared by every link.
    convenience init() {
        let hub = CloudTuiClientPaths.clientURL().map { CloudWireGuardHub.production(clientURL: $0) }
        self.init(links: CloudMachineLinkManager(hub: hub), wireGuardHub: hub)
    }

    /// Kills the hub child synchronously; for `applicationWillTerminate`, where nothing
    /// may await and an orphaned hub would keep a WireGuard session alive after quit.
    nonisolated func terminateWireGuardHubForAppQuit() {
        wireGuardHub?.terminateForAppQuit()
    }

    /// Live headless links, for the Cloud tunnel's idle policy.
    func connectedCloudLinkCount() async -> Int {
        await links.connectedMachineCount
    }

    /// Registers this Mac's cloud machines with the catalog and starts polling.
    func start(catalog: SurfaceCatalog) {
        self.catalog = catalog
        guard !ManagedDevicePolicy().isEnforced(.disableCloud) else { return }
        // Block observers are retained by NotificationCenter: drop the previous
        // tokens so a re-start never leaves stale callbacks registered.
        if let accessObserver { NotificationCenter.default.removeObserver(accessObserver) }
        accessObserver = NotificationCenter.default.addObserver(
            forName: .cmuxCloudVMAccessDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.accessDidEnd() }
        }
        // A Ghostty config reload can change the resolved theme; re-push it so remote
        // panes keep matching the local ones (connect-time push covers new links).
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        themeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.links.pushHostThemeToConnectedLinks() }
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(force: false)
                // The poll interval is the intended behavior (the list is not push-driven),
                // not a synchronization substitute.
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(45))
            }
        }
    }

    /// Re-reads the machine list and refreshes every provider (links, snapshots, ports).
    @discardableResult
    func refresh(force: Bool) async -> Bool {
        guard !ManagedDevicePolicy().isEnforced(.disableCloud) else { return false }
        while true {
            if let inFlight = refreshInFlight {
                let listed = await inFlight.value
                if refreshInFlight == inFlight {
                    refreshInFlight = nil
                }
                if !force { return listed }
                continue
            }

            refreshGeneration &+= 1
            let generation = refreshGeneration
            let task = Task<Bool, Never> { [weak self] in
                guard let self else { return false }
                return await self.performRefresh(force: force, generation: generation)
            }
            refreshInFlight = task
            let listed = await task.value
            if refreshGeneration == generation {
                refreshInFlight = nil
            }
            return listed
        }
    }

    func provider(machineID: String) -> CmuxTuiSurfaceProvider? {
        providers[machineID]
    }

    /// The provider for a machine that may have been created a moment ago (`cmux vm new`
    /// opens its terminal right after `POST /api/vm` returns): when the registry has not
    /// listed it yet, re-read the fleet once instead of failing with "no provider".
    func providerRefreshingIfMissing(machineID: String) async -> CmuxTuiSurfaceProvider? {
        guard !ManagedDevicePolicy().isEnforced(.disableCloud) else { return nil }
        if let provider = providers[machineID] { return provider }
        await refresh(force: true)
        return providers[machineID]
    }

    func machineWasDeleted(_ id: String) {
        providers[id]?.stop()
        providers[id] = nil
        catalog?.unregister(machine: .cloud(id))
        Task { await links.disconnect(machineID: id) }
    }

    /// The headless link's local mux socket for a machine, connecting if needed.
    func linkSocketPath(machineID: String) async throws -> (socketPath: String, session: String) {
        let connected = try await links.connected(machineID: machineID)
        return (connected.socketPath, connected.session)
    }

    func privateRoute(machineID: String) async -> String? {
        await links.privateRoute(for: machineID)
    }

    // MARK: - internals

    private func performRefresh(force: Bool, generation: UInt64) async -> Bool {
        guard let catalog, let client = VMClient.shared else { return false }
        guard let page = try? await client.listPage() else { return false }
        guard generation == refreshGeneration else { return false }
        let seen = Set(page.vms.map(\.id))
        // Reconcile both stores. A restored catalog can contain a machine for
        // which this process has not created a provider yet.
        let catalogMachineIDs = Set(catalog.machines.keys.compactMap(\.cloudMachineID))
        let staleIDs = Set(providers.keys)
            .union(catalogMachineIDs)
            .union(catalog.pendingRestoredMachineIDs)
            .subtracting(seen)
        for id in staleIDs {
            providers[id]?.stop()
            providers[id] = nil
            catalog.unregister(machine: .cloud(id))
        }
        await links.retain(machineIDs: seen)
        guard generation == refreshGeneration else { return false }
        for summary in page.vms {
            await links.setPrivateAddress(summary.preferredPrivateAddress, for: summary.id)
            if let provider = providers[summary.id] {
                provider.update(summary: summary)
            } else {
                let provider = CmuxTuiSurfaceProvider(summary: summary, links: links, catalog: catalog)
                providers[summary.id] = provider
                catalog.register(provider)
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for provider in providers.values {
                group.addTask { @MainActor in await provider.refresh(force: force) }
            }
        }
        return true
    }

    func accessDidEnd() async {
        for provider in providers.values { provider.stop() }
        for id in providers.keys { catalog?.unregister(machine: .cloud(id)) }
        providers.removeAll()
        await links.disconnectAll()
        // Signing out drops the tunnel too: the next account enrolls its own.
        await wireGuardHub?.stop()
    }
}
