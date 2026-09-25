import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal client for the BestTime.app foot-traffic API (https://besttime.app).
///
/// Endpoints used (all inputs are query parameters, as in BestTime's official examples):
/// - `POST /api/v1/forecasts`      – weekly foot-traffic forecast for a venue (name + address).
/// - `POST /api/v1/forecasts/live` – live busyness right now vs. the forecast for this hour.
///
/// BestTime percentages are relative to the venue's busiest hour of the week (100 %).
/// Each day in `day_raw` runs from 6 AM until 5 AM the next morning, and `day_int`
/// uses 0 = Monday … 6 = Sunday.
struct BestTimeClient: Sendable {
    static let baseURL = URL(string: "https://besttime.app/api/v1")!

    let apiKeyPrivate: String
    let session: URLSession

    init(apiKeyPrivate: String, session: URLSession = .shared) {
        self.apiKeyPrivate = apiKeyPrivate
        self.session = session
    }

    /// Creates (or refreshes) the weekly forecast for a venue. Uses BestTime credits.
    func newForecast(venueName: String, venueAddress: String) async throws -> BestTimeForecastResponse {
        let request = makeRequest(path: "forecasts", query: [
            ("api_key_private", apiKeyPrivate),
            ("venue_name", venueName),
            ("venue_address", venueAddress),
        ])
        return try await send(request)
    }

    /// Live busyness for a venue. Prefer `venueID` (from an earlier forecast) when known.
    func live(venueID: String?, venueName: String, venueAddress: String) async throws -> BestTimeLiveResponse {
        var query = [("api_key_private", apiKeyPrivate)]
        if let venueID, !venueID.isEmpty {
            query.append(("venue_id", venueID))
        } else {
            query.append(("venue_name", venueName))
            query.append(("venue_address", venueAddress))
        }
        return try await send(makeRequest(path: "forecasts/live", query: query))
    }

    func makeRequest(path: String, query: [(String, String)]) -> URLRequest {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents leaves "+" as-is, but servers usually decode "+" as a space.
        // Addresses can contain "+" (for example Google Plus Codes like "7JWV+8X").
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45 // New forecasts can take a while to compute.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        let decoder = JSONDecoder()

        // BestTime reports problems as {"status": "error", "message": ...}.
        if let envelope = try? decoder.decode(BestTimeEnvelope.self, from: data),
           let status = envelope.status, status.uppercased() != "OK" {
            throw BestTimeError.api(message: envelope.message?.text ?? "BestTime returned status \"\(status)\".")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BestTimeError.http(status: http.statusCode)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw BestTimeError.invalidResponse
        }
    }
}

// MARK: - Errors

enum BestTimeError: LocalizedError, Equatable {
    case api(message: String)
    case http(status: Int)
    case invalidResponse
    case noForecastData

    var errorDescription: String? {
        switch self {
        case .api(let message): message
        case .http(let status): "BestTime request failed (HTTP \(status))."
        case .invalidResponse: "BestTime sent a response the app could not read."
        case .noForecastData: "BestTime has no foot-traffic data for this place yet."
        }
    }

    /// True when the problem is about this venue (not the key, credits or the network),
    /// so retrying the same venue soon would only waste credits.
    var isVenueSpecific: Bool {
        switch self {
        case .noForecastData:
            return true
        case .api(let message):
            let lowered = message.lowercased()
            let accountWords = ["key", "credit", "limit", "quota", "subscription", "unauthor"]
            return !accountWords.contains { lowered.contains($0) }
        case .http, .invalidResponse:
            return false
        }
    }

    /// True when the API key is missing, wrong or out of credits.
    var isAccountProblem: Bool {
        switch self {
        case .http(let status): status == 401 || status == 403
        case .api: !isVenueSpecific
        default: false
        }
    }
}

// MARK: - Response models

/// Status + message wrapper present on every BestTime response.
struct BestTimeEnvelope: Decodable {
    let status: String?
    let message: BestTimeMessage?
}

/// BestTime error messages are either a string or an object such as
/// `{"api_key_private": ["Invalid key"]}`.
struct BestTimeMessage: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
        } else if let lists = try? container.decode([String: [String]].self) {
            text = lists.sorted { $0.key < $1.key }.flatMap(\.value).joined(separator: " ")
        } else if let strings = try? container.decode([String: String].self) {
            text = strings.sorted { $0.key < $1.key }.map(\.value).joined(separator: " ")
        } else {
            text = "Unknown BestTime error."
        }
    }
}

struct BestTimeVenueInfo: Decodable, Sendable {
    let venueID: String?
    let venueName: String?
    let venueAddress: String?
    /// IANA time zone, e.g. "Asia/Kolkata".
    let venueTimezone: String?

    enum CodingKeys: String, CodingKey {
        case venueID = "venue_id"
        case venueName = "venue_name"
        case venueAddress = "venue_address"
        case venueTimezone = "venue_timezone"
    }
}

/// Response of `POST /forecasts`.
struct BestTimeForecastResponse: Decodable, Sendable {
    let status: String
    let venueInfo: BestTimeVenueInfo?
    /// `day_raw` per `day_int` (0 = Monday). Each array starts at 6 AM.
    let dayWindows: [Int: [Int]]

    enum CodingKeys: String, CodingKey {
        case status
        case venueInfo = "venue_info"
        case analysis
    }

    private struct DayAnalysis: Decodable {
        struct DayInfo: Decodable {
            let dayInt: LenientInt?
            enum CodingKeys: String, CodingKey { case dayInt = "day_int" }
        }

        let dayInfo: DayInfo?
        let dayRaw: [LenientInt]?

        enum CodingKeys: String, CodingKey {
            case dayInfo = "day_info"
            case dayRaw = "day_raw"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? container.decode(String.self, forKey: .status)) ?? ""
        venueInfo = try? container.decodeIfPresent(BestTimeVenueInfo.self, forKey: .venueInfo)

        var windows: [Int: [Int]] = [:]
        // `analysis` is a list sorted Monday → Sunday; accept a "0"…"6" keyed object too.
        if let days = try? container.decode([DayAnalysis].self, forKey: .analysis) {
            for (index, day) in days.enumerated() {
                windows[day.dayInfo?.dayInt?.value ?? index] = day.dayRaw?.map(\.value) ?? []
            }
        } else if let days = try? container.decode([String: DayAnalysis].self, forKey: .analysis) {
            for (key, day) in days {
                guard let dayInt = day.dayInfo?.dayInt?.value ?? Int(key) else { continue }
                windows[dayInt] = day.dayRaw?.map(\.value) ?? []
            }
        }
        dayWindows = windows
    }
}

/// Response of `POST /forecasts/live`.
struct BestTimeLiveResponse: Decodable, Sendable {
    struct Analysis: Decodable, Sendable {
        let venueLiveBusyness: LenientInt?
        let venueLiveBusynessAvailable: Bool?
        let venueForecastedBusyness: LenientInt?
        let venueLiveForecastedDelta: LenientInt?

        enum CodingKeys: String, CodingKey {
            case venueLiveBusyness = "venue_live_busyness"
            case venueLiveBusynessAvailable = "venue_live_busyness_available"
            case venueForecastedBusyness = "venue_forecasted_busyness"
            case venueLiveForecastedDelta = "venue_live_forecasted_delta"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            venueLiveBusyness = try? container.decodeIfPresent(LenientInt.self, forKey: .venueLiveBusyness)
            venueLiveBusynessAvailable = try? container.decodeIfPresent(Bool.self, forKey: .venueLiveBusynessAvailable)
            venueForecastedBusyness = try? container.decodeIfPresent(LenientInt.self, forKey: .venueForecastedBusyness)
            venueLiveForecastedDelta = try? container.decodeIfPresent(LenientInt.self, forKey: .venueLiveForecastedDelta)
        }
    }

    let status: String
    let analysis: Analysis?
    let venueInfo: BestTimeVenueInfo?

    enum CodingKeys: String, CodingKey {
        case status
        case analysis
        case venueInfo = "venue_info"
    }

    /// The live busyness, only when BestTime says live data is available.
    var liveBusyness: Int? {
        guard analysis?.venueLiveBusynessAvailable == true else { return nil }
        return analysis?.venueLiveBusyness?.value
    }
}

/// Decodes a number that may arrive as an integer, a decimal or a numeric string.
struct LenientInt: Decodable, Sendable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = Int(double.rounded())
        } else if let string = try? container.decode(String.self), let double = Double(string) {
            value = Int(double.rounded())
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a number")
        }
    }
}
