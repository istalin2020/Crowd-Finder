import Foundation

/// Turns a crowd report into a simple "should I go now?" answer.
struct VisitAdvice: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        /// Quiet or moderate right now.
        case goNow
        /// Busy now, but noticeably quieter later today.
        case goLater(hour: Int, busyness: Int)
        /// Busy now and it stays busy for the rest of the day.
        case expectCrowds
        /// No visitors expected right now (usually closed).
        case closedNow
    }

    let verdict: Verdict
    let headline: String
    let detail: String

    /// Minimum drop (percentage points) for "go later" to be worth suggesting.
    static let meaningfulDrop = 15

    init(report: CrowdReport, at date: Date) {
        let current = report.currentBusyness
        let level = report.level
        let localHour = report.clock.localHour(at: date)
        // Only look at *later* hours; the current hour is what the user already sees.
        let laterHours = report.forecast?.upcomingHours(from: localHour).dropFirst().filter { $0.busyness > 0 } ?? []
        let quietestLater = laterHours.min { $0.busyness < $1.busyness }

        if level == .empty {
            verdict = .closedNow
            headline = "Probably closed right now"
            if let next = laterHours.first {
                detail = "Visitors are expected again from about \(HourFormatter.string(for: next.hour))."
            } else {
                detail = "No visitors expected for the rest of the day."
            }
        } else if level <= .moderate {
            verdict = .goNow
            headline = level == .quiet ? "Great time to go now" : "Good time to go now"
            let busiestLater = laterHours.max { $0.busyness < $1.busyness }
            if let peak = busiestLater, peak.busyness > current + Self.meaningfulDrop {
                detail = "It gets busier later, around \(HourFormatter.string(for: peak.hour)) (\(peak.busyness) %)."
            } else {
                detail = "Crowd levels are comfortable at the moment."
            }
        } else if let later = quietestLater,
                  later.busyness <= current - Self.meaningfulDrop,
                  later.busyness <= CrowdLevel.busyMax {
            verdict = .goLater(hour: later.hour, busyness: later.busyness)
            headline = "Better at \(HourFormatter.string(for: later.hour))"
            detail = "About \(later.busyness) % busy then, compared with \(current) % now."
        } else {
            verdict = .expectCrowds
            headline = "Expect crowds today"
            detail = "It stays busy for the rest of the day. Try early tomorrow instead."
        }
    }
}

/// Links that open Google Maps (the app if installed, otherwise the website).
/// Format: Google Maps URLs, https://developers.google.com/maps/documentation/urls/get-started
enum GoogleMapsLinks {
    static func place(_ place: Place) -> URL {
        url("https://www.google.com/maps/search/", [
            ("api", "1"),
            ("query", "\(place.coordinate.latitude),\(place.coordinate.longitude)"),
            ("query_place_id", place.id),
        ])
    }

    static func directions(to place: Place) -> URL {
        url("https://www.google.com/maps/dir/", [
            ("api", "1"),
            ("destination", "\(place.coordinate.latitude),\(place.coordinate.longitude)"),
            ("destination_place_id", place.id),
        ])
    }

    private static func url(_ base: String, _ query: [(String, String)]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }
}
