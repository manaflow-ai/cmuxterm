import Foundation

/// Which machines a Cloud-style outline lists. The Cloud tab and the Devices
/// tab share one tree stack (`CloudTreeNodeBuilder`, `CloudTreeOutlineView`,
/// the row views, `CloudTreeNodeActions`); this value is the single switch that
/// decides which catalog machines become top-level rows.
enum CloudTreeMachineSource: Equatable, Sendable {
    /// The Cloud tab: the cloud fleet only. Device machines in the catalog are
    /// ignored, so the tree stays byte-for-byte what it was before devices existed.
    case cloud
    /// The Devices tab: the account's other Macs only, each a top-level machine row.
    case devices
    /// The Cloud tab with a "Devices" section appended under the fleet. The
    /// follow-up that merges the Devices tab into the Cloud tab flips
    /// `MachinesPanelView` to this value; nothing else changes.
    case cloudWithDevicesSection

    var includesCloudMachines: Bool {
        switch self {
        case .cloud, .cloudWithDevicesSection: return true
        case .devices: return false
        }
    }

    var includesDevices: Bool {
        switch self {
        case .devices, .cloudWithDevicesSection: return true
        case .cloud: return false
        }
    }

    /// Devices sit under a group header only when they share the tree with the fleet.
    var groupsDevicesUnderSection: Bool { self == .cloudWithDevicesSection }
}
