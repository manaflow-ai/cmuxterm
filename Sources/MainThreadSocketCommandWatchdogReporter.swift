/// Reports main-thread socket command watchdog events.
protocol MainThreadSocketCommandWatchdogReporter: AnyObject, Sendable {
    func reportHang(_ observation: MainThreadSocketCommandWatchdogObservation)
    func reportRecovery(_ observation: MainThreadSocketCommandWatchdogObservation)
}
