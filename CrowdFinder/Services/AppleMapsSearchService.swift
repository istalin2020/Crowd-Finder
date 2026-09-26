import MapKit

/// Place search through Apple Maps (`MKLocalSearch`). Needs no API key.
///
/// Used as a second search engine when Google Places returns nothing, so the user always
/// finds restaurants, beaches, landmarks and cities anywhere in the world.
struct AppleMapsSearchService {

    @MainActor
    func search(text: String, near center: Coordinate?, radiusMeters: Double) async -> [Place] {
        if let center {
            let nearby = await localSearch(text, region: MKCoordinateRegion(
                center: center.clLocationCoordinate,
                latitudinalMeters: max(radiusMeters, 5_000) * 2,
                longitudinalMeters: max(radiusMeters, 5_000) * 2
            ))
            if !nearby.isEmpty { return nearby }
        }
        return await localSearch(text, region: nil)
    }

    @MainActor
    private func localSearch(_ text: String, region: MKCoordinateRegion?) async -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.pointOfInterest, .address]
        if let region { request.region = region }
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.compactMap(Place.init(mapItem:))
        } catch {
            // MapKit reports "nothing found" as an error; treat it as no results.
            return []
        }
    }
}

extension Place {
    /// Converts an Apple Maps result. Apple categories are translated to Google place types
    /// so crowd estimates and icons work the same way for both search engines.
    init?(mapItem item: MKMapItem) {
        let placemark = item.placemark
        let coordinate = placemark.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let name = item.name ?? placemark.name ?? "Unnamed place"

        var types: [String]
        if let category = item.pointOfInterestCategory {
            types = [Self.googleType(for: category), "point_of_interest", "establishment"]
        } else if name == placemark.country {
            types = ["country", "political"]
        } else if name == placemark.administrativeArea {
            types = ["administrative_area_level_1", "political"]
        } else if name == placemark.locality {
            types = ["locality", "political"]
        } else if name == placemark.subLocality {
            types = ["sublocality", "political"]
        } else {
            types = ["point_of_interest", "establishment"]
        }

        self.init(
            id: "apple:\(name)@\(String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude))",
            name: name,
            address: placemark.title ?? "",
            coordinate: Coordinate(coordinate),
            types: types,
            utcOffsetMinutes: item.timeZone.map { $0.secondsFromGMT() / 60 }
        )
    }

    private static func googleType(for category: MKPointOfInterestCategory) -> String {
        categoryMap[category] ?? "point_of_interest"
    }

    private static let categoryMap: [MKPointOfInterestCategory: String] = [
        .restaurant: "restaurant", .cafe: "cafe", .bakery: "bakery",
        .nightlife: "night_club", .brewery: "bar", .winery: "bar",
        .store: "store", .foodMarket: "supermarket",
        .museum: "museum", .amusementPark: "amusement_park", .aquarium: "aquarium",
        .zoo: "zoo", .theater: "performing_arts_theater", .movieTheater: "movie_theater",
        .stadium: "stadium", .park: "park", .nationalPark: "national_park",
        .beach: "beach", .marina: "tourist_attraction", .campground: "park",
        .publicTransport: "transit_station", .airport: "airport",
        .hospital: "hospital", .pharmacy: "pharmacy", .fitnessCenter: "gym",
        .school: "school", .university: "university", .library: "library",
        .hotel: "lodging", .bank: "bank", .atm: "bank", .postOffice: "post_office",
    ]
}
