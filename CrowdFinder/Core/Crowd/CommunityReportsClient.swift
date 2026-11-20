import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shares live crowd reports between users through Google Cloud Firestore (REST API).
///
/// Data layout: `crowdPlaces/{placeID}/reports/{reportID}` with fields
/// `level` (1 quiet … 4 very busy) and `createdAt` (set by the server).
///
/// Requests are unauthenticated; the Firestore security rules in the README allow anyone
/// to read reports and to *create* a valid report, and nothing else.
/// Formats follow google/firestore/v1 (firestore.proto, query.proto, write.proto).
struct CommunityReportsClient: Sendable {
    static let collection = "crowdPlaces"
    static let subcollection = "reports"

    let projectID: String
    let session: URLSession

    init(projectID: String, session: URLSession = .shared) {
        self.projectID = projectID
        self.session = session
    }

    private var databasePath: String { "projects/\(projectID)/databases/(default)" }

    private var baseURL: String { "https://firestore.googleapis.com/v1/\(databasePath)/documents" }

    /// Reports for a place created at or after `since`, newest first.
    func recentReports(placeID: String, since: Date, limit: Int = 50) async throws -> [CommunityCrowdReport] {
        let parent = "\(Self.collection)/\(Self.documentID(for: placeID))"
        let body: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": Self.subcollection]],
                "where": [
                    "fieldFilter": [
                        "field": ["fieldPath": "createdAt"],
                        "op": "GREATER_THAN_OR_EQUAL",
                        "value": ["timestampValue": Self.timestampString(since)],
                    ],
                ],
                "orderBy": [["field": ["fieldPath": "createdAt"], "direction": "DESCENDING"]],
                "limit": limit,
            ],
        ]
        let data = try await post("\(baseURL)/\(parent):runQuery", body: body)
        return try Self.parseRunQuery(data)
    }

    /// Saves a report. The server sets `createdAt`, so times cannot be faked.
    func submit(level: CrowdLevel, placeID: String) async throws {
        guard CommunityCrowdReport.reportableLevels.contains(level) else { return }
        let name = "\(databasePath)/documents/\(Self.collection)/\(Self.documentID(for: placeID))/\(Self.subcollection)/\(UUID().uuidString)"
        let body: [String: Any] = [
            "writes": [[
                "update": [
                    "name": name,
                    "fields": ["level": ["integerValue": String(level.rawValue)]],
                ],
                "updateTransforms": [["fieldPath": "createdAt", "setToServerValue": "REQUEST_TIME"]],
                "currentDocument": ["exists": false],
            ]],
        ]
        _ = try await post("https://firestore.googleapis.com/v1/\(databasePath)/documents:commit", body: body)
    }

    // MARK: - Helpers

    /// Firestore document IDs may not contain "/" and should be URL-safe. Google place IDs
    /// already are; other IDs (e.g. Apple Maps results) are replaced by a stable hash.
    static func documentID(for placeID: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        if !placeID.isEmpty, placeID.count <= 400,
           placeID.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return placeID
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a, stable across launches
        for byte in placeID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "h" + String(hash, radix: 16)
    }

    static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parseTimestamp(_ string: String) -> Date? {
        // Firestore returns RFC 3339 with up to nanosecond precision, e.g. "2026-11-20T18:05:03.123456Z".
        let trimmed = string.replacingOccurrences(
            of: #"\.(\d{3})\d+"#, with: ".$1", options: .regularExpression
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    /// `runQuery` streams a JSON array of RunQueryResponse objects; entries without a
    /// `document` (e.g. only `readTime`) carry no result.
    static func parseRunQuery(_ data: Data) throws -> [CommunityCrowdReport] {
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CommunityReportsError.invalidResponse
        }
        if let error = items.compactMap({ $0["error"] as? [String: Any] }).first {
            throw CommunityReportsError.server(message: error["message"] as? String ?? "Unknown Firestore error")
        }
        return items.compactMap { item in
            guard let document = item["document"] as? [String: Any],
                  let fields = document["fields"] as? [String: Any],
                  let levelText = (fields["level"] as? [String: Any])?["integerValue"],
                  let level = Int("\(levelText)"),
                  let timeText = (fields["createdAt"] as? [String: Any])?["timestampValue"] as? String,
                  let createdAt = parseTimestamp(timeText) else { return nil }
            return CommunityCrowdReport(storedValue: level, createdAt: createdAt)
        }
    }

    private func post(_ urlString: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw CommunityReportsError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CommunityReportsError.from(data: data, status: http.statusCode)
        }
        return data
    }
}

enum CommunityReportsError: LocalizedError, Equatable {
    case server(message: String)
    case http(status: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .server(let message): message
        case .http(let status): "Live reports request failed (HTTP \(status))."
        case .invalidResponse: "Live reports: unexpected response."
        }
    }

    /// Google APIs report errors as {"error": {"code", "message", "status"}}, sometimes inside an array.
    static func from(data: Data, status: Int) -> CommunityReportsError {
        let json = try? JSONSerialization.jsonObject(with: data)
        let object = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
        if let error = object?["error"] as? [String: Any], let message = error["message"] as? String {
            return .server(message: message)
        }
        return .http(status: status)
    }
}
