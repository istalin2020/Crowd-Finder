import Foundation

/// Where a crowd number came from. Shown to the user so they know how much to trust it.
enum CrowdDataSource: String, Codable, Sendable {
    /// Live reports from people at the place in the last 90 minutes.
    case community
    /// Real-time foot traffic measured by BestTime right now.
    case live
    /// BestTime forecast for this hour, based on historical foot traffic.
    case forecast
    /// On-device estimate from typical patterns for this kind of place.
    case estimate

    var badgeTitle: String {
        switch self {
        case .community: "LIVE REPORTS"
        case .live: "LIVE"
        case .forecast: "FORECAST"
        case .estimate: "USUAL · NOT LIVE"
        }
    }

    var explanation: String {
        switch self {
        case .community: "Live reports from people who are at this place right now (last 90 minutes, newest count most)."
        case .live: "Live foot traffic from BestTime."
        case .forecast: "BestTime forecast for this hour, based on historical foot traffic. Not live: events are not included."
        case .estimate: "The usual crowd for this type of place at this hour – not a live count. Events such as shows or festivals are not included. Live reports from visitors replace it as soon as someone reports."
        }
    }

    /// True for sources that measure the crowd right now.
    var isLive: Bool { self == .community || self == .live }
}

/// Everything the app knows about the crowd at one place.
struct CrowdReport: Equatable, Sendable {
    let placeID: String
    /// Source of `currentBusyness`.
    let source: CrowdDataSource
    /// Busyness at `generatedAt` (0 … 100, live values may exceed 100).
    let currentBusyness: Int
    /// The forecast for this hour, when a live value is shown (to say "busier than usual").
    let usualBusyness: Int?
    /// Hour-by-hour pattern for the whole week, when available.
    let forecast: WeeklyForecast?
    /// Time zone of the place.
    let timeZone: TimeZone
    let generatedAt: Date
    /// BestTime venue ID, used for cheaper follow-up calls.
    let venueID: String?
    /// Optional note, e.g. why real data was not available.
    let note: String?
    /// Recent visitor reports, when any exist.
    let liveSummary: LiveCrowdSummary?
    /// Where the hour-by-hour pattern (future hours, chart) comes from: forecast or estimate.
    let patternSource: CrowdDataSource

    init(
        placeID: String,
        source: CrowdDataSource,
        currentBusyness: Int,
        usualBusyness: Int? = nil,
        forecast: WeeklyForecast?,
        timeZone: TimeZone,
        generatedAt: Date,
        venueID: String? = nil,
        note: String? = nil,
        liveSummary: LiveCrowdSummary? = nil,
        patternSource: CrowdDataSource? = nil
    ) {
        self.placeID = placeID
        self.source = source
        self.currentBusyness = max(0, currentBusyness)
        self.usualBusyness = usualBusyness
        self.forecast = forecast
        self.timeZone = timeZone
        self.generatedAt = generatedAt
        self.venueID = venueID
        self.note = note
        self.liveSummary = liveSummary
        self.patternSource = patternSource ?? (source.isLive ? .forecast : source)
    }

    /// Builds a report for "now" from a weekly forecast.
    init(
        placeID: String,
        source: CrowdDataSource,
        forecast: WeeklyForecast,
        timeZone: TimeZone,
        at date: Date,
        venueID: String? = nil,
        note: String? = nil
    ) {
        let localHour = PlaceClock(timeZone: timeZone).localHour(at: date)
        self.init(
            placeID: placeID,
            source: source,
            currentBusyness: forecast.busyness(at: localHour),
            forecast: forecast,
            timeZone: timeZone,
            generatedAt: date,
            venueID: venueID,
            note: note
        )
    }

    var clock: PlaceClock { PlaceClock(timeZone: timeZone) }

    var level: CrowdLevel { CrowdLevel(busyness: currentBusyness) }

    /// Busyness `hourOffset` hours after `date`.
    /// Offset 0 returns the current (possibly live) value; later hours come from the forecast.
    func busyness(hoursAfter date: Date, offset: Int) -> Int? {
        if offset == 0 { return currentBusyness }
        guard let forecast else { return nil }
        return forecast.busyness(at: clock.localHour(hoursAfter: date, offset: offset))
    }

    /// Difference between the live value and what is usual for this hour.
    var liveDelta: Int? {
        guard source.isLive, let usualBusyness else { return nil }
        return currentBusyness - usualBusyness
    }

    /// The quietest open hour from now until the end of today (in the place's local time).
    func quietestUpcomingHour(from date: Date) -> HourValue? {
        forecast?.quietestUpcomingHour(from: clock.localHour(at: date))
    }

    /// The busiest hour of today (in the place's local time).
    func peakHourToday(from date: Date) -> HourValue? {
        forecast?.peakHour(ofDayContaining: clock.localHour(at: date))
    }
}
