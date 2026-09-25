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
    private(set) var recentSearches: [String]

    // MARK: Crowd state
    private(set) var reports: [String: CrowdReport] = [:]
    private(set) var loadingPlaceIDs: Set<String> = []
    private(set) var liveLoadingPlaceIDs: Set<String> = []
    private(set) var accountProblem: String?
    private(set) var usesRealData: Bool
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

    private static let recentSearchesKey = "recentSearches"
    private static let maxRecentSearches = 8
    /// Parallel BestTime requests per batch (keeps the app responsive and polite to the API).
    private static let crowdBatchSize = 4

    init(placeSearch: PlaceSearching = GooglePlaceSearchService(), bestTimeKey: String? = BestTimeKeyStore.currentKey) {
        self.placeSearch = placeSearch
        self.crowdService = Self.makeCrowdService(bestTimeKey: bestTimeKey)
        self.usesRealData = bestTimeKey != nil
        self.recentSearches = UserDefaults.standard.stringArray(forKey: Self.recentSearchesKey) ?? []
    }

    private static func makeCrowdService(bestTimeKey: String?) -> CrowdService {
        CrowdService(
            bestTime: bestTimeKey.map { BestTimeClient(apiKeyPrivate: $0) },
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
                isSelected: place.id == selectedPlaceID
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
        remember(text)
        runSearch(text: text, title: "Results for “\(text)”", center: mapCenter, radius: mapRadius, isQuickSearch: false)
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

        searchTask = Task {
            do {
                var results = try await placeSearch.search(text: text, near: center, radiusMeters: radius)
                try Task.checkCancellation()
                var newTitle = title
                var newArea = isQuickSearch ? areaContext : nil

                // A city or area was searched: show the crowd at its popular places instead.
                if !isQuickSearch, let area = results.first, area.isArea {
                    newArea = area
                    newTitle = "Popular places in \(area.name)"
                    cameraCommand = .focus(area.coordinate, zoom: area.suggestedZoom)
                    results = try await placeSearch.search(
                        text: "top tourist attractions in \(area.name)",
                        near: area.coordinate,
                        radiusMeters: 20_000
                    )
                    try Task.checkCancellation()
                }

                show(results, title: newTitle, area: newArea)
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

    /// Loads live data (and, if needed, a real forecast) for one place.
    func loadLiveData(for place: Place) {
        guard usesRealData, !liveLoadingPlaceIDs.contains(place.id) else { return }
        liveLoadingPlaceIDs.insert(place.id)
        let service = crowdService
        Task {
            let report = await service.liveReport(for: place, at: Date())
            apply(report)
            liveLoadingPlaceIDs.remove(place.id)
            accountProblem = await service.accountProblem
        }
    }

    /// Call after the BestTime key changes in Settings.
    func reloadCrowdSource() {
        let key = BestTimeKeyStore.currentKey
        crowdService = Self.makeCrowdService(bestTimeKey: key)
        usesRealData = key != nil
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

    func selectPlace(id: String) {
        guard let place = places.first(where: { $0.id == id }) else { return }
        select(place)
    }

    func mapCameraChanged(center: Coordinate, radius: Double) {
        mapCenter = center
        mapRadius = radius
    }

    func userLocationUpdated(_ coordinate: Coordinate) {
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
