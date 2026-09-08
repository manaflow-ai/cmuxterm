public import Foundation

/// Shared interpretation of HTTP `Retry-After` for every automatic client
/// retry owner. A server directive is a minimum wait, never a replacement for
/// a longer local backoff.
public enum CmxRetryAfterPolicy {
    public static let defaultRateLimitSeconds = 60

    /// Parses either delta-seconds or an HTTP-date. Invalid, zero, and expired
    /// directives return nil so callers can apply their documented fallback.
    public static func seconds(
        from value: String?,
        now: Date = Date()
    ) -> Int? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let seconds = Int(raw), seconds > 0 {
            return seconds
        }
        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'",
            "EEEE',' dd-MMM-yy HH':'mm':'ss 'GMT'",
            "EEE MMM d HH':'mm':'ss yyyy",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let deadline = formatter.date(from: raw) {
                let remaining = Int(ceil(deadline.timeIntervalSince(now)))
                return remaining > 0 ? remaining : nil
            }
        }
        return nil
    }

    public static func seconds(
        from response: HTTPURLResponse,
        now: Date = Date(),
        defaultSeconds: Int? = nil
    ) -> Int? {
        seconds(
            from: response.value(forHTTPHeaderField: "Retry-After"),
            now: now
        ) ?? defaultSeconds.flatMap { $0 > 0 ? $0 : nil }
    }

    public static func delay(
        localSeconds: TimeInterval,
        retryAfterSeconds: Int?
    ) -> TimeInterval {
        max(localSeconds, TimeInterval(max(0, retryAfterSeconds ?? 0)))
    }
}

/// Transport-neutral rate-limit error used when Foundation exposes an HTTP
/// handshake response only after a WebSocket operation fails.
public struct CmxRateLimitedError: CmxRetryAfterProviding, Equatable {
    public let retryAfterSeconds: Int?

    public init(retryAfterSeconds: Int?) {
        self.retryAfterSeconds = retryAfterSeconds
    }
}

/// One monotonic cooldown shared by all triggers that can reach the same
/// endpoint. Concurrent callers join the deadline, and a later directive may
/// extend but never shorten it.
public actor CmxRetryAfterGate {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let now: @Sendable () -> TimeInterval
    private let sleep: Sleep
    private var deadline: TimeInterval?

    public init() {
        now = { ProcessInfo.processInfo.systemUptime }
        sleep = { try await Task<Never, Never>.sleep(for: .seconds($0)) }
    }

    init(
        now: @escaping @Sendable () -> TimeInterval,
        sleep: @escaping Sleep
    ) {
        self.now = now
        self.sleep = sleep
    }

    public func extend(by seconds: Int) {
        guard seconds > 0 else { return }
        let candidate = now() + TimeInterval(seconds)
        deadline = max(deadline ?? candidate, candidate)
    }

    public func remainingSeconds() -> Int? {
        guard let deadline else { return nil }
        let remaining = Int(ceil(deadline - now()))
        if remaining <= 0 {
            self.deadline = nil
            return nil
        }
        return remaining
    }

    public func wait() async throws {
        while let deadline {
            let remaining = deadline - now()
            guard remaining > 0 else {
                self.deadline = nil
                return
            }
            try await sleep(remaining)
        }
    }
}
