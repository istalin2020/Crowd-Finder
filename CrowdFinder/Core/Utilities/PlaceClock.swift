import Foundation

/// Local weekday and hour at a place.
struct LocalHour: Hashable, Sendable {
    /// ISO-style weekday: 0 = Monday … 6 = Sunday (the same convention BestTime uses).
    let weekday: Int
    /// Clock hour, 0 … 23.
    let hour: Int
}

/// Converts dates to the local time *of the place*, not of the phone.
///
/// This matters when someone in Chennai checks how busy the Eiffel Tower is right now:
/// we must look at the Paris hour, not the Chennai hour.
struct PlaceClock: Sendable {
    let timeZone: TimeZone

    /// Picks the most accurate time zone available:
    /// 1. an IANA identifier (handles daylight saving time correctly),
    /// 2. the current UTC offset reported by Google Places,
    /// 3. the phone's own time zone.
    init(timeZoneIdentifier: String? = nil, utcOffsetMinutes: Int? = nil, fallback: TimeZone = .current) {
        if let identifier = timeZoneIdentifier, let zone = TimeZone(identifier: identifier) {
            timeZone = zone
        } else if let minutes = utcOffsetMinutes, let zone = TimeZone(secondsFromGMT: minutes * 60) {
            timeZone = zone
        } else {
            timeZone = fallback
        }
    }

    init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    func localHour(at date: Date) -> LocalHour {
        let components = calendar.dateComponents([.weekday, .hour], from: date)
        // Calendar weekday: 1 = Sunday … 7 = Saturday. Convert to 0 = Monday … 6 = Sunday.
        let weekday = ((components.weekday ?? 2) + 5) % 7
        return LocalHour(weekday: weekday, hour: components.hour ?? 0)
    }

    /// Local hour `offset` hours after `date`.
    func localHour(hoursAfter date: Date, offset: Int) -> LocalHour {
        localHour(at: date.addingTimeInterval(TimeInterval(offset) * 3600))
    }

    /// Hour of the day (0…23) and minutes, e.g. to show "Local time 18:05".
    func localTimeString(at date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// True when the place's time zone differs from the phone's at `date`.
    func differsFromDevice(at date: Date, device: TimeZone = .current) -> Bool {
        timeZone.secondsFromGMT(for: date) != device.secondsFromGMT(for: date)
    }
}

enum HourFormatter {
    /// Formats a clock hour as "6 AM", "12 PM", "11 PM" (or "18:00" style for 24-hour locales).
    static func string(for hour: Int, locale: Locale = .current) -> String {
        var components = DateComponents()
        components.year = 2024
        components.month = 1
        components.day = 1
        components.hour = ((hour % 24) + 24) % 24
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: components) else { return "\(hour):00" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter.string(from: date)
    }

    /// Weekday name for 0 = Monday … 6 = Sunday.
    static func weekdayName(_ weekday: Int, short: Bool = false, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = short ? calendar.shortWeekdaySymbols : calendar.weekdaySymbols
        // Calendar symbols start at Sunday.
        return symbols[(weekday + 1) % 7]
    }
}
