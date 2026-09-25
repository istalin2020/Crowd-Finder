import Foundation

/// Reads configuration injected at build time from `Config/*.xcconfig` via `Config/Info.plist`.
enum AppConfig {
    static let googleMapsKeyInfoKey = "GoogleMapsAPIKey"
    static let bestTimeKeyInfoKey = "BestTimeAPIKeyPrivate"

    /// Google Maps Platform key (Maps SDK for iOS + Places API). Required.
    static var googleMapsAPIKey: String? { infoValue(googleMapsKeyInfoKey) }

    /// Optional BestTime private key bundled at build time.
    static var bundledBestTimeKey: String? { infoValue(bestTimeKeyInfoKey) }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// Returns `nil` for empty values, unexpanded `$(VARIABLES)` and template placeholders.
    static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.hasPrefix("$("),
              !value.uppercased().hasPrefix("YOUR_") else { return nil }
        return value
    }

    private static func infoValue(_ key: String) -> String? {
        cleaned(Bundle.main.object(forInfoDictionaryKey: key) as? String)
    }
}

/// User preferences stored in `UserDefaults`.
enum AppSettings {
    static let placesPerSearchKey = "placesPerSearch"
    /// How many search results may use BestTime credits automatically.
    static let defaultPlacesPerSearch = 8

    static var placesPerSearch: Int {
        let stored = UserDefaults.standard.object(forKey: placesPerSearchKey) as? Int
        return stored ?? defaultPlacesPerSearch
    }
}

/// Where the BestTime key lives: the Keychain (entered in Settings) wins over the bundled key.
enum BestTimeKeyStore {
    private static let account = "besttime.api_key_private"

    static var userKey: String? { AppConfig.cleaned(KeychainStore.string(for: account)) }

    static var currentKey: String? { userKey ?? AppConfig.bundledBestTimeKey }

    static func saveUserKey(_ key: String?) {
        KeychainStore.set(AppConfig.cleaned(key), for: account)
    }
}
