import XCTest
@testable import CrowdFinder

final class CrowdLevelTests: XCTestCase {

    func testThresholds() {
        XCTAssertEqual(CrowdLevel(busyness: 0), .empty)
        XCTAssertEqual(CrowdLevel(busyness: -5), .empty)
        XCTAssertEqual(CrowdLevel(busyness: 1), .quiet)
        XCTAssertEqual(CrowdLevel(busyness: 24), .quiet)
        XCTAssertEqual(CrowdLevel(busyness: 25), .moderate)
        XCTAssertEqual(CrowdLevel(busyness: 49), .moderate)
        XCTAssertEqual(CrowdLevel(busyness: 50), .busy)
        XCTAssertEqual(CrowdLevel(busyness: 74), .busy)
        XCTAssertEqual(CrowdLevel(busyness: 75), .veryBusy)
        XCTAssertEqual(CrowdLevel(busyness: 100), .veryBusy)
        // Live values can exceed 100 %.
        XCTAssertEqual(CrowdLevel(busyness: 140), .veryBusy)
    }

    func testLevelsAreOrdered() {
        XCTAssertLessThan(CrowdLevel.quiet, CrowdLevel.moderate)
        XCTAssertLessThan(CrowdLevel.busy, CrowdLevel.veryBusy)
        XCTAssertEqual(CrowdLevel.legendLevels, [.quiet, .moderate, .busy, .veryBusy])
    }

    func testEveryLevelHasAdvice() {
        for level in CrowdLevel.allCases {
            XCTAssertFalse(level.title.isEmpty)
            XCTAssertFalse(level.advice.isEmpty)
        }
    }
}

final class PlaceCategoryTests: XCTestCase {

    func testFirstMatchingGoogleTypeWins() {
        XCTAssertEqual(PlaceCategory(googleTypes: ["tourist_attraction", "restaurant", "point_of_interest"]), .attraction)
        XCTAssertEqual(PlaceCategory(googleTypes: ["point_of_interest", "establishment", "cafe"]), .cafe)
    }

    func testSpecificSubtypes() {
        XCTAssertEqual(PlaceCategory(googleTypes: ["south_indian_restaurant"]), .restaurant)
        XCTAssertEqual(PlaceCategory(googleTypes: ["electronics_store"]), .shopping)
        XCTAssertEqual(PlaceCategory(googleTypes: ["train_station"]), .transit)
        XCTAssertEqual(PlaceCategory(googleTypes: ["hindu_temple", "place_of_worship"]), .worship)
        XCTAssertEqual(PlaceCategory(googleTypes: ["beach"]), .park)
        XCTAssertEqual(PlaceCategory(googleTypes: ["night_club"]), .nightlife)
        XCTAssertEqual(PlaceCategory(googleTypes: ["international_airport"]), .airport)
    }

    func testUnknownTypesFallBackToOther() {
        XCTAssertEqual(PlaceCategory(googleTypes: []), .other)
        XCTAssertEqual(PlaceCategory(googleTypes: ["point_of_interest", "establishment"]), .other)
    }
}
