import Foundation

@MainActor
public struct ComputersSettingsActions {
    public var updates: () -> AsyncStream<ComputersSettingsSnapshot>
    public var refresh: () async -> Void
    public var pair: (String) async -> String?
    public var open: (String) async -> Void
    public var unpair: (String) async -> Void
    public var showPairing: () -> Void

    public init(
        updates: @escaping () -> AsyncStream<ComputersSettingsSnapshot> = { AsyncStream { $0.finish() } },
        refresh: @escaping () async -> Void = {},
        pair: @escaping (String) async -> String? = { _ in nil },
        open: @escaping (String) async -> Void = { _ in },
        unpair: @escaping (String) async -> Void = { _ in },
        showPairing: @escaping () -> Void = {}
    ) {
        self.updates = updates
        self.refresh = refresh
        self.pair = pair
        self.open = open
        self.unpair = unpair
        self.showPairing = showPairing
    }
}

public extension SettingsHostActions {
    func computersSettingsActions() -> ComputersSettingsActions { ComputersSettingsActions() }
}
