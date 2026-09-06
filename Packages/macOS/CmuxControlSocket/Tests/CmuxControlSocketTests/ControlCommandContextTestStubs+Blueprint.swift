import Foundation
@testable import CmuxControlSocket

// Benign defaults for the blueprint-domain seam, so a test fake that conforms
// to the full `ControlCommandContext` umbrella only has to implement the
// domain it actually exercises (same pattern as
// ControlCommandContextTestStubs+Project.swift).

extension ControlBlueprintContext {
    func controlBlueprintState(
        routing: ControlRoutingSelectors
    ) -> ControlBlueprintResolution<ControlBlueprintStateSnapshot> { .workspaceNotFound }

    func controlBlueprintContent(
        routing: ControlRoutingSelectors,
        format: String
    ) -> ControlBlueprintResolution<ControlBlueprintContent> { .workspaceNotFound }

    func controlBlueprintSetVisibility(
        routing: ControlRoutingSelectors,
        action: ControlBlueprintVisibilityAction,
        requestedFocus: Bool
    ) -> ControlBlueprintResolution<ControlBlueprintVisibilityOutcome> { .workspaceNotFound }
}
