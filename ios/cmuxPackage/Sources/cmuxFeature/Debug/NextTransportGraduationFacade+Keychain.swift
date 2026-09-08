#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import CmuxMobileShell
import CmuxNextTransport
import CmuxNextTransportBridge
import Foundation
import OSLog
import Security

extension NextTransportGraduationFacade {
    /// Device-only Keychain persistence for ticket/grant pairs. The defaults
    /// key is retained solely as a one-time migration source for older debug
    /// builds; new writes never place pairing material in preferences.
    enum BootstrapKeychain {
        private static let accountPrefix = "mac-"

        static func read(
            macID: String, defaults: UserDefaults, keyPrefix: String
        ) -> Data? {
            let account = accountPrefix + macID
            var query = baseQuery(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                let data = result as? Data {
                return data
            }
            guard let legacy = defaults.data(forKey: keyPrefix + macID) else { return nil }
            // Migrate atomically from the old preferences slot when possible.
            let migrated = writeKeychain(legacy, account: account)
            // Never leave ticket/grant material in the preferences plist when
            // the protected write is unavailable; callers can re-pair.
            defaults.removeObject(forKey: keyPrefix + macID)
            return migrated ? legacy : nil
        }

        static func write(
            _ data: Data, macID: String, defaults: UserDefaults, keyPrefix: String
        ) -> Bool {
            let account = accountPrefix + macID
            if writeKeychain(data, account: account) {
                defaults.removeObject(forKey: keyPrefix + macID)
                return true
            } else {
                Self.logger.error(
                    "bootstrap Keychain write failed mac=\(String(macID.prefix(8)), privacy: .public); not writing defaults")
                defaults.removeObject(forKey: keyPrefix + macID)
                return false
            }
        }

        static func delete(
            macID: String, defaults: UserDefaults, keyPrefix: String
        ) {
            SecItemDelete(baseQuery(account: accountPrefix + macID) as CFDictionary)
            defaults.removeObject(forKey: keyPrefix + macID)
        }

        private static func writeKeychain(_ data: Data, account: String) -> Bool {
            let query = baseQuery(account: account)
            let update = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
            if update == errSecSuccess { return true }
            guard update == errSecItemNotFound else { return false }
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }

        private static func baseQuery(account: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: bootstrapKeychainService,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true,
            ]
        }
    }
}
#endif
