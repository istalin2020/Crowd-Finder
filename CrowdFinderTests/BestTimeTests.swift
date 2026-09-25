import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CrowdFinder

final class BestTimeDecodingTests: XCTestCase {

    func testDecodesForecastAnalysisList() throws {
        let response = try JSONDecoder().decode(BestTimeForecastResponse.self, from: Fixtures.forecastJSON())
        XCTAssertEqual(response.status, "OK")
        XCTAssertEqual(response.venueInfo?.venueID, "ven_test123")
        XCTAssertEqual(response.venueInfo?.venueTimezone, "Asia/Kolkata")
        XCTAssertEqual(response.dayWindows.count, 7)
        XCTAssertEqual(response.dayWindows[0]?.count, 24)
        XCTAssertEqual(response.dayWindows[3]?.first, 300)
    }

    func testDecodesAnalysisKeyedByDayAndDecimalValues() throws {
        let json = """
        {"status": "OK",
         "analysis": {"1": {"day_raw": [10.4, 20.6, "30"]}, "5": {"day_info": {"day_int": 5}, "day_raw": [1, 2]}},
         "venue_info": {"venue_id": "ven_1"}}
        """
        let response = try JSONDecoder().decode(BestTimeForecastResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.dayWindows[1], [10, 21, 30])
        XCTAssertEqual(response.dayWindows[5], [1, 2])
    }

    func testDecodesLiveResponse() throws {
        let response = try JSONDecoder().decode(BestTimeLiveResponse.self, from: Fixtures.liveJSON(available: true, live: 82))
        XCTAssertEqual(response.liveBusyness, 82)
        XCTAssertEqual(response.analysis?.venueForecastedBusyness?.value, 60)
        XCTAssertEqual(response.analysis?.venueLiveForecastedDelta?.value, 22)

        let unavailable = try JSONDecoder().decode(BestTimeLiveResponse.self, from: Fixtures.liveJSON(available: false, live: 82))
        XCTAssertNil(unavailable.liveBusyness)
    }

    func testErrorMessagesAsStringOrObject() throws {
        let plain = try JSONDecoder().decode(BestTimeEnvelope.self, from: Data(#"{"status":"error","message":"Venue not found"}"#.utf8))
        XCTAssertEqual(plain.message?.text, "Venue not found")

        let object = try JSONDecoder().decode(
            BestTimeEnvelope.self,
            from: Data(#"{"status":"error","message":{"api_key_private":["Invalid private API key"]}}"#.utf8)
        )
        XCTAssertEqual(object.message?.text, "Invalid private API key")
    }

    func testErrorClassification() {
        XCTAssertTrue(BestTimeError.api(message: "Venue not found").isVenueSpecific)
        XCTAssertFalse(BestTimeError.api(message: "Invalid private API key").isVenueSpecific)
        XCTAssertTrue(BestTimeError.api(message: "Not enough credits").isAccountProblem)
        XCTAssertTrue(BestTimeError.http(status: 401).isAccountProblem)
        XCTAssertFalse(BestTimeError.http(status: 500).isAccountProblem)
    }
}

final class BestTimeClientTests: XCTestCase {

    func testForecastRequestUsesPOSTAndEncodesPlusSigns() throws {
        let client = BestTimeClient(apiKeyPrivate: "pri_abc")
        let request = client.makeRequest(path: "forecasts", query: [
            ("api_key_private", "pri_abc"),
            ("venue_name", "Café & Bar"),
            ("venue_address", "7JWV+8X Chennai, Tamil Nadu"),
        ])
        XCTAssertEqual(request.httpMethod, "POST")
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.hasPrefix("https://besttime.app/api/v1/forecasts?"), url)
        XCTAssertTrue(url.contains("7JWV%2B8X"), url)
        XCTAssertTrue(url.contains("Caf%C3%A9%20%26%20Bar"), url)
        XCTAssertFalse(url.contains("+"), url)
    }
}

final class CrowdServiceTests: XCTestCase {

    private let place = Place(
        id: "google-place-1",
        name: "Test Mall",
        address: "1 Test Road, Chennai",
        coordinate: Coordinate(latitude: 13.08, longitude: 80.27),
        types: ["shopping_mall"],
        userRatingCount: 1_000,
        utcOffsetMinutes: 330
    )
    /// Thursday 2024-01-04 06:30 UTC = 12:00 in India.
    private let thursdayNoonIndia = Date(timeIntervalSince1970: 1_704_349_800)

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testWithoutKeyUsesEstimate() async {
        let service = CrowdService(bestTime: nil, cache: ForecastCache(fileURL: nil))
        let report = await service.report(for: place, at: thursdayNoonIndia)
        XCTAssertEqual(report.source, .estimate)
        XCTAssertNotNil(report.forecast)
        XCTAssertFalse(service.usesRealData)
    }

    func testForecastIsFetchedOnceThenCached() async throws {
        StubURLProtocol.respond { request in
            XCTAssertEqual(request.url?.path, "/api/v1/forecasts")
            return (200, Fixtures.forecastJSON())
        }
        let service = CrowdService(bestTime: Self.client(), cache: ForecastCache(fileURL: nil))

        let first = await service.report(for: place, at: thursdayNoonIndia)
        XCTAssertEqual(first.source, .forecast)
        XCTAssertEqual(first.venueID, "ven_test123")
        XCTAssertEqual(first.timeZone.identifier, "Asia/Kolkata")
        // Thursday (day 3) window at 12:00 → index 6 → 300 + 6.
        XCTAssertEqual(first.currentBusyness, 306)

        let second = await service.report(for: place, at: thursdayNoonIndia.addingTimeInterval(3600))
        XCTAssertEqual(second.source, .forecast)
        XCTAssertEqual(second.currentBusyness, 307)
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "The second report must come from the cache")
    }

    func testUnknownVenueFallsBackToEstimateAndIsRemembered() async {
        StubURLProtocol.respond { _ in (404, Data(#"{"status":"error","message":"Venue not found"}"#.utf8)) }
        let service = CrowdService(bestTime: Self.client(), cache: ForecastCache(fileURL: nil))

        let report = await service.report(for: place, at: thursdayNoonIndia)
        XCTAssertEqual(report.source, .estimate)
        XCTAssertEqual(report.note, "BestTime: Venue not found")

        _ = await service.report(for: place, at: thursdayNoonIndia)
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "A venue without data must not be requested again right away")
        let problem = await service.accountProblem
        XCTAssertNil(problem)
    }

    func testInvalidKeyIsReportedAsAccountProblem() async {
        StubURLProtocol.respond { _ in
            (401, Data(#"{"status":"error","message":{"api_key_private":["Invalid private API key"]}}"#.utf8))
        }
        let service = CrowdService(bestTime: Self.client(), cache: ForecastCache(fileURL: nil))
        let report = await service.report(for: place, at: thursdayNoonIndia)
        XCTAssertEqual(report.source, .estimate)
        let problem = await service.accountProblem
        XCTAssertEqual(problem, "Invalid private API key")
    }

    func testOfflineModeDoesNotSpendCredits() async {
        StubURLProtocol.respond { _ in (200, Fixtures.forecastJSON()) }
        let service = CrowdService(bestTime: Self.client(), cache: ForecastCache(fileURL: nil))
        let report = await service.report(for: place, at: thursdayNoonIndia, allowNetwork: false)
        XCTAssertEqual(report.source, .estimate)
        XCTAssertNotNil(report.note)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testLiveReportUsesVenueIDAndLiveValue() async throws {
        StubURLProtocol.respond { request in
            if request.url?.path == "/api/v1/forecasts/live" {
                let query = request.url?.query ?? ""
                XCTAssertTrue(query.contains("venue_id=ven_test123"), query)
                return (200, Fixtures.liveJSON(available: true, live: 82))
            }
            return (200, Fixtures.forecastJSON())
        }
        let service = CrowdService(bestTime: Self.client(), cache: ForecastCache(fileURL: nil))
        let report = await service.liveReport(for: place, at: thursdayNoonIndia)

        XCTAssertEqual(report.source, .live)
        XCTAssertEqual(report.currentBusyness, 82)
        XCTAssertEqual(report.usualBusyness, 60)
        XCTAssertEqual(report.liveDelta, 22)
        XCTAssertNotNil(report.forecast, "The weekly forecast is kept for the hourly chart")
        XCTAssertEqual(report.busyness(hoursAfter: thursdayNoonIndia, offset: 1), 307)
    }

    func testLiveUnavailableKeepsForecast() async {
        StubURLProtocol.respond { request in
            request.url?.path == "/api/v1/forecasts/live"
                ? (200, Fixtures.liveJSON(available: false, live: 0))
                : (200, Fixtures.forecastJSON())
        }
        let service = CrowdService(bestTime: Self.client(), cache: ForecastCache(fileURL: nil))
        let report = await service.liveReport(for: place, at: thursdayNoonIndia)
        XCTAssertEqual(report.source, .forecast)
        XCTAssertEqual(report.currentBusyness, 306)
        XCTAssertNotNil(report.note)
    }

    func testCacheSurvivesOnDisk() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cf-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = CachedVenueForecast(
            venueID: "ven_1",
            forecast: WeeklyForecast(dayWindows: [0: Array(1...24)]),
            timeZoneIdentifier: "Europe/Paris",
            fetchedAt: thursdayNoonIndia
        )
        await ForecastCache(fileURL: url).store(entry, for: "p1")

        let reloaded = await ForecastCache(fileURL: url).forecast(for: "p1", now: thursdayNoonIndia)
        XCTAssertEqual(reloaded, entry)
        let expired = await ForecastCache(fileURL: url).forecast(for: "p1", now: thursdayNoonIndia.addingTimeInterval(8 * 24 * 3600))
        XCTAssertNil(expired)
    }

    private static func client() -> BestTimeClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return BestTimeClient(apiKeyPrivate: "pri_test", session: URLSession(configuration: configuration))
    }
}

// MARK: - Test helpers

enum Fixtures {
    /// A forecast shaped like BestTime's `POST /forecasts` response.
    /// `day_raw` for day d holds d*100 + index, so every value identifies its day and hour.
    static func forecastJSON() -> Data {
        let days: [[String: Any]] = (0..<7).map { day in
            [
                "day_info": ["day_int": day, "day_text": "Day \(day)", "day_max": 100],
                "busy_hours": [18, 19],
                "quiet_hours": [6, 7],
                "day_raw": (0..<24).map { day * 100 + $0 },
            ]
        }
        let object: [String: Any] = [
            "status": "OK",
            "analysis": days,
            "venue_info": [
                "venue_id": "ven_test123",
                "venue_name": "Test Mall",
                "venue_address": "1 Test Road, Chennai",
                "venue_timezone": "Asia/Kolkata",
                "venue_dwell_time_min": 30,
            ],
            "epoch_analysis": 1_704_349_800,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// A response shaped like BestTime's `POST /forecasts/live`.
    static func liveJSON(available: Bool, live: Int) -> Data {
        let object: [String: Any] = [
            "status": "OK",
            "analysis": [
                "venue_forecasted_busyness": 60,
                "venue_live_busyness": live,
                "venue_live_busyness_available": available,
                "venue_forecast_busyness_available": true,
                "venue_live_forecasted_delta": live - 60,
                "hour_start_12": "12PM",
                "hour_end_12": "1PM",
            ],
            "venue_info": ["venue_id": "ven_test123", "venue_timezone": "Asia/Kolkata"],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }
}

/// Intercepts URLSession requests in tests.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, Data))?
    private static var count = 0

    static func respond(_ handler: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        count = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let handler = Self.handler
        Self.lock.unlock()

        let (status, data) = handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
