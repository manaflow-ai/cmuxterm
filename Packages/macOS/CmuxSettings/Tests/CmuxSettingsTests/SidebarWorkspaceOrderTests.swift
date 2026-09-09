import Foundation
import Testing
@testable import CmuxSettings

@Suite("SidebarWorkspaceOrder")
struct SidebarWorkspaceOrderTests {
    @Test func decodesLegacyNotificationBooleans() {
        #expect(SidebarWorkspaceOrder.decodeFromUserDefaults(true) == .notificationRecency)
        #expect(SidebarWorkspaceOrder.decodeFromUserDefaults(false) == .manual)
    }

    @Test func roundTripsCurrentStoredValues() {
        for order in SidebarWorkspaceOrder.allCases {
            #expect(
                SidebarWorkspaceOrder.decodeFromUserDefaults(order.encodeForUserDefaults()) == order
            )
            #expect(SidebarWorkspaceOrder.decodeFromJSON(order.encodeForJSON()) == order)
        }
    }

    @Test func catalogReadsLegacyValuesAndWritesCurrentValues() throws {
        let suiteName = "SidebarWorkspaceOrderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SettingCatalog().sidebar.workspaceOrder

        defaults.set(false, forKey: key.userDefaultsKey)
        #expect(key.value(in: defaults) == .manual)

        key.set(.creation, in: defaults)
        #expect(defaults.string(forKey: key.userDefaultsKey) == "creation")
        #expect(key.value(in: defaults) == .creation)
    }

    @Test func onlyPersistedOrdersAllowDragging() {
        #expect(SidebarWorkspaceOrder.notificationRecency.allowsManualReordering)
        #expect(SidebarWorkspaceOrder.manual.allowsManualReordering)
        #expect(!SidebarWorkspaceOrder.creation.allowsManualReordering)
        #expect(!SidebarWorkspaceOrder.custom.allowsManualReordering)
    }
}
