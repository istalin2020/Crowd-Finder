import Foundation

/// A week of hourly busyness percentages for one place.
///
/// Values are stored by *clock* hour: `hourly[weekday][hour]` where weekday is
/// 0 = Monday … 6 = Sunday and hour is 0 … 23 in the place's local time.
struct WeeklyForecast: Codable, Equatable, Sendable {
    static let hoursPerDay = 24
    static let daysPerWeek = 7

    /// BestTime and Google "Popular times" describe a day from 6 AM until 5 AM the next
    /// morning, so late-night hours belong to the evening before.
    static let dayWindowStartHour = 6

    private(set) var hourly: [[Int]]

    /// Creates a forecast from clock-hour values. Missing values are filled with 0.
    init(hourly: [[Int]]) {
        self.hourly = (0..<Self.daysPerWeek).map { day in
            let values = day < hourly.count ? hourly[day] : []
            return (0..<Self.hoursPerDay).map { hour in
                hour < values.count ? max(0, values[hour]) : 0
            }
        }
    }

    /// Creates a forecast from "day windows" (6 AM → 5 AM next day), the format BestTime returns.
    ///
    /// - Parameter windows: `windows[weekday]` holds 24 values; index 0 is 6 AM of that weekday
    ///   and index 23 is 5 AM of the following weekday.
    init(dayWindows windows: [Int: [Int]]) {
        var hourly = Array(repeating: Array(repeating: 0, count: Self.hoursPerDay), count: Self.daysPerWeek)
        for (weekday, values) in windows where (0..<Self.daysPerWeek).contains(weekday) {
            for (index, value) in values.prefix(Self.hoursPerDay).enumerated() {
                let clockHour = (index + Self.dayWindowStartHour) % Self.hoursPerDay
                // Hours after midnight (index 18…23 → 0 AM…5 AM) fall on the next calendar day.
                let clockDay = index < Self.hoursPerDay - Self.dayWindowStartHour
                    ? weekday
                    : (weekday + 1) % Self.daysPerWeek
                hourly[clockDay][clockHour] = max(0, value)
            }
        }
        self.init(hourly: hourly)
    }

    func busyness(at localHour: LocalHour) -> Int {
        hourly[localHour.weekday][localHour.hour]
    }

    /// The 24 hours of a "day window" starting at 6 AM, as `(clock hour, busyness)` pairs.
    func dayWindow(weekday: Int) -> [HourValue] {
        (0..<Self.hoursPerDay).map { index in
            let clockHour = (index + Self.dayWindowStartHour) % Self.hoursPerDay
            let clockDay = index < Self.hoursPerDay - Self.dayWindowStartHour
                ? weekday
                : (weekday + 1) % Self.daysPerWeek
            return HourValue(hour: clockHour, busyness: hourly[clockDay][clockHour])
        }
    }

    /// The weekday whose day window contains `localHour` (1 AM on Saturday belongs to Friday night).
    static func dayWindowWeekday(for localHour: LocalHour) -> Int {
        localHour.hour < dayWindowStartHour
            ? (localHour.weekday + daysPerWeek - 1) % daysPerWeek
            : localHour.weekday
    }

    /// The quietest *open* hour (busyness > 0) from `localHour` until the end of that day window.
    func quietestUpcomingHour(from localHour: LocalHour) -> HourValue? {
        upcomingHours(from: localHour)
            .filter { $0.busyness > 0 }
            .min { lhs, rhs in lhs.busyness < rhs.busyness }
    }

    /// The busiest hour of the day window that contains `localHour`.
    func peakHour(ofDayContaining localHour: LocalHour) -> HourValue? {
        dayWindow(weekday: Self.dayWindowWeekday(for: localHour))
            .filter { $0.busyness > 0 }
            .max { lhs, rhs in lhs.busyness < rhs.busyness }
    }

    /// The remaining hours of the current day window, starting at `localHour`.
    func upcomingHours(from localHour: LocalHour) -> [HourValue] {
        let window = dayWindow(weekday: Self.dayWindowWeekday(for: localHour))
        guard let start = window.firstIndex(where: { $0.hour == localHour.hour }) else { return window }
        return Array(window[start...])
    }

    /// True when every value is zero (no usable data).
    var isEmpty: Bool { hourly.allSatisfy { $0.allSatisfy { $0 == 0 } } }
}

/// One hour of a forecast.
struct HourValue: Hashable, Sendable {
    let hour: Int
    let busyness: Int
}
