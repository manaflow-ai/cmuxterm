import CmuxSettingsUI
import Foundation

extension HostSettingsActions {
    func computersSettingsActions() -> ComputersSettingsActions {
        ComputersSettingsActions(
            updates: { HiveComputersService.shared.updates() },
            refresh: { await HiveComputersService.shared.refresh() },
            pair: { await HiveComputersService.shared.pair($0) },
            open: { await HiveComputersService.shared.open($0) },
            unpair: { await HiveComputersService.shared.unpair($0) },
            showPairing: { MobilePairingWindowController.shared.show() }
        )
    }
}
