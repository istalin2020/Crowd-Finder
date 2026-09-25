import XCTest
@testable import CrowdFinder

final class WeeklyForecastTests: XCTestCase {

    /// A day window where index i holds the value (i + 1), i.e. 6 AM → 1, 7 AM → 2 … 5 AM → 24.
    private let countingWindow = Array(1...24)

    func testDayWindowStartsAtSixAM() {
        let forecast = WeeklyForecast(dayWindows: [0: countingWindow])

        // Monday 6 AM is the first value, Monday 11 PM is index 17.
        XCTAssertEqual(forecast.busyness(at: LocalHour(weekday: 0, hour: 6)), 1)
        XCTAssertEqual(forecast.busyness(at: LocalHour(weekday: 0, hour: 23)), 18)
        // 0 AM – 5 AM of Monday's window belong to Tuesday on the calendar.
        XCTAssertEqual(forecast.busyness(at: LocalHour(weekday: 1, hour: 0)), 19)
        XCTAssertEqual(forecast.busyness(at: LocalHour(weekday: 1, hour: 5)), 24)
        // Monday 0 AM – 5 AM come from Sunday's window, which is empty here.
        XCTAssertEqual(forecast.busyness(at: LocalHour(weekday: 0, hour: 3)), 0)
    }

    func testSundayWindowWrapsToMonday() {
        let forecast = WeeklyForecast(dayWindows: [6: countingWindow])
        XCTAssertEqual(forecast.busyness(at: LocalHour(weekday: 6, hour: 6)), 1)
        XCTAssertEqual(forecast.busyness(at: LocalHour(weekday: 0, hour: 2)), 21)
    }

    func testDayWindowRoundTrip() {
        var windows: [Int: [Int]] = [:]
        for day in 0..<7 { windows[day] = (0..<24).map { day * 100 + $0 } }
        let forecast = WeeklyForecast(dayWindows: windows)
        for day in 0..<7 {
            XCTAssertEqual(forecast.dayWindow(weekday: day).map(\.busyness), windows[day])
            XCTAssertEqual(forecast.dayWindow(weekday: day).first?.hour, 6)
            XCTAssertEqual(forecast.dayWindow(weekday: day).last?.hour, 5)
        }
    }

    func testDayWindowWeekdayForLateNightHours() {
        // 1 AM on Saturday still belongs to Friday night.
        XCTAssertEqual(WeeklyForecast.dayWindowWeekday(for: LocalHour(weekday: 5, hour: 1)), 4)
        XCTAssertEqual(WeeklyForecast.dayWindowWeekday(for: LocalHour(weekday: 0, hour: 4)), 6)
        XCTAssertEqual(WeeklyForecast.dayWindowWeekday(for: LocalHour(weekday: 2, hour: 6)), 2)
    }

    func testQuietestUpcomingHourIgnoresClosedHours() {
        // Open 10 AM – 9 PM, quietest open hour at 3 PM (index 9).
        var window = Array(repeating: 0, count: 24)
        for index in 4...15 { window[index] = 60 }
        window[9] = 15
        window[14] = 20
        let forecast = WeeklyForecast(dayWindows: [2: window])

        let fromMorning = forecast.quietestUpcomingHour(from: LocalHour(weekday: 2, hour: 11))
        XCTAssertEqual(fromMorning, HourValue(hour: 15, busyness: 15))

        // After 3 PM the next quietest open hour is 8 PM.
        let fromEvening = forecast.quietestUpcomingHour(from: LocalHour(weekday: 2, hour: 16))
        XCTAssertEqual(fromEvening, HourValue(hour: 20, busyness: 20))
    }

    func testPeakHour() {
        var window = Array(repeating: 10, count: 24)
        window[13] = 95 // 7 PM
        let forecast = WeeklyForecast(dayWindows: [4: window])
        XCTAssertEqual(forecast.peakHour(ofDayContaining: LocalHour(weekday: 4, hour: 9)), HourValue(hour: 19, busyness: 95))
        // At 2 AM on Saturday we are still in Friday's window.
        XCTAssertEqual(forecast.peakHour(ofDayContaining: LocalHour(weekday: 5, hour: 2))?.hour, 19)
    }

    func testMissingValuesAreZeroAndNegativeValuesClamped() {
        let forecast = WeeklyForecast(hourly: [[-10, 50]])
        XCTAssertEqual(forecast.busyness(at: LocalHour(weekday: 0, hour: 0)), 0)
        XCTAssertEqual(forecast.busyness(at: LocalHour(weekday: 0, hour: 1)), 50)
        XCTAssertEqual(forecast.busyness(at: LocalHour(weekday: 6, hour: 23)), 0)
        XCTAssertFalse(forecast.isEmpty)
        XCTAssertTrue(WeeklyForecast(hourly: []).isEmpty)
    }
}

final class PlaceClockTests: XCTestCase {

    /// Monday 2024-01-01 12:00:00 UTC.
    private let mondayNoonUTC = Date(timeIntervalSince1970: 1_704_110_400)

    func testUsesPlaceTimeZoneNotDeviceTimeZone() {
        let chennai = PlaceClock(timeZoneIdentifier: "Asia/Kolkata")
        XCTAssertEqual(chennai.localHour(at: mondayNoonUTC), LocalHour(weekday: 0, hour: 17))

        let newYork = PlaceClock(timeZoneIdentifier: "America/New_York")
        XCTAssertEqual(newYork.localHour(at: mondayNoonUTC), LocalHour(weekday: 0, hour: 7))

        let tokyo = PlaceClock(utcOffsetMinutes: 9 * 60)
        XCTAssertEqual(tokyo.localHour(at: mondayNoonUTC), LocalHour(weekday: 0, hour: 21))
    }

    func testWeekdayCrossesMidnight() {
        let auckland = PlaceClock(timeZoneIdentifier: "Pacific/Auckland") // UTC+13 in January
        XCTAssertEqual(auckland.localHour(at: mondayNoonUTC), LocalHour(weekday: 1, hour: 1))

        // Sunday 2023-12-31 20:00 UTC.
        let sundayEvening = mondayNoonUTC.addingTimeInterval(-16 * 3600)
        XCTAssertEqual(PlaceClock(utcOffsetMinutes: 0).localHour(at: sundayEvening), LocalHour(weekday: 6, hour: 20))
    }

    func testIdentifierWinsOverOffsetAndInvalidIdentifierFallsBack() {
        let clock = PlaceClock(timeZoneIdentifier: "Europe/Paris", utcOffsetMinutes: 330)
        XCTAssertEqual(clock.timeZone.identifier, "Europe/Paris")

        let fallback = PlaceClock(timeZoneIdentifier: "Not/AZone", utcOffsetMinutes: 330)
        XCTAssertEqual(fallback.timeZone.secondsFromGMT(), 330 * 60)
    }

    func testHourOffset() {
        let clock = PlaceClock(utcOffsetMinutes: 0)
        XCTAssertEqual(clock.localHour(hoursAfter: mondayNoonUTC, offset: 13), LocalHour(weekday: 1, hour: 1))
    }
}
