import XCTest
@testable import CrowdFinder

final class CrowdEstimatorTests: XCTestCase {
    private let estimator = CrowdEstimator()

    private func place(_ types: [String], reviews: Int? = 5_000) -> Place {
        Place(
            id: "p-\(types.joined())",
            name: "Test",
            address: "Somewhere",
            coordinate: Coordinate(latitude: 0, longitude: 0),
            types: types,
            userRatingCount: reviews
        )
    }

    private func value(_ forecast: WeeklyForecast, _ weekday: Int, _ hour: Int) -> Int {
        forecast.busyness(at: LocalHour(weekday: weekday, hour: hour))
    }

    /// One real Google type per category.
    private let sampleTypes: [PlaceCategory: String] = [
        .restaurant: "restaurant", .cafe: "cafe", .nightlife: "bar", .shopping: "shopping_mall",
        .grocery: "supermarket", .attraction: "museum", .park: "park", .transit: "train_station",
        .airport: "airport", .worship: "hindu_temple", .fitness: "gym", .health: "hospital",
        .education: "university", .entertainment: "movie_theater", .services: "bank",
        .lodging: "hotel", .other: "point_of_interest",
    ]

    func testEveryCategoryStaysWithinRangeAndReachesItsCap() {
        XCTAssertEqual(sampleTypes.count, PlaceCategory.allCases.count)
        for category in PlaceCategory.allCases {
            let profile = CrowdEstimator.profile(for: category)
            XCTAssertEqual(profile.hours.count, 24, "\(category)")
            XCTAssertEqual(profile.dayFactors.count, 7, "\(category)")

            let testPlace = place([sampleTypes[category]!], reviews: 100_000)
            XCTAssertEqual(testPlace.category, category)
            let forecast = estimator.forecast(for: testPlace)
            let values = forecast.hourly.flatMap { $0 }
            XCTAssertEqual(values.count, 7 * 24)
            XCTAssertTrue(values.allSatisfy { (0...100).contains($0) }, "\(category)")
            XCTAssertEqual(values.max(), 100, "\(category) should peak at 100 % for a very popular place")
        }
    }

    func testPeakCapGrowsWithPopularity() {
        XCTAssertEqual(CrowdEstimator.peakCap(userRatingCount: nil), 85)
        XCTAssertEqual(CrowdEstimator.peakCap(userRatingCount: 0), 60)
        XCTAssertEqual(CrowdEstimator.peakCap(userRatingCount: 1_000), 88)
        XCTAssertEqual(CrowdEstimator.peakCap(userRatingCount: 1_000_000), 100)

        let small = estimator.forecast(for: place(["cafe"], reviews: 12)).hourly.flatMap { $0 }.max() ?? 0
        let famous = estimator.forecast(for: place(["cafe"], reviews: 40_000)).hourly.flatMap { $0 }.max() ?? 0
        XCTAssertLessThan(small, famous)
    }

    func testTransitPeaksAtRushHourOnWeekdays() {
        let forecast = estimator.forecast(for: place(["train_station"]))
        XCTAssertGreaterThan(value(forecast, 1, 8), value(forecast, 1, 14))
        XCTAssertGreaterThan(value(forecast, 1, 18), value(forecast, 1, 11))
        XCTAssertGreaterThan(value(forecast, 1, 8), value(forecast, 6, 8), "Weekday rush beats Sunday morning")
    }

    func testNightlifeIsBusiestLateOnWeekends() {
        let forecast = estimator.forecast(for: place(["night_club"]))
        XCTAssertGreaterThan(value(forecast, 5, 23), value(forecast, 0, 23), "Saturday night beats Monday night")
        XCTAssertGreaterThan(value(forecast, 5, 23), value(forecast, 5, 14))
        // 1 AM on Saturday is Friday night – busier than 1 AM on Tuesday (Monday night).
        XCTAssertGreaterThan(value(forecast, 5, 1), value(forecast, 1, 1))
    }

    func testAttractionsAreBusierOnWeekends() {
        let forecast = estimator.forecast(for: place(["tourist_attraction"]))
        XCTAssertGreaterThan(value(forecast, 6, 13), value(forecast, 2, 13))
        XCTAssertEqual(value(forecast, 2, 3), 0, "Closed in the middle of the night")
    }

    func testChurchIsBusiestOnSundayAndMosqueOnFriday() {
        let church = estimator.forecast(for: place(["church", "place_of_worship"]))
        XCTAssertGreaterThan(value(church, 6, 7), value(church, 2, 7))

        let mosque = estimator.forecast(for: place(["mosque", "place_of_worship"]))
        XCTAssertGreaterThan(value(mosque, 4, 18), value(mosque, 2, 18))
    }

    func testEstimateIsDeterministicAndUsesPlaceTimeZone() {
        let paris = Place(
            id: "eiffel", name: "Eiffel Tower", address: "Paris",
            coordinate: Coordinate(latitude: 48.858, longitude: 2.294),
            types: ["tourist_attraction"], userRatingCount: 400_000, utcOffsetMinutes: 60
        )
        // Monday 2024-01-01 12:00 UTC = 13:00 in Paris (winter).
        let date = Date(timeIntervalSince1970: 1_704_110_400)
        let report = estimator.report(for: paris, at: date)
        XCTAssertEqual(report.source, .estimate)
        XCTAssertEqual(report.timeZone.secondsFromGMT(), 3600)
        XCTAssertEqual(report.currentBusyness, report.forecast?.busyness(at: LocalHour(weekday: 0, hour: 13)))
        XCTAssertEqual(report, estimator.report(for: paris, at: date))
    }
}
