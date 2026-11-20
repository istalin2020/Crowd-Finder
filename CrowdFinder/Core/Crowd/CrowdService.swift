import Foundation

/// Decides where crowd numbers come from and always returns *something* useful.
///
/// Priority for each place:
/// 1. **Live reports** – what people at the place reported in the last 90 minutes.
///    This is the only source that catches one-off events (shows, festivals, protests).
/// 2. **Live** – BestTime live busyness (select high-traffic venues, when the user opens a place).
/// 3. **Forecast** – BestTime weekly forecast (cached on the device for a week).
/// 4. **Estimate** – the usual pattern for this kind of place, computed on the device.
actor CrowdService {
    private let bestTime: BestTimeClient?
    private let community: CommunityReportsClient?
    private let estimator: CrowdEstimator
    private let cache: ForecastCache
    private var inFlight: [String: Task<CachedVenueForecast, Error>] = [:]

    private struct CachedReports {
        let fetchedAt: Date
        let reports: [CommunityCrowdReport]
    }
    private var communityCache: [String: CachedReports] = [:]
    /// Live reports are re-read at most this often per place.
    static let communityRefreshInterval: TimeInterval = 45

    /// The most recent problem with the BestTime account (bad key, no credits, …), if any.
    private(set) var accountProblem: String?
    /// The most recent problem reading live reports (database not set up, rules missing, …), if any.
    private(set) var communityProblem: String?

    init(
        bestTime: BestTimeClient?,
        community: CommunityReportsClient? = nil,
        estimator: CrowdEstimator = CrowdEstimator(),
        cache: ForecastCache
    ) {
        self.bestTime = bestTime
        self.community = community
        self.estimator = estimator
        self.cache = cache
    }

    nonisolated var usesRealData: Bool { bestTime != nil }
    nonisolated var supportsLiveReports: Bool { community != nil }

    /// Crowd report for `date`, including live visitor reports when available.
    /// - Parameter allowNetwork: When `false`, only cached BestTime data is used, which saves credits.
    ///   Live visitor reports are always checked (they are free).
    func report(for place: Place, at date: Date, allowNetwork: Bool = true) async -> CrowdReport {
        let base = await baseReport(for: place, at: date, allowNetwork: allowNetwork)
        return await withLiveReports(base, for: place, at: date)
    }

    /// Like `report(for:at:)`, but also asks BestTime for live foot traffic.
    func liveReport(for place: Place, at date: Date) async -> CrowdReport {
        let base = await bestTimeLiveReport(for: place, at: date)
        return await withLiveReports(base, for: place, at: date)
    }

    /// Sends what the user sees at the place, then returns the updated report.
    func submitLiveReport(level: CrowdLevel, for place: Place, at date: Date) async throws -> CrowdReport {
        guard let community else { throw CommunityReportsError.server(message: "Live reports are not set up.") }
        try await community.submit(level: level, placeID: place.id)
        communityCache[place.id] = nil
        var reports = await communityReports(for: place.id, at: date)
        // Show the user's own report right away, even if the read happened just before the write.
        if !reports.contains(where: { $0.level == level && abs($0.createdAt.timeIntervalSince(date)) < 120 }) {
            reports.append(CommunityCrowdReport(level: level, createdAt: date))
            communityCache[place.id] = CachedReports(fetchedAt: date, reports: reports)
        }
        let base = await baseReport(for: place, at: date, allowNetwork: false)
        return base.applying(LiveCrowdAggregator.summary(of: reports, at: date))
    }

    // MARK: - Sources

    private func withLiveReports(_ report: CrowdReport, for place: Place, at date: Date) async -> CrowdReport {
        guard community != nil else { return report }
        let reports = await communityReports(for: place.id, at: date)
        return report.applying(LiveCrowdAggregator.summary(of: reports, at: date))
    }

    private func communityReports(for placeID: String, at date: Date) async -> [CommunityCrowdReport] {
        guard let community else { return [] }
        if let cached = communityCache[placeID],
           date.timeIntervalSince(cached.fetchedAt) < Self.communityRefreshInterval {
            return cached.reports
        }
        do {
            let reports = try await community.recentReports(
                placeID: placeID,
                since: date.addingTimeInterval(-LiveCrowdAggregator.window)
            )
            communityCache[placeID] = CachedReports(fetchedAt: date, reports: reports)
            communityProblem = nil
            return reports
        } catch {
            communityProblem = error.localizedDescription
            return communityCache[placeID]?.reports ?? []
        }
    }

    private func baseReport(for place: Place, at date: Date, allowNetwork: Bool) async -> CrowdReport {
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

    /// BestTime forecast, with the current hour replaced by BestTime live foot traffic when available.
    private func bestTimeLiveReport(for place: Place, at date: Date) async -> CrowdReport {
        let base = await baseReport(for: place, at: date, allowNetwork: true)
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
            note: note,
            liveSummary: liveSummary,
            patternSource: patternSource
        )
    }

    /// Replaces "now" with live visitor reports. The usual value for this hour is kept
    /// so the app can say "much busier than usual".
    func applying(_ summary: LiveCrowdSummary?) -> CrowdReport {
        guard let summary else { return self }
        return CrowdReport(
            placeID: placeID,
            source: .community,
            currentBusyness: summary.busyness,
            usualBusyness: source.isLive ? usualBusyness : currentBusyness,
            forecast: forecast,
            timeZone: timeZone,
            generatedAt: generatedAt,
            venueID: venueID,
            note: nil,
            liveSummary: summary,
            patternSource: patternSource
        )
    }
}
