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
    @MainActor
    func search(text: String, near center: Coordinate?, radiusMeters: Double) async throws -> [Place] {
        let request = GMSPlaceSearchByTextRequest(
            textQuery: text,
            placeProperties: Self.properties.map(\.rawValue)
        )
        if let center {
            // A bias (not a restriction): nearby results rank higher, but
            // "Eiffel Tower" is still found when the map shows Chennai.
            let radius = min(max(radiusMeters, Self.radiusRange.lowerBound), Self.radiusRange.upperBound)
            request.locationBias = GMSPlaceCircularLocationOption(
                CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
                radius
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            GMSPlacesClient.shared().searchByText(with: request) { results, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (results ?? []).compactMap(Place.init(gmsPlace:)))
                }
            }
        }
    }
}

extension Place {
    init?(gmsPlace place: GMSPlace) {
        guard let placeID = place.placeID, CLLocationCoordinate2DIsValid(place.coordinate) else { return nil }
        self.init(
            id: placeID,
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
