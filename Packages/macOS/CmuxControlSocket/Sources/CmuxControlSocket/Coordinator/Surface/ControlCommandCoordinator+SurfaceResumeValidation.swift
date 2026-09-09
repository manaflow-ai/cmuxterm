internal import Foundation

extension ControlCommandCoordinator {
    /// The byte-faithful twin of `v2SurfaceResumeTargetValidationError`: an
    /// `invalid_params` error when any of `window_id` / `workspace_id` /
    /// `surface_id` / `terminal_id` / `tab_id` is present-but-non-null yet
    /// does not resolve.
    func surfaceResumeTargetValidationError(
        _ params: [String: JSONValue]
    ) -> ControlCallResult? {
        for key in ["window_id", "workspace_id", "surface_id", "terminal_id", "tab_id"] where hasNonNull(params, key) {
            if uuid(params, key) == nil {
                return .err(code: "invalid_params", message: "Missing or invalid \(key)", data: nil)
            }
        }
        return nil
    }

    /// The legacy `v2PublicSurfaceResumeSource`: `process-detected` → `manual`.
    func publicResumeSource(_ params: [String: JSONValue]) -> String? {
        let source = optionalTrimmedRawString(params, "source")
        return source == "process-detected" ? "manual" : source
    }

    func surfaceAgentEventTime(
        _ params: [String: JSONValue]
    ) -> (value: TimeInterval?, error: ControlCallResult?) {
        guard hasNonNull(params, "agent_event_time") else { return (nil, nil) }
        guard let value = double(params, "agent_event_time"),
              value.isPlausibleControlAgentEventTime else {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: context?.controlSurfaceInvalidAgentEventTimeError()
                        ?? "Missing or invalid agent_event_time; expected Unix seconds between 2000-01-01 and 5 minutes from now",
                    data: nil
                )
            )
        }
        return (value, nil)
    }
}
