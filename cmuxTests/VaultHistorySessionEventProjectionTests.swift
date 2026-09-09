import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct VaultHistorySessionEventProjectionTests {
    @Test func projectionProducesStableDerivedEvents() throws {
        let entry = SessionEntry(
            id: "abc123",
            agent: .claude,
            sessionId: "abc123",
            title: "Fix the tests",
            cwd: "/tmp/repo",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            fileURL: nil,
            specifics: .claude(
                model: nil,
                permissionMode: nil,
                configDirectoryForResume: nil
            )
        )
        let projection = VaultHistorySessionEventProjection()

        let first = projection.events(from: [entry])
        let second = projection.events(from: [entry])
        #expect(first == second)

        let event = try #require(first.first)
        #expect(event.id == "session:claude:abc123")
        #expect(event.kind == .sessionActivity)
        #expect(event.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(event.title == "Fix the tests")
        #expect(event.subject.agent == "claude")
        #expect(event.subject.sessionId == "abc123")
        #expect(event.subject.directory == "/tmp/repo")
    }

    /// Reports the cost of the production projection for the review's
    /// 1,000-session case without making correctness depend on CI hardware.
    @Test func projectionMeasuresThousandSessionSnapshot() {
        let entries = (0..<1000).map { index in
            SessionEntry(
                id: "\(index)",
                agent: .claude,
                sessionId: "\(index)",
                title: "Review a deliberately long session title for workspace \(index)",
                cwd: "/tmp/vault-history-benchmark/project-\(index % 20)",
                gitBranch: nil,
                pullRequest: nil,
                // A deterministic permutation exercises an unsorted snapshot.
                modified: Date(timeIntervalSince1970: Double((index * 37) % 1000)),
                fileURL: nil,
                specifics: .claude(
                    model: nil,
                    permissionMode: nil,
                    configDirectoryForResume: nil
                )
            )
        }
        let projection = VaultHistorySessionEventProjection()
        let expected = projection.events(from: entries)
        #expect(expected.count == 1000)
        #expect(Set(expected.map(\.id)).count == 1000)
        #expect(expected.first?.id == "session:claude:27")
        #expect(expected.last?.id == "session:claude:0")
        #expect(zip(expected, expected.dropFirst()).allSatisfy { pair in
            pair.0.timestamp > pair.1.timestamp
        })

        for _ in 0..<5 {
            #expect(projection.events(from: entries) == expected)
        }

        let clock = ContinuousClock()
        var milliseconds: [Double] = []
        for _ in 0..<30 {
            var projected = expected
            let duration = clock.measure {
                projected = projection.events(from: entries)
            }
            // Observe every output field outside the timed section, both to
            // check repeatability and to keep the measured work observable.
            #expect(projected == expected)
            let components = duration.components
            milliseconds.append(
                Double(components.seconds) * 1000
                    + Double(components.attoseconds) / 1_000_000_000_000_000
            )
        }
        milliseconds.sort()
        let median = milliseconds[milliseconds.count / 2]
        let p95 = milliseconds[(milliseconds.count * 95 - 1) / 100]
        print(
            "VAULT_HISTORY_PROJECTION_BENCHMARK entries=1000 samples=30 "
                + "input=permuted median_ms=\(median) p95_ms=\(p95)"
        )
    }
}
