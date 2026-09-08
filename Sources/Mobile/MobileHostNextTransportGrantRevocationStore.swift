#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

/// Device-only durable denylist for DEBUG next-transport grants. The actor
/// serializes read/modify/write updates so concurrent revocations cannot
/// overwrite one another, and caps retained IDs to keep the store bounded.
actor MobileHostNextTransportGrantRevocationStore {
    private let keychain: any CmxIrohSecureCredentialStoring
    let account = "all"
    private let maximumGrantIDs = 1_024

    init(keychain: any CmxIrohSecureCredentialStoring = CmxIrohKeychainCredentialStore(
        service: "dev.cmux.nextTransport.revokedGrants")) {
        self.keychain = keychain
    }

    func load() async -> Set<String> {
        do {
            guard let data = try await keychain.read(account: account) else { return [] }
            return Set(try JSONDecoder().decode([String].self, from: data))
        } catch {
            MobileHostNextTransportRuntime.logger.error(
                "next-transport grant revocation read failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    func revoke(_ grantIDs: Set<String>) async {
        guard !grantIDs.isEmpty else { return }
        var all = await load()
        all.formUnion(grantIDs)
        if all.count > maximumGrantIDs {
            all = Set(all.sorted().suffix(maximumGrantIDs))
        }
        do {
            let data = try JSONEncoder().encode(all.sorted())
            try await keychain.write(
                data,
                account: account,
                accessibility: .afterFirstUnlockThisDeviceOnly)
        } catch {
            MobileHostNextTransportRuntime.logger.error(
                "next-transport grant revocation write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
