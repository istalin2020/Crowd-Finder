import Foundation
import Observation

/// A one-time instruction for the map camera. A new `id` means "run this again".
struct MapCameraCommand: Equatable {
    enum Kind: Equatable {
        case focus(Coordinate, zoom: Float?)
        case fit([Coordinate])
    }

    let id = UUID()
    let kind: Kind

    static func focus(_ coordinate: Coordinate, zoom: Float? = nil) -> MapCameraCommand {
        MapCameraCommand(kind: .focus(coordinate, zoom: zoom))
    }

    static func fit(_ coordinates: [Coordinate]) -> MapCameraCommand {
        MapCameraCommand(kind: .fit(coordinates))
    }
}

/// What the map needs to draw one place.
struct CrowdAnnotation: Identifiable, Equatable {
    let id: String
    let coordinate: Coordinate
    let name: String
    let category: PlaceCategory
    /// `nil` while the crowd level is loading.
    let busyness: Int?
    let isSelected: Bool
    /// The value comes from live data (visitor reports or BestTime live).
    var isLive = false

    var level: CrowdLevel? { busyness.map(CrowdLevel.init(busyness:)) }
}

/// A one-tap search shown under the search bar.
struct QuickSearch: Identifiable, Hashable {
    let title: String
    let symbolName: String
    let query: String
    var id: String { query }

    static let all: [QuickSearch] = [
        QuickSearch(title: "Tourist spots", symbolName: "binoculars.fill", query: "tourist attractions"),
        QuickSearch(title: "Restaurants", symbolName: "fork.knife", query: "restaurants"),
        QuickSearch(title: "Cafés", symbolName: "cup.and.saucer.fill", query: "cafes"),
        QuickSearch(title: "Malls", symbolName: "bag.fill", query: "shopping malls"),
        QuickSearch(title: "Parks", symbolName: "tree.fill", query: "parks"),
        QuickSearch(title: "Beaches", symbolName: "beach.umbrella.fill", query: "beaches"),
        QuickSearch(title: "Worship", symbolName: "building.columns.fill", query: "places of worship"),
        QuickSearch(title: "Stations", symbolName: "tram.fill", query: "train stations"),
        QuickSearch(title: "Gyms", symbolName: "dumbbell.fill", query: "gyms"),
        QuickSearch(title: "Hospitals", symbolName: "cross.case.fill", query: "hospitals"),
    ]

    static let examples = ["Marina Beach", "Times Square", "Eiffel Tower", "Dubai Mall", "Tokyo"]
}

/// Whether the user can send a live crowd report for a place right now.
enum ReportEligibility: Equatable {
    case allowed
    /// Live reports need a Firebase project ID (Settings).
    case notConfigured
    case locationUnknown
    case tooFar(meters: Double)
    case coolingDown(minutes: Int)
}

/// Feedback shown after sending a live report.
struct ReportFeedback: Equatable {
    let placeID: String
    let text: String
    let isError: Bool
}

enum PlaceSortOrder: String, CaseIterable, Identifiable {
    case relevance = "Best match"
    case leastCrowded = "Least crowded first"
    var id: String { rawValue }
}

@MainActor
@Observable
final class CrowdMapViewModel {

    // MARK: Search state
    var searchText = ""
    private(set) var isSearching = false
    private(set) var places: [Place] = []
    /// Title above the results, e.g. "Tourist attractions in Chennai".
    private(set) var resultsTitle: String?
    /// Set when the user searched a city or area; quick searches then stay inside it.
    private(set) var areaContext: Place?
    var errorMessage: String?
    /// Which engine answered, and why Google didn't (helps diagnose key / API problems).
    private(set) var searchNote: String?
    /// "Search as you type" suggestions.
    let suggestions = SearchSuggestionProvider()
    private(set) var recentSearches: [String]

    // MARK: Crowd state
    private(set) var reports: [String: CrowdReport] = [:]
    private(set) var loadingPlaceIDs: Set<String> = []
    private(set) var liveLoadingPlaceIDs: Set<String> = []
    private(set) var accountProblem: String?
    private(set) var usesRealData: Bool

    // MARK: Live reports
    private(set) var supportsLiveReports: Bool
    /// Problem reading live reports (e.g. database or rules not set up), if any.
    private(set) var communityProblem: String?
    private(set) var userLocation: Coordinate?
    private(set) var submittingReportPlaceID: String?
    private(set) var reportFeedback: ReportFeedback?
    /// When live data was last refreshed automatically.
    private(set) var lastLiveRefresh: Date?
    /// You must be this close to a place to report its crowd (large parks and dams included).
    static let reportRadiusMeters: Double = 1_500
    /// One report per place per person every 10 minutes.
    static let reportCooldown: TimeInterval = 10 * 60
    static let liveRefreshInterval: UInt64 = 60
    /// 0 = now, otherwise hours from now ("time travel" through the forecast).
    var hourOffset = 0
    var sortOrder: PlaceSortOrder = .relevance

    // MARK: Map state
    var selectedPlaceID: String?
    /// The place shown in the detail sheet.
    var detailPlace: Place?
    private(set) var cameraCommand: MapCameraCommand?

    @ObservationIgnored private var mapCenter: Coordinate?
    @ObservationIgnored private var mapRadius: Double = 5_000
    @ObservationIgnored private var hasCenteredOnUser = false
    private let placeSearch: PlaceSearching
    @ObservationIgnored private var crowdService: CrowdService
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var crowdTask: Task<Void, Never>?
    @ObservationIgnored private var liveRefreshTask: Task<Void, Never>?

    private static let recentSearchesKey = "recentSearches"
    private static let maxRecentSearches = 8
    /// Parallel BestTime requests per batch (keeps the app responsive and polite to the API).
    private static let crowdBatchSize = 4

    init(placeSearch: PlaceSearching = SmartPlaceSearchService(), bestTimeKey: String? = BestTimeKeyStore.currentKey) {
        self.placeSearch = placeSearch
        self.crowdService = Self.makeCrowdService(bestTimeKey: bestTimeKey)
        self.usesRealData = bestTimeKey != nil
        self.supportsLiveReports = AppConfig.firebaseProjectID != nil
        self.recentSearches = UserDefaults.standard.stringArray(forKey: Self.recentSearchesKey) ?? []
    }

    private static func makeCrowdService(bestTimeKey: String?) -> CrowdService {
        CrowdService(
            bestTime: bestTimeKey.map { BestTimeClient(apiKeyPrivate: $0) },
            community: AppConfig.firebaseProjectID.map { CommunityReportsClient(projectID: $0) },
            cache: ForecastCache()
        )
    }

    // MARK: - Derived data

    var displayedPlaces: [Place] {
        switch sortOrder {
        case .relevance:
            return places
        case .leastCrowded:
            let now = Date()
            return places.enumerated().sorted { lhs, rhs in
                let left = busyness(for: lhs.element, at: now) ?? Int.max
                let right = busyness(for: rhs.element, at: now) ?? Int.max
                return left == right ? lhs.offset < rhs.offset : left < right
            }.map(\.element)
        }
    }

    var annotations: [CrowdAnnotation] {
        let now = Date()
        return places.map { place in
            CrowdAnnotation(
                id: place.id,
                coordinate: place.coordinate,
                name: place.name,
                category: place.category,
                busyness: busyness(for: place, at: now),
                isSelected: place.id == selectedPlaceID,
                isLive: hourOffset == 0 && reports[place.id]?.source.isLive == true
            )
        }
    }

    /// Busyness at the selected time (now or `hourOffset` hours from now).
    func busyness(for place: Place, at date: Date = Date()) -> Int? {
        reports[place.id]?.busyness(hoursAfter: date, offset: hourOffset)
    }

    func report(for place: Place) -> CrowdReport? { reports[place.id] }

    func isLoading(_ place: Place) -> Bool { loadingPlaceIDs.contains(place.id) }

    func isLoadingLive(_ place: Place) -> Bool { liveLoadingPlaceIDs.contains(place.id) }

    // MARK: - Search

    func search(_ query: String? = nil) {
        let text = (query ?? searchText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchText = text
        suggestions.clear()
        remember(text)
        runSearch(text: text, title: "Results for “\(text)”", center: mapCenter, radius: mapRadius, isQuickSearch: false)
    }

    /// Call while the user types to refresh the suggestion list.
    func searchTextChanged(_ text: String) {
        suggestions.update(query: text, near: mapCenter)
    }

    func choose(_ suggestion: SearchSuggestion) {
        search(suggestion.query)
        searchText = suggestion.title
    }

    /// Quick searches stay inside the searched city, or around the visible map area.
    func search(_ quick: QuickSearch) {
        if let area = areaContext {
            searchText = "\(quick.title) in \(area.name)"
            runSearch(text: "\(quick.query) in \(area.name)", title: "\(quick.title) in \(area.name)",
                      center: area.coordinate, radius: 15_000, isQuickSearch: true)
        } else {
            searchText = quick.title
            runSearch(text: quick.query, title: "\(quick.title) nearby",
                      center: mapCenter, radius: mapRadius, isQuickSearch: true)
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        crowdTask?.cancel()
        searchText = ""
        places = []
        reports = [:]
        loadingPlaceIDs = []
        resultsTitle = nil
        areaContext = nil
        errorMessage = nil
        searchNote = nil
        suggestions.clear()
        selectedPlaceID = nil
        hourOffset = 0
        isSearching = false
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: Self.recentSearchesKey)
    }

    private func runSearch(text: String, title: String, center: Coordinate?, radius: Double, isQuickSearch: Bool) {
        searchTask?.cancel()
        crowdTask?.cancel()
        isSearching = true
        errorMessage = nil
        searchNote = nil

        searchTask = Task {
            do {
                var result = try await placeSearch.search(text: text, near: center, radiusMeters: radius)
                try Task.checkCancellation()
                var results = result.places
                var newTitle = title
                var newArea = isQuickSearch ? areaContext : nil

                // A city or area was searched: show the crowd at its popular places instead.
                if !isQuickSearch, let area = results.first, area.isArea {
                    newArea = area
                    newTitle = "Popular places in \(area.name)"
                    cameraCommand = .focus(area.coordinate, zoom: area.suggestedZoom)
                    result = try await placeSearch.search(
                        text: "top tourist attractions in \(area.name)",
                        near: area.coordinate,
                        radiusMeters: 20_000
                    )
                    try Task.checkCancellation()
                    results = result.places
                }

                show(results, title: newTitle, area: newArea)
                if result.engine == .apple, !results.isEmpty {
                    searchNote = "Results from Apple Maps. \(result.googleIssue ?? "")"
                }
                if results.isEmpty {
                    errorMessage = "No places found for “\(text)”. Try a different name, or add the city (e.g. “parks in Chennai”)."
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                isSearching = false
                errorMessage = "Search failed: \(error.localizedDescription)"
            }
        }
    }

    private func show(_ results: [Place], title: String, area: Place?) {
        isSearching = false
        places = results
        reports = [:]
        resultsTitle = results.isEmpty ? nil : title
        areaContext = area
        selectedPlaceID = nil
        hourOffset = 0
        if !results.isEmpty {
            cameraCommand = .fit(results.map(\.coordinate))
        }
        loadCrowd(for: results)
    }

    private func remember(_ query: String) {
        var recent = recentSearches.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        recent.insert(query, at: 0)
        recentSearches = Array(recent.prefix(Self.maxRecentSearches))
        UserDefaults.standard.set(recentSearches, forKey: Self.recentSearchesKey)
    }

    // MARK: - Crowd data

    private func loadCrowd(for places: [Place], allowNetworkLimit: Int? = nil) {
        crowdTask?.cancel()
        let service = crowdService
        let networkLimit = allowNetworkLimit ?? AppSettings.placesPerSearch
        let now = Date()
        loadingPlaceIDs = Set(places.map(\.id))

        let indexed = Array(places.enumerated())
        let batches = stride(from: 0, to: indexed.count, by: Self.crowdBatchSize).map { start in
            indexed[start..<min(start + Self.crowdBatchSize, indexed.count)]
        }

        crowdTask = Task {
            for batch in batches {
                if Task.isCancelled { return }
                await withTaskGroup(of: CrowdReport.self) { group in
                    for (index, place) in batch {
                        group.addTask {
                            await service.report(for: place, at: now, allowNetwork: index < networkLimit)
                        }
                    }
                    for await report in group where !Task.isCancelled {
                        apply(report)
                    }
                }
            }
            accountProblem = await service.accountProblem
            communityProblem = await service.communityProblem
        }
    }

    private func apply(_ report: CrowdReport) {
        guard places.contains(where: { $0.id == report.placeID }) else { return }
        reports[report.placeID] = report
        loadingPlaceIDs.remove(report.placeID)
    }

    /// Re-computes "now" values after the app was in the background (uses cached data only).
    func refreshIfStale(olderThan maxAge: TimeInterval = 20 * 60) {
        guard loadingPlaceIDs.isEmpty else { return }
        let now = Date()
        let stale = places.filter { place in
            guard let report = reports[place.id] else { return false }
            return now.timeIntervalSince(report.generatedAt) > maxAge
        }
        guard !stale.isEmpty else { return }
        loadCrowd(for: stale, allowNetworkLimit: 0)
    }

    /// Loads live data (visitor reports, BestTime live and, if needed, a real forecast) for one place.
    func loadLiveData(for place: Place) {
        guard usesRealData || supportsLiveReports, !liveLoadingPlaceIDs.contains(place.id) else { return }
        liveLoadingPlaceIDs.insert(place.id)
        let service = crowdService
        Task {
            let report = await service.liveReport(for: place, at: Date())
            apply(report)
            liveLoadingPlaceIDs.remove(place.id)
            accountProblem = await service.accountProblem
            communityProblem = await service.communityProblem
        }
    }

    // MARK: - Live updates

    /// Refreshes live data every minute while the app is open.
    func startLiveUpdates() {
        liveRefreshTask?.cancel()
        liveRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.liveRefreshInterval * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.refreshLiveData()
            }
        }
    }

    func stopLiveUpdates() {
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
    }

    /// Re-reads visitor reports and recomputes "now" for every result. Uses no BestTime credits.
    func refreshLiveData() async {
        guard !places.isEmpty, loadingPlaceIDs.isEmpty else { return }
        let service = crowdService
        let now = Date()
        for place in places.prefix(20) {
            if Task.isCancelled { return }
            let fresh = await service.report(for: place, at: now, allowNetwork: false)
            // Keep a recent BestTime live value unless visitors reported something newer.
            if let existing = reports[place.id], existing.source == .live, fresh.source != .community,
               now.timeIntervalSince(existing.generatedAt) < 30 * 60 {
                continue
            }
            apply(fresh)
        }
        lastLiveRefresh = now
        communityProblem = await service.communityProblem
    }

    // MARK: - Live reports

    func reportEligibility(for place: Place, now: Date = Date()) -> ReportEligibility {
        guard supportsLiveReports else { return .notConfigured }
        if let last = lastReportDates()[place.id], now.timeIntervalSince(last) < Self.reportCooldown {
            let minutes = Int(((Self.reportCooldown - now.timeIntervalSince(last)) / 60).rounded(.up))
            return .coolingDown(minutes: max(1, minutes))
        }
        guard let userLocation else { return .locationUnknown }
        let distance = userLocation.distance(to: place.coordinate)
        return distance <= Self.reportRadiusMeters ? .allowed : .tooFar(meters: distance)
    }

    /// Sends what the user sees at the place to everyone, live.
    func submitLiveReport(_ level: CrowdLevel, for place: Place) {
        guard reportEligibility(for: place) == .allowed, submittingReportPlaceID == nil else { return }
        submittingReportPlaceID = place.id
        reportFeedback = nil
        let service = crowdService
        Task {
            do {
                let report = try await service.submitLiveReport(level: level, for: place, at: Date())
                apply(report)
                rememberReport(for: place.id)
                reportFeedback = ReportFeedback(
                    placeID: place.id,
                    text: "Thanks! Your report is live for everyone for the next 90 minutes.",
                    isError: false
                )
            } catch {
                reportFeedback = ReportFeedback(
                    placeID: place.id,
                    text: "Couldn't send your report: \(error.localizedDescription)",
                    isError: true
                )
            }
            submittingReportPlaceID = nil
            communityProblem = await service.communityProblem
        }
    }

    private static let lastReportsKey = "lastLiveReportDates"

    private func lastReportDates() -> [String: Date] {
        let stored = UserDefaults.standard.dictionary(forKey: Self.lastReportsKey) as? [String: Double] ?? [:]
        return stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func rememberReport(for placeID: String) {
        var stored = UserDefaults.standard.dictionary(forKey: Self.lastReportsKey) as? [String: Double] ?? [:]
        let cutoff = Date().addingTimeInterval(-Self.reportCooldown).timeIntervalSince1970
        stored = stored.filter { $0.value > cutoff }
        stored[placeID] = Date().timeIntervalSince1970
        UserDefaults.standard.set(stored, forKey: Self.lastReportsKey)
    }

    /// Call after the BestTime key or the live-reports project changes in Settings.
    func reloadCrowdSource() {
        let key = BestTimeKeyStore.currentKey
        crowdService = Self.makeCrowdService(bestTimeKey: key)
        usesRealData = key != nil
        supportsLiveReports = AppConfig.firebaseProjectID != nil
        communityProblem = nil
        accountProblem = nil
        if !places.isEmpty {
            reports = [:]
            loadCrowd(for: places)
        }
    }

    func clearForecastCache() async {
        await crowdService.clearCache()
    }

    // MARK: - Selection & map

    func select(_ place: Place) {
        selectedPlaceID = place.id
        detailPlace = place
        cameraCommand = .focus(place.coordinate)
        loadLiveData(for: place)
    }

    /// Opens crowd details for any place label tapped on the Google map.
    func openMapPlace(id placeID: String, name: String, coordinate: Coordinate) {
        if let existing = places.first(where: { $0.id == placeID }) {
            select(existing)
            return
        }
        errorMessage = nil
        let service = crowdService
        Task {
            // Look the place up to get its address, type and popularity (used for the crowd level).
            var place = Place(id: placeID, name: name, address: "", coordinate: coordinate)
            if let results = try? await placeSearch.search(text: name, near: coordinate, radiusMeters: 1_000).places,
               let match = results.first(where: { $0.id == placeID })
                ?? results.first(where: { $0.coordinate.distance(to: coordinate) < 150 }) {
                place = match
            }
            if !places.contains(where: { $0.id == place.id }) {
                if places.isEmpty { resultsTitle = "Places you tapped on the map" }
                places.append(place)
            }
            select(place)
            if reports[place.id] == nil {
                apply(await service.report(for: place, at: Date(), allowNetwork: true))
            }
        }
    }

    func selectPlace(id: String) {
        guard let place = places.first(where: { $0.id == id }) else { return }
        select(place)
    }

    func mapCameraChanged(center: Coordinate, radius: Double) {
        mapCenter = center
        mapRadius = radius
    }

    func userLocationUpdated(_ coordinate: Coordinate) {
        userLocation = coordinate
        // Center on the user once, unless they already searched something.
        guard !hasCenteredOnUser, places.isEmpty else { return }
        hasCenteredOnUser = true
        mapCenter = coordinate
        cameraCommand = .focus(coordinate, zoom: 13)
    }

    func centerOn(_ coordinate: Coordinate) {
        cameraCommand = .focus(coordinate, zoom: 15)
    }
}
