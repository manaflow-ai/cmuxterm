import Foundation

/// A main-actor socket command that exceeded the watchdog deadline.
struct MainThreadSocketCommandWatchdogObservation: Sendable, Equatable {
    let descriptor: SocketCommandDescriptor
    let elapsedMs: Double
    let thresholdMs: Double
    let backtrace: [String]
}
