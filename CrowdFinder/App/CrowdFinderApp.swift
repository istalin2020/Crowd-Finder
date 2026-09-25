import SwiftUI
import GoogleMaps
import GooglePlaces

@main
struct CrowdFinderApp: App {
    private let isGoogleConfigured: Bool

    init() {
        // The key comes from Config/Secrets.xcconfig → Info.plist (see README).
        if let apiKey = AppConfig.googleMapsAPIKey {
            _ = GMSServices.provideAPIKey(apiKey)
            _ = GMSPlacesClient.provideAPIKey(apiKey)
            isGoogleConfigured = true
        } else {
            isGoogleConfigured = false
        }
    }

    var body: some Scene {
        WindowGroup {
            if isGoogleConfigured {
                ContentView()
            } else {
                SetupRequiredView()
            }
        }
    }
}
