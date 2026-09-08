#if DEBUG
import Foundation

extension NextTransportGraduationFacade {
    var bootstrapKeychain: NextTransportBootstrapKeychain {
        NextTransportBootstrapKeychain(service: Self.bootstrapKeychainService, logger: Self.logger)
    }
}
#endif
