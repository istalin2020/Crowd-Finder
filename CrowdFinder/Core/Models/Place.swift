import Foundation

/// A latitude/longitude pair.
///
/// The app keeps its own coordinate type (instead of `CLLocationCoordinate2D`) so the
/// core logic stays platform-independent and easy to unit test.
struct Coordinate: Hashable, Codable, Sendable {
    var latitude: Double
    var longitude: Double

    /// Great-circle distance in meters (haversine formula).
    func distance(to other: Coordinate) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// A place returned by Google Places search.
struct Place: Identifiable, Hashable, Sendable {
    /// Google Place ID.
    let id: String
    let name: String
    let address: String
    let coordinate: Coordinate
    /// Google Places types, for example `["tourist_attraction", "point_of_interest"]`.
    let types: [String]
    /// Average Google rating (1.0 – 5.0), if known.
    let rating: Double?
    /// Number of Google reviews, if known. Used as a popularity signal for estimates.
    let userRatingCount: Int?
    /// The place's current offset from UTC in minutes. Lets us use the place's local time.
    let utcOffsetMinutes: Int?

    init(
        id: String,
        name: String,
        address: String,
        coordinate: Coordinate,
        types: [String] = [],
        rating: Double? = nil,
        userRatingCount: Int? = nil,
        utcOffsetMinutes: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.coordinate = coordinate
        self.types = types
        self.rating = rating
        self.userRatingCount = userRatingCount
        self.utcOffsetMinutes = utcOffsetMinutes
    }

    var category: PlaceCategory { PlaceCategory(googleTypes: types) }

    /// True for a city, district, state or country rather than a single venue.
    /// Searching an area shows the crowd at the popular places inside it.
    var isArea: Bool {
        let isVenue = types.contains("point_of_interest") || types.contains("establishment")
        return !isVenue && types.contains { Self.areaTypes.contains($0) }
    }

    /// A sensible map zoom level for showing this place.
    var suggestedZoom: Float {
        if types.contains("country") { return 5 }
        if types.contains("administrative_area_level_1") { return 7 }
        if types.contains("administrative_area_level_2") { return 9 }
        if types.contains("locality") || types.contains("postal_town") { return 11.5 }
        if isArea { return 13 }
        return 16
    }

    private static let areaTypes: Set<String> = [
        "country", "administrative_area_level_1", "administrative_area_level_2",
        "administrative_area_level_3", "locality", "sublocality", "sublocality_level_1",
        "postal_town", "neighborhood", "colloquial_area", "postal_code",
    ]
}
