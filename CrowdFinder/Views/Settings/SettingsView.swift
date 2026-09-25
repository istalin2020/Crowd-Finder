import SwiftUI

struct SettingsView: View {
    let model: CrowdMapViewModel

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.placesPerSearchKey) private var placesPerSearch = AppSettings.defaultPlacesPerSearch
    @State private var keyInput = ""
    @State private var hasSavedKey = BestTimeKeyStore.userKey != nil
    @State private var cacheCleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Crowd data") {
                        Label(model.usesRealData ? "BestTime (real data)" : "Estimates only",
                              systemImage: model.usesRealData ? "checkmark.seal.fill" : "wand.and.stars")
                            .foregroundStyle(model.usesRealData ? CrowdLevel.quiet.color : .secondary)
                    }
                    if let problem = model.accountProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(CrowdLevel.busy.color)
                    }

                    SecureField("BestTime private key (pri_…)", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Save key") {
                        BestTimeKeyStore.saveUserKey(keyInput)
                        keyInput = ""
                        hasSavedKey = BestTimeKeyStore.userKey != nil
                        model.reloadCrowdSource()
                    }
                    .disabled(AppConfig.cleaned(keyInput) == nil)

                    if hasSavedKey {
                        Button("Remove saved key", role: .destructive) {
                            BestTimeKeyStore.saveUserKey(nil)
                            hasSavedKey = false
                            model.reloadCrowdSource()
                        }
                    }

                    Link(destination: URL(string: "https://besttime.app")!) {
                        Label("Get a BestTime API key", systemImage: "arrow.up.right.square")
                    }
                } header: {
                    Text("Real foot-traffic data")
                } footer: {
                    Text("Google Maps does not share crowd data with apps, so Crowd Finder uses BestTime.app for real foot-traffic forecasts and live busyness. Without a key the app shows estimates. The key is stored in the iOS Keychain on this device only.")
                }

                Section {
                    Stepper("Top \(placesPerSearch) results", value: $placesPerSearch, in: 1...20)
                } header: {
                    Text("Credit saver")
                } footer: {
                    Text("BestTime uses credits for each new venue forecast. Only the top results of a search load real data automatically; open any other place to load its data. Forecasts are saved on this device for 7 days.")
                }

                Section {
                    Button(cacheCleared ? "Saved forecasts cleared" : "Clear saved forecasts") {
                        Task {
                            await model.clearForecastCache()
                            cacheCleared = true
                        }
                    }
                    .disabled(cacheCleared)
                    if !model.recentSearches.isEmpty {
                        Button("Clear recent searches") { model.clearRecentSearches() }
                    }
                }

                Section("How to read crowd levels") {
                    ForEach(CrowdLevel.legendLevels, id: \.self) { level in
                        HStack {
                            Circle().fill(level.color).frame(width: 12, height: 12)
                            Text(level.title).fontWeight(.semibold)
                            Spacer()
                            Text(range(for: level)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Text("100 % means as busy as the place's busiest hour of a normal week. Live values can go above 100 %.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach([CrowdDataSource.live, .forecast, .estimate], id: \.self) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            SourceBadge(source: source)
                            Text(source.explanation).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: AppConfig.appVersion)
                    Text("Maps and place search by Google Maps Platform. Foot-traffic data by BestTime.app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func range(for level: CrowdLevel) -> String {
        switch level {
        case .empty: "0 %"
        case .quiet: "1–\(CrowdLevel.quietMax) %"
        case .moderate: "\(CrowdLevel.quietMax + 1)–\(CrowdLevel.moderateMax) %"
        case .busy: "\(CrowdLevel.moderateMax + 1)–\(CrowdLevel.busyMax) %"
        case .veryBusy: "\(CrowdLevel.busyMax + 1) %+"
        }
    }
}

/// Shown when the Google Maps API key has not been configured yet.
struct SetupRequiredView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "key.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                Text("Add your Google Maps API key")
                    .font(.title.bold())
                Text("Crowd Finder needs a Google Maps Platform key to show the map and search places.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    step(1, "In Google Cloud Console, enable **Maps SDK for iOS** and **Places API (New)**, then create an API key.")
                    step(2, "Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig`.")
                    step(3, "Set `GOOGLE_MAPS_API_KEY = your key` in that file.")
                    step(4, "Build and run again (⌘R).")
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text("Tip: restrict the key to your app's bundle identifier and to these two APIs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: Circle())
            Text(text)
        }
    }
}
