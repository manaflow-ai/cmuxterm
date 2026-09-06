import Foundation

/// How much of its terminal pane an open blueprint drawer occupies.
///
/// The drawer sits below the Ghostty surface inside the same pane. `collapsed`
/// shows only the header bar, `split` shares the pane at a user-dragged
/// fraction, and `enlarged` gives the canvas most of the pane while keeping a
/// minimum terminal height so the hosted terminal view never reaches zero size.
enum TerminalBlueprintLayout: Equatable, Sendable {
    case collapsed
    case split(fraction: Double)
    case enlarged

    static let defaultSplitFraction = 0.4
    static let minimumSplitFraction = 0.15
    static let maximumSplitFraction = 0.85
    static let enlargedFraction = 0.85
    /// Height of the header bar, the only thing visible while collapsed.
    static let headerHeight = 30.0
    /// The terminal keeps at least this many points however large the drawer is.
    static let minimumTerminalHeight = 96.0

    static func clampedFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return defaultSplitFraction }
        return min(maximumSplitFraction, max(minimumSplitFraction, fraction))
    }

    var isCollapsed: Bool {
        if case .collapsed = self { return true }
        return false
    }

    var isEnlarged: Bool {
        if case .enlarged = self { return true }
        return false
    }

    /// The pane fraction the drawer wants, or nil while collapsed.
    var fraction: Double? {
        switch self {
        case .collapsed:
            return nil
        case .split(let fraction):
            return Self.clampedFraction(fraction)
        case .enlarged:
            return Self.enlargedFraction
        }
    }

    /// Resolves the drawer height for a pane of `containerHeight` points.
    func drawerHeight(containerHeight: Double) -> Double {
        guard let fraction, containerHeight.isFinite, containerHeight > 0 else {
            return Self.headerHeight
        }
        let requested = containerHeight * fraction
        let maximum = max(Self.headerHeight, containerHeight - Self.minimumTerminalHeight)
        return max(Self.headerHeight, min(requested, maximum))
    }
}

extension TerminalBlueprintLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case fraction
    }

    private enum Kind: String, Codable {
        case collapsed
        case split
        case enlarged
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .collapsed:
            self = .collapsed
        case .split:
            let fraction = try container.decodeIfPresent(Double.self, forKey: .fraction)
                ?? Self.defaultSplitFraction
            self = .split(fraction: Self.clampedFraction(fraction))
        case .enlarged:
            self = .enlarged
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .collapsed:
            try container.encode(Kind.collapsed, forKey: .kind)
        case .split(let fraction):
            try container.encode(Kind.split, forKey: .kind)
            try container.encode(Self.clampedFraction(fraction), forKey: .fraction)
        case .enlarged:
            try container.encode(Kind.enlarged, forKey: .kind)
        }
    }
}
