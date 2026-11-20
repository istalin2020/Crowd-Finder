import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CrowdFinder

final class LiveCrowdAggregatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_763_661_000)

    private func report(_ level: CrowdLevel, minutesAgo: Double) -> CommunityCrowdReport {
        CommunityCrowdReport(level: level, createdAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    func testNoRecentReportsMeansNoLiveValue() {
        XCTAssertNil(LiveCrowdAggregator.summary(of: [], at: now))
        XCTAssertNil(LiveCrowdAggregator.summary(of: [report(.veryBusy, minutesAgo: 95)], at: now))
    }

    func testSingleVeryBusyReportBeatsTheUsualPattern() throws {
        let summary = try XCTUnwrap(LiveCrowdAggregator.summary(of: [report(.veryBusy, minutesAgo: 5)], at: now))
        XCTAssertEqual(summary.level, .veryBusy)
        XCTAssertEqual(summary.reportCount, 1)
    }

    func testNewerReportsCountMore() throws {
        // The crowd left: an old "very busy" and a fresh "quiet".
        let summary = try XCTUnwrap(LiveCrowdAggregator.summary(
            of: [report(.veryBusy, minutesAgo: 80), report(.quiet, minutesAgo: 2)], at: now
        ))
        XCTAssertLessThan(summary.busyness, 37)
        XCTAssertEqual(summary.reportCount, 2)
        XCTAssertEqual(summary.newestReportAt, now.addingTimeInterval(-120))
    }

    func testEqualAgesAverage() throws {
        let summary = try XCTUnwrap(LiveCrowdAggregator.summary(
            of: [report(.quiet, minutesAgo: 10), report(.veryBusy, minutesAgo: 10)], at: now
        ))
        XCTAssertEqual(summary.busyness, 50) // (12 + 88) / 2
    }

    func testOnlyReportableLevelsAreAccepted() {
        XCTAssertNil(CommunityCrowdReport(storedValue: 0, createdAt: now))
        XCTAssertNil(CommunityCrowdReport(storedValue: 9, createdAt: now))
        XCTAssertEqual(CommunityCrowdReport(storedValue: 4, createdAt: now)?.level, .veryBusy)
    }
}

final class CommunityReportsClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_763_661_000) // 2025-11-20T17:50:00Z

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testDocumentIDs() {
        XCTAssertEqual(CommunityReportsClient.documentID(for: "ChIJLU7jZClu5kcR4PcOOO6p3I0"), "ChIJLU7jZClu5kcR4PcOOO6p3I0")
        let apple = CommunityReportsClient.documentID(for: "apple:Al Khoud Dam@23.5,58.1")
        XCTAssertTrue(apple.hasPrefix("h"))
        XCTAssertFalse(apple.contains("/"))
        XCTAssertEqual(apple, CommunityReportsClient.documentID(for: "apple:Al Khoud Dam@23.5,58.1"), "Stable across calls")
    }

    func testParsesRunQueryWithNanosecondTimestamps() throws {
        let json = """
        [
          {"document": {"name": "projects/p/databases/(default)/documents/crowdPlaces/x/reports/a",
                        "fields": {"level": {"integerValue": "4"},
                                   "createdAt": {"timestampValue": "2025-11-20T17:45:03.123456789Z"}}},
           "readTime": "2025-11-20T17:50:00.000001Z"},
          {"document": {"fields": {"level": {"integerValue": "1"},
                                   "createdAt": {"timestampValue": "2025-11-20T17:30:00Z"}}}},
          {"document": {"fields": {"level": {"integerValue": "7"},
                                   "createdAt": {"timestampValue": "2025-11-20T17:30:00Z"}}}}
        ]
        """
        let reports = try CommunityReportsClient.parseRunQuery(Data(json.utf8))
        XCTAssertEqual(reports.count, 2, "Invalid level 7 is ignored")
        XCTAssertEqual(reports[0].level, .veryBusy)
        XCTAssertEqual(reports[0].createdAt.timeIntervalSince1970, 1_763_660_703.123, accuracy: 0.01)
        XCTAssertEqual(reports[1].level, .quiet)
    }

    func testEmptyRunQueryResult() throws {
        XCTAssertEqual(try CommunityReportsClient.parseRunQuery(Data(#"[{"readTime": "2025-11-20T17:50:00Z"}]"#.utf8)), [])
    }

    func testQueryRequestFormat() async throws {
        var captured: URLRequest?
        StubURLProtocol.respond { request in
            captured = request
            return (200, Data(#"[{"readTime": "2025-11-20T17:50:00Z"}]"#.utf8))
        }
        _ = try await Self.client().recentReports(placeID: "PLACE_1", since: now)

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://firestore.googleapis.com/v1/projects/demo-project/databases/(default)/documents/crowdPlaces/PLACE_1:runQuery"
        )
        let body = try XCTUnwrap(Self.jsonBody(of: request))
        let query = try XCTUnwrap(body["structuredQuery"] as? [String: Any])
        XCTAssertEqual((query["from"] as? [[String: Any]])?.first?["collectionId"] as? String, "reports")
        let filter = try XCTUnwrap((query["where"] as? [String: Any])?["fieldFilter"] as? [String: Any])
        XCTAssertEqual(filter["op"] as? String, "GREATER_THAN_OR_EQUAL")
        XCTAssertEqual((filter["value"] as? [String: Any])?["timestampValue"] as? String, "2025-11-20T17:50:00.000Z")
        XCTAssertEqual((query["orderBy"] as? [[String: Any]])?.first?["direction"] as? String, "DESCENDING")
    }

    func testSubmitUsesServerTimeAndCreateOnlyPrecondition() async throws {
        var captured: URLRequest?
        StubURLProtocol.respond { request in
            captured = request
            return (200, Data(#"{"writeResults": [{}], "commitTime": "2025-11-20T17:50:00Z"}"#.utf8))
        }
        try await Self.client().submit(level: .busy, placeID: "PLACE_1")

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://firestore.googleapis.com/v1/projects/demo-project/databases/(default)/documents:commit"
        )
        let body = try XCTUnwrap(Self.jsonBody(of: request))
        let write = try XCTUnwrap((body["writes"] as? [[String: Any]])?.first)
        let update = try XCTUnwrap(write["update"] as? [String: Any])
        XCTAssertTrue((update["name"] as? String)?.hasPrefix(
            "projects/demo-project/databases/(default)/documents/crowdPlaces/PLACE_1/reports/") == true)
        let level = (update["fields"] as? [String: Any])?["level"] as? [String: Any]
        XCTAssertEqual(level?["integerValue"] as? String, "3")
        let transform = (write["updateTransforms"] as? [[String: Any]])?.first
        XCTAssertEqual(transform?["fieldPath"] as? String, "createdAt")
        XCTAssertEqual(transform?["setToServerValue"] as? String, "REQUEST_TIME")
        XCTAssertEqual((write["currentDocument"] as? [String: Any])?["exists"] as? Bool, false)
    }

    func testFirestoreErrorMessageIsShown() async {
        StubURLProtocol.respond { _ in
            (403, Data(#"{"error": {"code": 403, "message": "Missing or insufficient permissions.", "status": "PERMISSION_DENIED"}}"#.utf8))
        }
        do {
            _ = try await Self.client().recentReports(placeID: "P", since: now)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? CommunityReportsError, .server(message: "Missing or insufficient permissions."))
        }
    }

    static func client() -> CommunityReportsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return CommunityReportsClient(projectID: "demo-project", session: URLSession(configuration: configuration))
    }

    /// URLSession may hand the body to URL protocols as a stream instead of `httpBody`.
    static func jsonBody(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            data = collected
        }
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

final class CrowdServiceLiveReportTests: XCTestCase {
    private let dam = Place(
        id: "DAM_1", name: "Al Khoud Dam", address: "Seeb, Oman",
        coordinate: Coordinate(latitude: 23.56, longitude: 58.17),
        types: ["tourist_attraction"], userRatingCount: 105, utcOffsetMinutes: 240
    )
    /// 2026-11-20 16:00 UTC = 20:00 in Oman.
    private let showTime = Date(timeIntervalSince1970: 1_795_190_400)

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func runQueryJSON(levels: [Int], minutesAgo: Int) -> Data {
        let created = CommunityReportsClient.timestampString(showTime.addingTimeInterval(TimeInterval(-minutesAgo * 60)))
        let items = levels.map { level in
            #"{"document": {"fields": {"level": {"integerValue": "\#(level)"}, "createdAt": {"timestampValue": "\#(created)"}}}}"#
        }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    func testVisitorReportsOverrideTheUsualPattern() async {
        StubURLProtocol.respond { _ in (200, self.runQueryJSON(levels: [4, 4, 3], minutesAgo: 5)) }
        let service = CrowdService(bestTime: nil, community: CommunityReportsClient.clientForTests(), cache: ForecastCache(fileURL: nil))

        let report = await service.report(for: dam, at: showTime)
        XCTAssertEqual(report.source, .community)
        XCTAssertEqual(report.liveSummary?.reportCount, 3)
        XCTAssertGreaterThanOrEqual(report.currentBusyness, 75, "A drone show crowd must show as very busy")
        XCTAssertNotNil(report.usualBusyness, "The usual value is kept for comparison")
        XCTAssertNotNil(report.forecast, "The hourly pattern is kept for the chart")
        XCTAssertEqual(report.patternSource, .estimate, "Future hours still come from the estimate")
    }

    func testNoReportsFallsBackToTheUsualPattern() async {
        StubURLProtocol.respond { _ in (200, Data(#"[{"readTime": "2026-11-20T16:00:00Z"}]"#.utf8)) }
        let service = CrowdService(bestTime: nil, community: CommunityReportsClient.clientForTests(), cache: ForecastCache(fileURL: nil))
        let report = await service.report(for: dam, at: showTime)
        XCTAssertEqual(report.source, .estimate)
        XCTAssertNil(report.liveSummary)
    }

    func testReportsAreCachedBriefly() async {
        StubURLProtocol.respond { _ in (200, self.runQueryJSON(levels: [2], minutesAgo: 1)) }
        let service = CrowdService(bestTime: nil, community: CommunityReportsClient.clientForTests(), cache: ForecastCache(fileURL: nil))
        _ = await service.report(for: dam, at: showTime)
        _ = await service.report(for: dam, at: showTime.addingTimeInterval(20))
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        _ = await service.report(for: dam, at: showTime.addingTimeInterval(60))
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "Refreshed after the cache interval")
    }

    func testSubmittedReportShowsImmediately() async throws {
        StubURLProtocol.respond { request in
            request.url?.absoluteString.hasSuffix(":commit") == true
                ? (200, Data(#"{"commitTime": "2026-11-20T16:00:00Z"}"#.utf8))
                : (200, Data(#"[{"readTime": "2026-11-20T16:00:00Z"}]"#.utf8)) // read is not yet consistent
        }
        let service = CrowdService(bestTime: nil, community: CommunityReportsClient.clientForTests(), cache: ForecastCache(fileURL: nil))
        let report = try await service.submitLiveReport(level: .veryBusy, for: dam, at: showTime)
        XCTAssertEqual(report.source, .community)
        XCTAssertEqual(report.level, .veryBusy)
    }

    func testDatabaseProblemIsReported() async {
        StubURLProtocol.respond { _ in
            (404, Data(#"{"error": {"code": 404, "message": "The database (default) does not exist.", "status": "NOT_FOUND"}}"#.utf8))
        }
        let service = CrowdService(bestTime: nil, community: CommunityReportsClient.clientForTests(), cache: ForecastCache(fileURL: nil))
        let report = await service.report(for: dam, at: showTime)
        XCTAssertEqual(report.source, .estimate)
        let problem = await service.communityProblem
        XCTAssertEqual(problem, "The database (default) does not exist.")
    }
}

extension CommunityReportsClient {
    static func clientForTests() -> CommunityReportsClient { CommunityReportsClientTests.client() }
}
