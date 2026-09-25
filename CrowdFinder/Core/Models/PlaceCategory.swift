import Foundation

/// A simplified category for a place, derived from its Google Places types.
///
/// The category decides the icon and, when no real foot-traffic data is available,
/// the typical daily crowd pattern used by `CrowdEstimator`.
enum PlaceCategory: String, CaseIterable, Codable, Sendable {
    case restaurant
    case cafe
    case nightlife
    case shopping
    case grocery
    case attraction
    case park
    case transit
    case airport
    case worship
    case fitness
    case health
    case education
    case entertainment
    case services
    case lodging
    case other

    /// Maps Google Places types (Table A) to a category.
    /// The first type that matches wins, because Google lists the most specific type first.
    init(googleTypes: [String]) {
        for type in googleTypes {
            if let match = Self.category(forGoogleType: type) {
                self = match
                return
            }
        }
        self = .other
    }

    var displayName: String {
        switch self {
        case .restaurant: "Restaurant"
        case .cafe: "Café"
        case .nightlife: "Nightlife"
        case .shopping: "Shopping"
        case .grocery: "Grocery"
        case .attraction: "Attraction"
        case .park: "Park & outdoors"
        case .transit: "Transit"
        case .airport: "Airport"
        case .worship: "Place of worship"
        case .fitness: "Fitness"
        case .health: "Health"
        case .education: "Education"
        case .entertainment: "Entertainment"
        case .services: "Public services"
        case .lodging: "Hotel"
        case .other: "Place"
        }
    }

    /// SF Symbol name for the category.
    var symbolName: String {
        switch self {
        case .restaurant: "fork.knife"
        case .cafe: "cup.and.saucer.fill"
        case .nightlife: "wineglass.fill"
        case .shopping: "bag.fill"
        case .grocery: "cart.fill"
        case .attraction: "binoculars.fill"
        case .park: "tree.fill"
        case .transit: "tram.fill"
        case .airport: "airplane"
        case .worship: "building.columns.fill"
        case .fitness: "dumbbell.fill"
        case .health: "cross.case.fill"
        case .education: "graduationcap.fill"
        case .entertainment: "theatermasks.fill"
        case .services: "building.2.fill"
        case .lodging: "bed.double.fill"
        case .other: "mappin"
        }
    }

    private static func category(forGoogleType type: String) -> PlaceCategory? {
        if let exact = exactTypeMap[type] { return exact }
        // Google has many specific sub-types, e.g. "indian_restaurant" or "electronics_store".
        if type.hasSuffix("_restaurant") { return .restaurant }
        if type.hasSuffix("_store") || type.hasSuffix("_shop") { return .shopping }
        if type.hasSuffix("_station") { return .transit }
        if type.hasSuffix("_airport") { return .airport }
        return nil
    }

    private static let exactTypeMap: [String: PlaceCategory] = [
        // Food & drink
        "restaurant": .restaurant, "food_court": .restaurant, "meal_takeaway": .restaurant,
        "diner": .restaurant, "bar_and_grill": .restaurant, "buffet_restaurant": .restaurant,
        "cafe": .cafe, "coffee_shop": .cafe, "tea_house": .cafe, "bakery": .cafe,
        "ice_cream_shop": .cafe, "dessert_shop": .cafe, "juice_shop": .cafe,
        "bar": .nightlife, "pub": .nightlife, "wine_bar": .nightlife, "night_club": .nightlife,
        // Shopping
        "shopping_mall": .shopping, "department_store": .shopping, "market": .shopping,
        "store": .shopping, "clothing_store": .shopping, "electronics_store": .shopping,
        "supermarket": .grocery, "grocery_store": .grocery, "convenience_store": .grocery,
        // Sights
        "tourist_attraction": .attraction, "museum": .attraction, "art_gallery": .attraction,
        "amusement_park": .attraction, "aquarium": .attraction, "zoo": .attraction,
        "historical_landmark": .attraction, "historical_place": .attraction,
        "monument": .attraction, "cultural_landmark": .attraction, "observation_deck": .attraction,
        "water_park": .attraction, "visitor_center": .attraction, "landmark": .attraction,
        // Outdoors
        "park": .park, "national_park": .park, "state_park": .park, "garden": .park,
        "botanical_garden": .park, "beach": .park, "hiking_area": .park, "playground": .park,
        "plaza": .park, "dog_park": .park, "natural_feature": .park,
        // Transport
        "train_station": .transit, "subway_station": .transit, "bus_station": .transit,
        "transit_station": .transit, "light_rail_station": .transit, "ferry_terminal": .transit,
        "bus_stop": .transit, "airport": .airport, "international_airport": .airport,
        // Worship
        "place_of_worship": .worship, "church": .worship, "hindu_temple": .worship,
        "mosque": .worship, "synagogue": .worship,
        // Fitness
        "gym": .fitness, "fitness_center": .fitness, "yoga_studio": .fitness,
        "swimming_pool": .fitness, "sports_club": .fitness,
        // Health
        "hospital": .health, "doctor": .health, "pharmacy": .health, "drugstore": .health,
        "medical_lab": .health, "dental_clinic": .health,
        // Education
        "school": .education, "university": .education, "primary_school": .education,
        "secondary_school": .education, "library": .education,
        // Entertainment
        "movie_theater": .entertainment, "stadium": .entertainment, "arena": .entertainment,
        "bowling_alley": .entertainment, "casino": .entertainment, "concert_hall": .entertainment,
        "event_venue": .entertainment, "performing_arts_theater": .entertainment,
        "sports_complex": .entertainment,
        // Public services
        "bank": .services, "post_office": .services, "city_hall": .services,
        "courthouse": .services, "local_government_office": .services,
        "government_office": .services, "embassy": .services,
        // Lodging
        "lodging": .lodging, "hotel": .lodging, "resort_hotel": .lodging,
        "hostel": .lodging, "motel": .lodging,
    ]
}
