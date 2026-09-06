/// Receives release-visible slow CLI socket command observations.
protocol SlowSocketCommandSink: AnyObject, Sendable {
    func recordSlowCommand(_ observation: SocketCommandObservation)
}
