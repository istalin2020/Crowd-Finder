import XCTest
@testable import CrowdFinder

final class VisitAdviceTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    /// Monday 2024-01-01 12:00 UTC.
    private let mondayNoon = Date(timeIntervalSince1970: 1_704_110_400)

    /// Builds a Monday forecast from clock-hour values (6 AM … 5 AM window order).
    private func report(window: [Int], liveNow: Int? = nil) -> CrowdReport {
        let forecast = WeeklyForecast(dayWindows: [0: window])
        let base = CrowdReport(placeID: "p", source: .forecast, forecast: forecast, timeZone: utc, at: mondayNoon)
        guard let liveNow else { return base }
        return CrowdReport(
            placeID: "p", source: .live, currentBusyness: liveNow, usualBusyness: base.currentBusyness,
            forecast: forecast, timeZone: utc, generatedAt: mondayNoon
        )
    }

    private func window(_ values: [Int: Int], default fill: Int = 0) -> [Int] {
        (0..<24).map { index in values[(index + 6) % 24] ?? fill }
    }

    func testQuietNowMeansGo() {
        let advice = VisitAdvice(report: report(window: window([12: 20, 13: 30, 19: 90])), at: mondayNoon)
        XCTAssertEqual(advice.verdict, .goNow)
        XCTAssertTrue(advice.detail.contains("busier later"), advice.detail)
    }

    func testBusyNowButQuieterLater() {
        let advice = VisitAdvice(report: report(window: window([12: 90, 13: 85, 15: 30, 16: 45, 20: 70])), at: mondayNoon)
        XCTAssertEqual(advice.verdict, .goLater(hour: 15, busyness: 30))
    }

    func testLiveValueDrivesTheVerdict() {
        // The forecast says quiet, but live data says it's packed right now.
        let advice = VisitAdvice(report: report(window: window([12: 20, 14: 25, 15: 22]), liveNow: 95), at: mondayNoon)
        XCTAssertEqual(advice.verdict, .goLater(hour: 15, busyness: 22))
    }

    func testBusyAllDay() {
        let advice = VisitAdvice(report: report(window: window([:], default: 85)), at: mondayNoon)
        XCTAssertEqual(advice.verdict, .expectCrowds)
    }

    func testClosedNow() {
        let advice = VisitAdvice(report: report(window: window([17: 40, 18: 60])), at: mondayNoon)
        XCTAssertEqual(advice.verdict, .closedNow)
        XCTAssertFalse(advice.detail.contains("No visitors"), advice.detail)
    }
}

final class PlaceTests: XCTestCase {

    private func place(_ types: [String]) -> Place {
        Place(id: "x", name: "X", address: "", coordinate: Coordinate(latitude: 0, longitude: 0), types: types)
    }

    func testAreasAreDetected() {
        XCTAssertTrue(place(["locality", "political"]).isArea)
        XCTAssertTrue(place(["country", "political"]).isArea)
        XCTAssertFalse(place(["tourist_attraction", "point_of_interest", "establishment"]).isArea)
        XCTAssertFalse(place(["park", "point_of_interest", "establishment", "sublocality"]).isArea)
        XCTAssertEqual(place(["locality", "political"]).suggestedZoom, 11.5)
        XCTAssertEqual(place(["museum", "point_of_interest"]).suggestedZoom, 16)
    }

    func testDistance() {
        let chennai = Coordinate(latitude: 13.0827, longitude: 80.2707)
        let bengaluru = Coordinate(latitude: 12.9716, longitude: 77.5946)
        XCTAssertEqual(chennai.distance(to: bengaluru) / 1000, 290, accuracy: 5)
    }

    func testGoogleMapsLinks() {
        let tower = Place(
            id: "ChIJLU7jZClu5kcR4PcOOO6p3I0", name: "Eiffel Tower", address: "Paris",
            coordinate: Coordinate(latitude: 48.8584, longitude: 2.2945)
        )
        XCTAssertEqual(
            GoogleMapsLinks.place(tower).absoluteString,
            "https://www.google.com/maps/search/?api=1&query=48.8584,2.2945&query_place_id=ChIJLU7jZClu5kcR4PcOOO6p3I0"
        )
        XCTAssertEqual(
            GoogleMapsLinks.directions(to: tower).absoluteString,
            "https://www.google.com/maps/dir/?api=1&destination=48.8584,2.2945&destination_place_id=ChIJLU7jZClu5kcR4PcOOO6p3I0"
        )
    }
}
