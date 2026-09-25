import Foundation

/// Offline crowd estimate used when real foot-traffic data is not available.
///
/// How it works:
/// 1. Each place category has a typical hour-by-hour shape (for example, restaurants peak at
///    lunch and dinner, transit peaks at rush hour, bars peak late at night).
/// 2. A weekday factor makes weekends busier for leisure places and quieter for offices.
/// 3. The week is scaled so the busiest hour equals a "peak cap" that grows with the number
///    of Google reviews – a small local shop rarely gets as packed as a famous landmark.
///
/// The result is clearly labelled as an **estimate** in the app. It is a helpful guide,
/// not a measurement.
struct CrowdEstimator: Sendable {

    func forecast(for place: Place) -> WeeklyForecast {
        let profile = Self.profile(for: place)
        let cap = Double(Self.peakCap(userRatingCount: place.userRatingCount))

        // Raw week, stored by clock day/hour.
        var raw = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        for day in 0..<7 {
            for hour in 0..<24 {
                // Hours before 6 AM belong to the previous evening (e.g. Friday night at 1 AM Saturday).
                let businessDay = WeeklyForecast.dayWindowWeekday(for: LocalHour(weekday: day, hour: hour))
                var value = profile.hours[hour]
                if businessDay >= 5, profile.weekendFlattening > 0 {
                    value = value * (1 - profile.weekendFlattening) + profile.mean * profile.weekendFlattening
                }
                raw[day][hour] = value * profile.dayFactors[businessDay]
            }
        }

        let weekMax = raw.flatMap { $0 }.max() ?? 0
        guard weekMax > 0 else { return WeeklyForecast(hourly: []) }
        let hourly = raw.map { day in day.map { Int(($0 / weekMax * cap).rounded()) } }
        return WeeklyForecast(hourly: hourly)
    }

    func report(for place: Place, at date: Date, note: String? = nil) -> CrowdReport {
        CrowdReport(
            placeID: place.id,
            source: .estimate,
            forecast: forecast(for: place),
            timeZone: PlaceClock(utcOffsetMinutes: place.utcOffsetMinutes).timeZone,
            at: date,
            note: note
        )
    }

    /// Busiest-hour value for a place, based on its number of Google reviews.
    static func peakCap(userRatingCount: Int?) -> Int {
        guard let count = userRatingCount, count >= 0 else { return 85 }
        let cap = 55 + 11 * log10(Double(count) + 1)
        return Int(min(100, max(60, cap)).rounded())
    }

    // MARK: - Typical patterns

    struct Profile: Sendable {
        /// Relative busyness for each clock hour 0 … 23.
        let hours: [Double]
        /// Multiplier per weekday, 0 = Monday … 6 = Sunday.
        let dayFactors: [Double]
        /// 0 … 1. How much weekend days lose their weekday rush-hour shape.
        var weekendFlattening: Double = 0

        var mean: Double { hours.reduce(0, +) / Double(hours.count) }
    }

    static func profile(for place: Place) -> Profile {
        let base = profile(for: place.category)
        guard place.category == .worship else { return base }
        // Weekly services make some places of worship much busier on one day.
        var factors = base.dayFactors
        if place.types.contains("church") { factors[6] = 1.5 }
        if place.types.contains("mosque") { factors[4] = 1.5 }
        if place.types.contains("synagogue") { factors[4] = 1.2; factors[5] = 1.4 }
        return Profile(hours: base.hours, dayFactors: factors, weekendFlattening: base.weekendFlattening)
    }

    // swiftlint:disable line_length
    static func profile(for category: PlaceCategory) -> Profile {
        switch category {
        case .restaurant:
            Profile(hours: [10, 5, 0, 0, 0, 0, 5, 12, 20, 22, 22, 35, 65, 75, 55, 30, 25, 35, 55, 80, 90, 75, 45, 22],
                    dayFactors: [0.78, 0.78, 0.82, 0.88, 1.05, 1.2, 1.12])
        case .cafe:
            Profile(hours: [0, 0, 0, 0, 0, 0, 10, 35, 60, 70, 65, 55, 60, 62, 55, 58, 62, 55, 45, 35, 25, 15, 5, 0],
                    dayFactors: [0.9, 0.9, 0.9, 0.92, 0.98, 1.1, 1.05])
        case .nightlife:
            Profile(hours: [85, 65, 40, 15, 5, 0, 0, 0, 0, 0, 0, 5, 10, 12, 12, 15, 20, 28, 35, 45, 55, 68, 82, 90],
                    dayFactors: [0.45, 0.5, 0.62, 0.78, 1.15, 1.3, 0.7])
        case .shopping:
            Profile(hours: [0, 0, 0, 0, 0, 0, 0, 0, 5, 10, 20, 32, 42, 48, 50, 55, 64, 75, 85, 90, 80, 55, 25, 5],
                    dayFactors: [0.72, 0.72, 0.75, 0.8, 0.95, 1.3, 1.25])
        case .grocery:
            Profile(hours: [0, 0, 0, 0, 0, 0, 5, 15, 25, 35, 45, 50, 55, 50, 45, 50, 62, 80, 90, 78, 55, 30, 12, 3],
                    dayFactors: [0.85, 0.85, 0.85, 0.9, 1.0, 1.15, 1.05])
        case .attraction:
            Profile(hours: [0, 0, 0, 0, 0, 0, 0, 5, 12, 28, 50, 70, 80, 85, 85, 80, 72, 58, 40, 25, 15, 8, 3, 0],
                    dayFactors: [0.7, 0.72, 0.75, 0.8, 0.9, 1.3, 1.3])
        case .park:
            Profile(hours: [0, 0, 0, 0, 0, 12, 35, 45, 38, 28, 25, 24, 22, 22, 24, 32, 50, 72, 88, 78, 52, 28, 12, 4],
                    dayFactors: [0.75, 0.75, 0.78, 0.8, 0.88, 1.25, 1.35])
        case .transit:
            Profile(hours: [8, 4, 2, 2, 6, 18, 40, 72, 95, 85, 55, 45, 45, 48, 45, 50, 62, 85, 95, 78, 55, 40, 28, 15],
                    dayFactors: [1.0, 1.0, 1.0, 1.0, 1.0, 0.7, 0.6], weekendFlattening: 0.5)
        case .airport:
            Profile(hours: [30, 22, 18, 20, 35, 60, 78, 85, 82, 75, 70, 68, 65, 65, 68, 72, 78, 82, 85, 80, 72, 62, 50, 40],
                    dayFactors: [0.95, 0.85, 0.85, 0.95, 1.05, 0.9, 1.05])
        case .worship:
            Profile(hours: [0, 0, 0, 0, 0, 25, 55, 62, 55, 45, 40, 35, 30, 18, 15, 18, 28, 50, 72, 65, 40, 15, 4, 0],
                    dayFactors: [0.75, 0.75, 0.75, 0.8, 0.9, 1.05, 1.25])
        case .fitness:
            Profile(hours: [0, 0, 0, 0, 0, 25, 62, 80, 65, 42, 30, 26, 28, 25, 22, 28, 45, 75, 92, 85, 62, 35, 10, 0],
                    dayFactors: [1.05, 1.02, 1.0, 0.98, 0.85, 0.75, 0.7])
        case .health:
            Profile(hours: [12, 10, 8, 8, 8, 10, 18, 30, 48, 72, 88, 90, 80, 66, 70, 70, 64, 58, 50, 40, 30, 22, 18, 14],
                    dayFactors: [1.1, 1.0, 1.0, 1.0, 0.98, 0.75, 0.5])
        case .education:
            Profile(hours: [0, 0, 0, 0, 0, 0, 0, 25, 62, 82, 88, 88, 85, 75, 80, 78, 62, 42, 30, 20, 10, 0, 0, 0],
                    dayFactors: [1.0, 1.0, 1.0, 1.0, 0.95, 0.3, 0.2], weekendFlattening: 0.3)
        case .entertainment:
            Profile(hours: [12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 18, 25, 30, 34, 35, 40, 50, 65, 80, 88, 80, 60, 32],
                    dayFactors: [0.62, 0.62, 0.68, 0.75, 1.05, 1.3, 1.15])
        case .services:
            Profile(hours: [0, 0, 0, 0, 0, 0, 0, 0, 10, 42, 75, 88, 80, 62, 66, 70, 55, 30, 10, 0, 0, 0, 0, 0],
                    dayFactors: [1.1, 1.0, 1.0, 1.0, 1.0, 0.35, 0.1])
        case .lodging:
            Profile(hours: [40, 35, 30, 30, 30, 32, 45, 62, 70, 62, 52, 48, 48, 45, 50, 55, 58, 60, 65, 70, 72, 65, 55, 48],
                    dayFactors: [0.85, 0.85, 0.88, 0.9, 1.05, 1.15, 0.95])
        case .other:
            Profile(hours: [0, 0, 0, 0, 0, 0, 0, 8, 15, 25, 40, 50, 60, 60, 55, 55, 60, 70, 75, 70, 55, 35, 20, 10],
                    dayFactors: [0.8, 0.8, 0.85, 0.88, 1.0, 1.2, 1.15])
        }
    }
    // swiftlint:enable line_length
}
