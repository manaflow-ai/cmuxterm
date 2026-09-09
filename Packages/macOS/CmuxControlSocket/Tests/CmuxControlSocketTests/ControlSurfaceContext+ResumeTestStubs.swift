import Foundation
@testable import CmuxControlSocket

extension ControlSurfaceContext {
    func controlSurfaceResumeSet(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        inputs: ControlSurfaceResumeSetInputs
    ) -> ControlSurfaceResumeResolution { .surfaceNotFound }

    nonisolated func controlSurfaceInvalidAgentEventTimeError() -> String {
        "Missing or invalid agent_event_time"
    }

    func controlSurfaceResumeGet(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        claimCheckpointID: String?,
        claimSource: String?,
        claimUpdatedAt: Double?
    ) -> ControlSurfaceResumeResolution { .surfaceNotFound }

    func controlSurfaceResumeClear(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        expectedCheckpointID: String?,
        expectedSource: String?,
        expectedUpdatedAt: Double?,
        agentEventTime: TimeInterval?,
        agentSessionEnded: Bool
    ) -> ControlSurfaceResumeResolution { .surfaceNotFound }

}
