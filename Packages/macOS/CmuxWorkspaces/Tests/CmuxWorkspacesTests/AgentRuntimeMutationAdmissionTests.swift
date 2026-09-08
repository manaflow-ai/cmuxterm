import Testing
import CmuxWorkspaces

struct AgentRuntimeMutationAdmissionTests {
    @Test(arguments: [99.0, 100.0, 101.0], [true, false])
    func sameAgentRequiresBothWatermarks(event: Double, newerLifecycle: Bool) {
        let admission = AgentRuntimeMutationAdmission(
            lifecycleEventTime: newerLifecycle ? 100 : 90,
            statusEventTime: newerLifecycle ? 90 : 100,
            replacementWatermark: nil,
            agentEventTime: event,
            enforceOrdering: true,
            retainAcceptedEventTime: true
        )
        #expect(admission.isAccepted == (event >= 100))
        #expect(admission.retainedEventTime == (event >= 100 ? event : nil))
    }

    @Test(arguments: [99.0, 100.0, 101.0])
    func replacedAgentRequiresStrictlyNewerEvent(event: Double) {
        let admission = AgentRuntimeMutationAdmission(
            lifecycleEventTime: 90, statusEventTime: 90,
            replacementWatermark: 100, agentEventTime: event,
            enforceOrdering: true, retainAcceptedEventTime: true
        )
        #expect(admission.isAccepted == (event > 100))
        #expect(admission.retainedEventTime == (event > 100 ? event : nil))
    }

    @Test(arguments: [true, false])
    func unclockedEventsOnlyAllowInternalCleanup(enforceOrdering: Bool) {
        let admission = AgentRuntimeMutationAdmission(
            lifecycleEventTime: 100, statusEventTime: 100,
            replacementWatermark: 100, agentEventTime: nil,
            enforceOrdering: enforceOrdering, retainAcceptedEventTime: true
        )
        #expect(admission.isAccepted == !enforceOrdering)
        #expect(admission.retainedEventTime == nil)
    }

    @Test
    func customKeysDoNotRetainDurableWatermarks() {
        let admission = AgentRuntimeMutationAdmission(
            lifecycleEventTime: nil, statusEventTime: nil,
            replacementWatermark: nil, agentEventTime: 100,
            enforceOrdering: true, retainAcceptedEventTime: false
        )
        #expect(admission.isAccepted)
        #expect(admission.retainedEventTime == nil)
    }
}
