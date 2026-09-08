/// Observability is contractual (8.1, 8.2): admissions, denials by reason,
/// closes by reason, renewals. The lab screen renders these live in P1.
public struct TransportCounters: Sendable, Equatable {
    public var admissions = 0
    public var denialsByCode: [String: Int] = [:]
    public var closesByCode: [String: Int] = [:]
    public var grantRenewals = 0
    public var grantRenewalRejections = 0

    public init() {}
}
