import CmuxCLISocketAuth
import Foundation
import os
import Testing

private final class CLITestCounter: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock<Int>(initialState: 0)

    var value: Int {
        storage.withLock { $0 }
    }

    func increment() {
        storage.withLock { $0 += 1 }
    }
}

/// App-host smoke coverage for the package credential boundary.
@Suite(.serialized)
struct CLISocketCredentialResolverTests {
    @Test(arguments: [true, false])
    func nextOperationCanResolveAfterPriorProviderDeadline(returnsPassword: Bool) {
        let instant = Date(timeIntervalSince1970: 1_000)
        let clock = OSAllocatedUnfairLock(initialState: instant)
        var attempt = SocketCredentialResolutionAttempt(now: { clock.withLock { $0 } })
        var providerCalls = 0
        let expiredResult = attempt.resolve(
            provider: { _ in
                providerCalls += 1
                clock.withLock { $0.addTimeInterval(2) }
                return returnsPassword ? "cached-password" : nil
            },
            deadline: instant.addingTimeInterval(1)
        )
        #expect(expiredResult == nil)
        #expect(!attempt.isCompleted)
        let nextResult = attempt.resolve(
            provider: { _ in
                providerCalls += 1
                return "cached-password"
            },
            deadline: instant.addingTimeInterval(3)
        )
        #expect(nextResult == "cached-password")
        #expect(attempt.isCompleted)
        #expect(providerCalls == 2)
    }

    @Test
    func initialConnectionDemandDoesNotReadDeferredSources() {
        let fileReads = CLITestCounter()
        let keychainReads = CLITestCounter()
        let resolver = SocketCredentialResolver(
            explicitPassword: nil,
            socketPath: "/tmp/cmux-debug-allow-all.sock",
            environment: [:],
            filePasswordProvider: {
                fileReads.increment()
                return "file-password"
            },
            keychainPasswordProvider: { _ in
                keychainReads.increment()
                return "keychain-password"
            }
        )

        #expect(!SocketAuthenticationChallenge.isRequired("PONG"))
        #expect(resolver.password(for: .initialConnection) == nil)
        #expect(fileReads.value == 0)
        #expect(keychainReads.value == 0)
    }
}
