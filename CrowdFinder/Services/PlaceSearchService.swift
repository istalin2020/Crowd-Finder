import CoreLocation
import GooglePlaces

/// Finds places for a text query.
protocol PlaceSearching {
    @MainActor
    func search(text: String, near center: Coordinate?, radiusMeters: Double) async throws -> [Place]
}

/// Text Search through the Places SDK for iOS (Places API "Text Search (New)").
///
/// Using the SDK (instead of calling the web service directly) means the API key can be
/// restricted to this app's bundle identifier, as Google recommends for mobile apps.
struct GooglePlaceSearchService: PlaceSearching {

    /// Only the fields the app needs. Fewer fields = lower Places API cost.
    /// `rating` and `userRatingsTotal` are used as a popularity signal for crowd estimates.
    private static let properties: [GMSPlaceProperty] = [
        .placeID, .name, .coordinate, .formattedAddress, .types,
        .rating, .userRatingsTotal, .utcOffsetMinutes,
    ]

    /// Places API allows a location-bias radius of up to 50 km.
    private static let radiusRange: ClosedRange<Double> = 1_000...50_000

    /// Runs on the main thread, where Google recommends using `GMSPlacesClient`.
    ///
    /// The search first prefers places near the map. Text Search (New) can return **no**
    /// results for a far-away place (e.g. "Dubai Mall" while the map shows Muscat), so an
    /// empty nearby search is retried worldwide.
    @MainActor
    func search(text: String, near center: Coordinate?, radiusMeters: Double) async throws -> [Place] {
        if let center {
            let radius = min(max(radiusMeters, Self.radiusRange.lowerBound), Self.radiusRange.upperBound)
            let nearby = try await textSearch(text, biasCenter: center, biasRadius: radius)
            if !nearby.isEmpty { return nearby }
        }
        return try await textSearch(text, biasCenter: nil, biasRadius: 0)
    }

    @MainActor
    private func textSearch(_ text: String, biasCenter: Coordinate?, biasRadius: Double) async throws -> [Place] {
        let request = GMSPlaceSearchByTextRequest(
            textQuery: text,
            placeProperties: Self.properties.map(\.rawValue)
        )
        if let biasCenter {
            // A bias (not a restriction): nearby results rank higher.
            request.locationBias = GMSPlaceCircularLocationOption(biasCenter.clLocationCoordinate, biasRadius)
        }

        // `searchByText(with:completion:)` replaces the deprecated `searchByText(with:callback:)`
        // and returns a `GMSPlaceSearchByTextResponse` that holds the places.
        return try await withCheckedThrowingContinuation { continuation in
            GMSPlacesClient.shared().searchByText(with: request, completion: { response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let results: [GMSPlace] = response?.places ?? []
                let places = results.compactMap(Place.init(gmsPlace:))
                #if DEBUG
                print("[CrowdFinder] Text search \"\(text)\" (\(biasCenter == nil ? "worldwide" : "nearby")): \(results.count) results, \(places.count) usable")
                #endif
                continuation.resume(returning: places)
            })
        }
    }
}

extension Place {
    init?(gmsPlace place: GMSPlace) {
        guard CLLocationCoordinate2DIsValid(place.coordinate) else { return nil }
        let coordinate = place.coordinate
        // The place ID should always be present; fall back to name + position just in case.
        let id = place.placeID ?? "\(place.name ?? "place")@\(coordinate.latitude),\(coordinate.longitude)"
        self.init(
            id: id,
            name: place.name ?? "Unnamed place",
            address: place.formattedAddress ?? "",
            coordinate: Coordinate(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude),
            types: place.types ?? [],
            rating: place.rating > 0 ? Double(place.rating) : nil,
            userRatingCount: place.userRatingsTotal > 0 ? Int(place.userRatingsTotal) : nil,
            utcOffsetMinutes: place.utcOffsetMinutes?.intValue
        )
    }
}

extension Coordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
