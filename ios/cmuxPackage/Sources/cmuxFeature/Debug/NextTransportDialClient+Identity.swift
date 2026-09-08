#if DEBUG
import CmuxAuthRuntime
import CmuxNextTransport
import Foundation
import Observation
import OSLog
import Security

extension NextTransportDialClient {
    /// Identity private-key storage: the device-only Keychain (query shape
    /// matches `CmxIrohKeychainIdentityStore`), with a one-time migration
    /// from the UserDefaults slot early dev builds used. Secret material
    /// never returns to defaults; if the Keychain refuses the write the
    /// identity stays ephemeral for this launch.
    enum IdentityKeychain {
        static let account = "identity-private-key"

        static func read(service: String, account: String) -> Data? {
            var query = baseQuery(service: service, account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else {
                if status != errSecItemNotFound {
                    Self.logger.error(
                        "identity keychain read failed status=\(status, privacy: .public)")
                }
                return nil
            }
            return data
        }

        static func write(_ data: Data, service: String, account: String) -> Bool {
            let query = baseQuery(service: service, account: account)
            let update = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
            if update == errSecSuccess { return true }
            guard update == errSecItemNotFound else {
                Self.logger.error(
                    "identity keychain update failed status=\(update, privacy: .public)")
                return false
            }
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let add = SecItemAdd(insert as CFDictionary, nil)
            guard add == errSecSuccess else {
                Self.logger.error(
                    "identity keychain add failed status=\(add, privacy: .public)")
                return false
            }
            return true
        }

        private static func baseQuery(service: String, account: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true,
            ]
        }
    }

    static func currentIdentity(
        defaults: UserDefaults = .standard,
        keychainService: String = "dev.cmux.nextTransport.ios.identity.v1"
    ) -> PeerIdentity {
        loadOrCreateIdentity(defaults: defaults, keychainService: keychainService)
    }

    /// Resolves the durable identity on the generic executor for probe and
    /// composition paths that must not perform Keychain/defaults work on the
    /// MainActor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func currentIdentityOffMain(
        defaults: UserDefaults = .standard,
        keychainService: String = "dev.cmux.nextTransport.ios.identity.v1"
    ) async -> PeerIdentity {
        let box = DefaultsBox(defaults)
        return await currentIdentityOffMain(
            defaults: box, keychainService: keychainService)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func currentIdentityOffMain(
        defaults: DefaultsBox, keychainService: String
    ) async -> PeerIdentity {
        loadOrCreateIdentity(defaults: defaults.value, keychainService: keychainService)
    }

    static func loadOrCreateIdentity(
        defaults: UserDefaults, keychainService: String
    ) -> PeerIdentity {
        let legacyKeyKey = "dev.cmux.nextTransport.ios.identity.key"
        let idKey = "dev.cmux.nextTransport.ios.identity.deviceID"
        let deviceID: String
        if let stored = defaults.string(forKey: idKey) {
            deviceID = stored
        } else {
            deviceID = UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: idKey)
        }
        if let key = IdentityKeychain.read(service: keychainService, account: IdentityKeychain.account) {
            if let identity = try? PeerIdentity(
                appIdentity: "dev.cmux.next.ios", deviceID: deviceID, privateKeyData: key)
            {
                return identity
            }
            Self.logger.error(
                "identity keychain bytes invalid; replacing the corrupted identity")
        }
        // One-time migration: early dev builds kept the private key in
        // UserDefaults. Move it into the Keychain and clear the old slot
        // only once the Keychain write stuck.
        if let keyB64 = defaults.string(forKey: legacyKeyKey),
            let key = Data(base64Encoded: keyB64)
        {
            if IdentityKeychain.write(
                key, service: keychainService, account: IdentityKeychain.account)
            {
                defaults.removeObject(forKey: legacyKeyKey)
                Self.logger.notice("identity key migrated defaults -> keychain")
            }
            if let identity = try? PeerIdentity(
                appIdentity: "dev.cmux.next.ios", deviceID: deviceID, privateKeyData: key)
            {
                return identity
            }
            defaults.removeObject(forKey: legacyKeyKey)
            Self.logger.error(
                "legacy identity bytes invalid; generating a fresh identity")
        }
        let fresh = PeerIdentity.generate(
            appIdentity: "dev.cmux.next.ios", deviceID: deviceID)
        if !IdentityKeychain.write(
            fresh.privateKeyData, service: keychainService, account: IdentityKeychain.account)
        {
            Self.logger.error(
                "identity keychain write failed; identity is ephemeral this launch")
        }
        return fresh
    }

    /// Staging broker credentials from the dev launch env (mobile-dev-launch
    /// exports the dogfood pair into the app's environment on dev installs).
    static func brokerClient(identity: PeerIdentity) -> BrokerCredentialClient? {
        let env = ProcessInfo.processInfo.environment
        guard
            let email = env["CMUX_DOGFOOD_STACK_EMAIL"],
            let password = env["CMUX_DOGFOOD_STACK_PASSWORD"]
        else { return nil }
        return BrokerCredentialClient(
            environment: .staging,
            identity: identity,
            auth: .password(email: email, password: password),
            tag: "next-transport-ios",
            platform: "ios")
    }
}
#endif
