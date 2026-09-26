import MapKit
import Observation

/// One "search as you type" suggestion, e.g. "Malabar Days Restaurant" · "Al Mabela, Muscat".
struct SearchSuggestion: Identifiable, Hashable {
    let title: String
    let subtitle: String
    var id: String { title + "|" + subtitle }

    /// Text sent to the search engines when the suggestion is chosen.
    var query: String { subtitle.isEmpty ? title : "\(title), \(subtitle)" }
}

/// Live suggestions while typing, like the Google Maps search box.
/// Uses Apple's `MKLocalSearchCompleter` (free, no API key, results near the map first).
@MainActor
@Observable
final class SearchSuggestionProvider: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var suggestions: [SearchSuggestion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address, .query]
    }

    func update(query: String, near center: Coordinate?) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            suggestions = []
            completer.cancel()
            return
        }
        if let center {
            completer.region = MKCoordinateRegion(
                center: center.clLocationCoordinate,
                latitudinalMeters: 50_000,
                longitudinalMeters: 50_000
            )
        }
        completer.queryFragment = text
    }

    func clear() {
        suggestions = []
        completer.cancel()
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            self.suggestions = self.completer.results.prefix(8).map {
                SearchSuggestion(title: $0.title, subtitle: $0.subtitle)
            }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }
}
