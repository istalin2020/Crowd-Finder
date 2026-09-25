import Foundation

/// Decides where crowd numbers come from and always returns *something* useful.
///
/// Priority for each place:
/// 1. **Live** – BestTime live busyness (only when the user opens a place).
/// 2. **Forecast** – BestTime weekly forecast (cached on the device for a week).
/// 3. **Estimate** – on-device `CrowdEstimator`, when there is no BestTime key,
///    no data for the venue, or no network.
actor CrowdService {
    private let bestTime: BestTimeClient?
    private let estimator: CrowdEstimator
    private let cache: ForecastCache
    private var inFlight: [String: Task<CachedVenueForecast, Error>] = [:]

    /// The most recent problem with the BestTime account (bad key, no credits, …), if any.
    private(set) var accountProblem: String?

    init(bestTime: BestTimeClient?, estimator: CrowdEstimator = CrowdEstimator(), cache: ForecastCache) {
        self.bestTime = bestTime
        self.estimator = estimator
        self.cache = cache
    }

    nonisolated var usesRealData: Bool { bestTime != nil }

    /// Crowd report for `date`.
    /// - Parameter allowNetwork: When `false`, only cached BestTime data is used, which saves credits.
    func report(for place: Place, at date: Date, allowNetwork: Bool = true) async -> CrowdReport {
        guard let bestTime else {
            return estimator.report(for: place, at: date)
        }
        if let cached = await cache.forecast(for: place.id, now: date) {
            return forecastReport(for: place, entry: cached, at: date)
        }
        if await cache.isKnownMiss(place.id, now: date) {
            return estimator.report(for: place, at: date, note: BestTimeError.noForecastData.errorDescription)
        }
        guard allowNetwork else {
            return estimator.report(
                for: place, at: date,
                note: "Only the top results use BestTime to save credits. Open this place to load real data."
            )
        }

        do {
            let entry = try await fetchForecast(for: place, using: bestTime, at: date)
            accountProblem = nil
            return forecastReport(for: place, entry: entry, at: date)
        } catch let error as BestTimeError {
            if error.isAccountProblem {
                accountProblem = error.localizedDescription
            } else if error.isVenueSpecific {
                await cache.recordMiss(for: place.id, at: date)
            }
            return estimator.report(for: place, at: date, note: "BestTime: \(error.localizedDescription)")
        } catch {
            return estimator.report(
                for: place, at: date,
                note: "Couldn't reach BestTime (\(error.localizedDescription)). Showing an estimate."
            )
        }
    }

    /// Like `report(for:at:)`, then tries to replace the current hour with live foot traffic.
    func liveReport(for place: Place, at date: Date) async -> CrowdReport {
        let base = await report(for: place, at: date, allowNetwork: true)
        guard let bestTime, base.source == .forecast else { return base }

        do {
            let live = try await bestTime.live(venueID: base.venueID, venueName: place.name, venueAddress: place.address)
            guard let liveValue = live.liveBusyness else {
                return base.withNote("Live data isn't available for this place right now, so this is the forecast for this hour.")
            }
            return CrowdReport(
                placeID: place.id,
                source: .live,
                currentBusyness: liveValue,
                usualBusyness: live.analysis?.venueForecastedBusyness?.value ?? base.currentBusyness,
                forecast: base.forecast,
                timeZone: base.timeZone,
                generatedAt: date,
                venueID: base.venueID ?? live.venueInfo?.venueID
            )
        } catch {
            return base.withNote("Couldn't load live data (\(error.localizedDescription)). Showing the forecast.")
        }
    }

    func clearCache() async {
        await cache.removeAll()
    }

    // MARK: - Private

    private func fetchForecast(for place: Place, using client: BestTimeClient, at date: Date) async throws -> CachedVenueForecast {
        // Two screens asking for the same new place must not pay for two forecasts.
        if let running = inFlight[place.id] {
            return try await running.value
        }
        let task = Task { () throws -> CachedVenueForecast in
            let response = try await client.newForecast(venueName: place.name, venueAddress: place.address)
            let forecast = WeeklyForecast(dayWindows: response.dayWindows)
            guard !forecast.isEmpty else { throw BestTimeError.noForecastData }
            return CachedVenueForecast(
                venueID: response.venueInfo?.venueID,
                forecast: forecast,
                timeZoneIdentifier: response.venueInfo?.venueTimezone,
                fetchedAt: date
            )
        }
        inFlight[place.id] = task
        defer { inFlight[place.id] = nil }

        let entry = try await task.value
        await cache.store(entry, for: place.id)
        return entry
    }

    private func forecastReport(for place: Place, entry: CachedVenueForecast, at date: Date) -> CrowdReport {
        let clock = PlaceClock(timeZoneIdentifier: entry.timeZoneIdentifier, utcOffsetMinutes: place.utcOffsetMinutes)
        return CrowdReport(
            placeID: place.id,
            source: .forecast,
            forecast: entry.forecast,
            timeZone: clock.timeZone,
            at: date,
            venueID: entry.venueID
        )
    }
}

extension CrowdReport {
    func withNote(_ note: String?) -> CrowdReport {
        CrowdReport(
            placeID: placeID,
            source: source,
            currentBusyness: currentBusyness,
            usualBusyness: usualBusyness,
            forecast: forecast,
            timeZone: timeZone,
            generatedAt: generatedAt,
            venueID: venueID,
            note: note
        )
    }
}
