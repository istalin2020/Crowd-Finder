import Foundation

/// How crowded a place is, derived from a busyness percentage.
///
/// Busyness percentages follow the same convention as BestTime and Google "Popular times":
/// 100 % is the venue's own busiest hour of a normal week. Live values can go above 100 %.
enum CrowdLevel: Int, CaseIterable, Comparable, Codable, Sendable {
    case empty
    case quiet
    case moderate
    case busy
    case veryBusy

    /// Upper bounds (inclusive) for each level.
    static let quietMax = 24
    static let moderateMax = 49
    static let busyMax = 74

    init(busyness: Int) {
        switch busyness {
        case ..<1: self = .empty
        case ...Self.quietMax: self = .quiet
        case ...Self.moderateMax: self = .moderate
        case ...Self.busyMax: self = .busy
        default: self = .veryBusy
        }
    }

    static func < (lhs: CrowdLevel, rhs: CrowdLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .empty: "Empty"
        case .quiet: "Quiet"
        case .moderate: "Moderate"
        case .busy: "Busy"
        case .veryBusy: "Very busy"
        }
    }

    /// A short go/no-go suggestion for the user.
    var advice: String {
        switch self {
        case .empty: "Likely closed or empty right now"
        case .quiet: "Great time to go"
        case .moderate: "Good time to go"
        case .busy: "Expect a crowd"
        case .veryBusy: "Very crowded – consider going later"
        }
    }

    /// SF Symbol that summarises the advice.
    var adviceSymbolName: String {
        switch self {
        case .empty: "moon.zzz.fill"
        case .quiet, .moderate: "checkmark.circle.fill"
        case .busy: "exclamationmark.triangle.fill"
        case .veryBusy: "xmark.octagon.fill"
        }
    }

    /// Levels shown in the map legend.
    static let legendLevels: [CrowdLevel] = [.quiet, .moderate, .busy, .veryBusy]
}
