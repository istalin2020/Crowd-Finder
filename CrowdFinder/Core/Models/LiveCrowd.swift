import Foundation

/// One live crowd report sent by a person who is at the place.
struct CommunityCrowdReport: Equatable, Sendable {
    /// Quiet, moderate, busy or very busy.
    let level: CrowdLevel
    /// Set by the server when the report was saved.
    let createdAt: Date

    /// Reports are stored as 1 … 4.
    static let reportableLevels: [CrowdLevel] = [.quiet, .moderate, .busy, .veryBusy]

    var storedValue: Int { level.rawValue }

    init(level: CrowdLevel, createdAt: Date) {
        self.level = level
        self.createdAt = createdAt
    }

    init?(storedValue: Int, createdAt: Date) {
        guard let level = CrowdLevel(rawValue: storedValue), Self.reportableLevels.contains(level) else { return nil }
        self.init(level: level, createdAt: createdAt)
    }
}

/// What recent visitor reports say about the crowd right now.
struct LiveCrowdSummary: Equatable, Sendable {
    let busyness: Int
    let reportCount: Int
    let newestReportAt: Date

    var level: CrowdLevel { CrowdLevel(busyness: busyness) }
}

/// Combines recent visitor reports into one live busyness value.
///
/// - Only reports from the last `window` count.
/// - Newer reports count more: a report's weight halves every `halfLife`
///   (a 30-minute-old report counts half as much as a fresh one).
enum LiveCrowdAggregator {
    static let window: TimeInterval = 90 * 60
    static let halfLife: TimeInterval = 30 * 60

    /// Busyness used for each reported level (the middle of its range).
    static func busyness(for level: CrowdLevel) -> Int {
        switch level {
        case .empty: 0
        case .quiet: 12
        case .moderate: 37
        case .busy: 62
        case .veryBusy: 88
        }
    }

    static func summary(of reports: [CommunityCrowdReport], at now: Date) -> LiveCrowdSummary? {
        let recent = reports.filter { report in
            let age = now.timeIntervalSince(report.createdAt)
            return age >= -5 * 60 && age <= window // allow small clock differences
        }
        guard let newest = recent.map(\.createdAt).max() else { return nil }

        var weightedSum = 0.0
        var totalWeight = 0.0
        for report in recent {
            let age = max(0, now.timeIntervalSince(report.createdAt))
            let weight = pow(0.5, age / halfLife)
            weightedSum += Double(busyness(for: report.level)) * weight
            totalWeight += weight
        }
        let value = Int((weightedSum / totalWeight).rounded())
        return LiveCrowdSummary(busyness: value, reportCount: recent.count, newestReportAt: newest)
    }
}
