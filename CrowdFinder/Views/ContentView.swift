import SwiftUI
import UIKit

/// Main screen: a full-screen Google map with a search bar on top and results at the bottom.
struct ContentView: View {
    @State private var model = CrowdMapViewModel()
    @State private var location = LocationManager()
    @State private var showSettings = false
    @State private var topPanelHeight: CGFloat = 110
    @State private var bottomPanelHeight: CGFloat = 200
    @FocusState private var isSearchFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                GoogleMapView(
                    annotations: model.annotations,
                    cameraCommand: model.cameraCommand,
                    padding: mapPadding(in: proxy),
                    showsUserLocation: location.isAuthorized,
                    onMarkerTap: { id in
                        isSearchFocused = false
                        model.selectPlace(id: id)
                    },
                    onCameraIdle: { center, radius in model.mapCameraChanged(center: center, radius: radius) },
                    onMapTap: { isSearchFocused = false },
                    onPOITap: { placeID, name, coordinate in
                        isSearchFocused = false
                        model.openMapPlace(id: placeID, name: name, coordinate: coordinate)
                    }
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    topPanel
                        .onHeightChange { topPanelHeight = $0 }
                    Spacer(minLength: 0)
                    if !isSearchFocused {
                        bottomPanel
                            .onHeightChange { bottomPanelHeight = $0 }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: isSearchFocused)
            }
        }
        .sheet(item: $model.detailPlace) { place in
            PlaceDetailView(place: place, model: model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .task { location.requestLocation() }
        .onChange(of: location.lastLocation) { _, newLocation in
            if let newLocation { model.userLocationUpdated(newLocation) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshIfStale() }
        }
    }

    // MARK: - Panels

    private var topPanel: some View {
        VStack(spacing: 8) {
            SearchBar(
                text: $model.searchText,
                isFocused: $isSearchFocused,
                isSearching: model.isSearching,
                onSubmit: {
                    isSearchFocused = false
                    model.search()
                },
                onClear: {
                    model.clearSearch()
                },
                onSettings: { showSettings = true }
            )

            if isSearchFocused {
                SearchSuggestions(
                    recentSearches: model.recentSearches,
                    onSelect: { query in
                        isSearchFocused = false
                        model.search(query)
                    },
                    onClearRecent: { model.clearRecentSearches() }
                )
            } else {
                QuickSearchChips { quick in model.search(quick) }
            }

            if let message = model.errorMessage {
                MessageBanner(text: message, symbol: "exclamationmark.magnifyingglass") {
                    model.errorMessage = nil
                }
            } else if let problem = model.accountProblem {
                MessageBanner(text: "BestTime: \(problem) Showing estimates.", symbol: "exclamationmark.triangle.fill") {
                    showSettings = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Button {
                    if let here = location.lastLocation {
                        model.centerOn(here)
                    } else if location.isDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                        openURL(settings) // location was turned off for this app
                    } else {
                        location.requestLocation()
                    }
                } label: {
                    Image(systemName: location.isAuthorized ? "location.fill" : "location")
                        .font(.title3.weight(.semibold))
                        .frame(width: 48, height: 48)
                        .floatingPanel(cornerRadius: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show my location")
            }
            .padding(.horizontal, 16)

            if model.places.isEmpty {
                WelcomeCard(
                    usesRealData: model.usesRealData,
                    onExample: { example in model.search(example) },
                    onOpenSettings: { showSettings = true }
                )
                .padding(.horizontal, 16)
            } else {
                if let title = model.resultsTitle {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(model.places.count)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        CrowdLegend()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .floatingPanel(cornerRadius: 14)
                    .padding(.horizontal, 16)
                }

                TimeSelector(hourOffset: $model.hourOffset, sortOrder: $model.sortOrder)
                    .padding(.horizontal, 16)

                resultsCarousel
            }
        }
        .padding(.bottom, 8)
    }

    private var resultsCarousel: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(model.displayedPlaces) { place in
                        Button {
                            model.select(place)
                        } label: {
                            PlaceCard(
                                place: place,
                                report: model.report(for: place),
                                busyness: model.busyness(for: place),
                                isLoading: model.isLoading(place),
                                isSelected: place.id == model.selectedPlaceID,
                                hourOffset: model.hourOffset
                            )
                        }
                        .buttonStyle(.plain)
                        .id(place.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 8) // room for shadows
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .onChange(of: model.selectedPlaceID) { _, id in
                guard let id else { return }
                withAnimation { reader.scrollTo(id, anchor: .center) }
            }
        }
    }

    // MARK: - Helpers

    /// Map padding keeps markers, the camera focus and the Google logo clear of the panels
    /// and of the detail sheet (which covers roughly the lower half of the screen).
    private func mapPadding(in proxy: GeometryProxy) -> UIEdgeInsets {
        let sheetHeight = model.detailPlace == nil ? 0 : proxy.size.height * 0.5
        let bottomPanel = isSearchFocused ? 0 : bottomPanelHeight
        return UIEdgeInsets(
            top: proxy.safeAreaInsets.top + topPanelHeight,
            left: 0,
            bottom: proxy.safeAreaInsets.bottom + max(bottomPanel, sheetHeight),
            right: 0
        )
    }
}

/// A dismissible message under the search bar.
struct MessageBanner: View {
    let text: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(CrowdLevel.busy.color)
                Text(text)
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .floatingPanel(cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }
}
