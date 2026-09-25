import Foundation

/// A BestTime forecast saved on the device.
struct CachedVenueForecast: Codable, Equatable, Sendable {
    let venueID: String?
    let forecast: WeeklyForecast
    let timeZoneIdentifier: String?
    let fetchedAt: Date
}

/// Stores BestTime weekly forecasts on disk so the app does not spend API credits
/// on the same place again and again. Weekly patterns change slowly, so a week is fine.
actor ForecastCache {
    static let forecastLifetime: TimeInterval = 7 * 24 * 60 * 60
    /// How long to remember that BestTime has no data for a place.
    static let missLifetime: TimeInterval = 12 * 60 * 60

    private struct Storage: Codable {
        var forecasts: [String: CachedVenueForecast] = [:]
        var misses: [String: Date] = [:]
    }

    private let fileURL: URL?
    private var storage: Storage?

    /// - Parameter fileURL: Where to persist the cache. `nil` keeps it in memory only.
    init(fileURL: URL? = ForecastCache.defaultFileURL) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("besttime-forecasts.json")
    }

    func forecast(for placeID: String, now: Date) -> CachedVenueForecast? {
        guard let entry = load().forecasts[placeID] else { return nil }
        return now.timeIntervalSince(entry.fetchedAt) < Self.forecastLifetime ? entry : nil
    }

    func store(_ entry: CachedVenueForecast, for placeID: String) {
        var storage = load()
        storage.forecasts[placeID] = entry
        storage.misses[placeID] = nil
        save(storage)
    }

    func isKnownMiss(_ placeID: String, now: Date) -> Bool {
        guard let date = load().misses[placeID] else { return false }
        return now.timeIntervalSince(date) < Self.missLifetime
    }

    func recordMiss(for placeID: String, at date: Date) {
        var storage = load()
        storage.misses[placeID] = date
        save(storage)
    }

    func removeAll() {
        save(Storage())
    }

    var forecastCount: Int { load().forecasts.count }

    // MARK: - Persistence

    private func load() -> Storage {
        if let storage { return storage }
        var loaded = Storage()
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            loaded = decoded
        }
        storage = loaded
        return loaded
    }

    private func save(_ newValue: Storage) {
        storage = newValue
        guard let fileURL else { return }
        if let data = try? JSONEncoder().encode(newValue) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
