import Darwin
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentHookPIDSelectionTests {
    @Test("Generic hook PID selection uses the corroborated live process")
    func verifiedInferredPIDWinsAndMismatchesFailClosed() {
        let cli = CMUXCLI(args: [])
        let livePID = Int(getpid())

        #expect(
            cli.preferredAgentHookEventPID(
                agentName: "cursor",
                mappedPID: 999_991,
                inferredPID: livePID,
                verifiedPID: livePID
            ) == livePID
        )
        #expect(
            cli.preferredAgentHookEventPID(
                agentName: "cursor",
                mappedPID: 999_991,
                inferredPID: livePID,
                verifiedPID: livePID + 1
            ) == 999_991
        )
    }
}
