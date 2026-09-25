import SwiftUI

/// A result card in the bottom carousel.
struct PlaceCard: View {
    let place: Place
    let report: CrowdReport?
    let busyness: Int?
    let isLoading: Bool
    let isSelected: Bool
    let hourOffset: Int

    private var level: CrowdLevel? { busyness.map(CrowdLevel.init(busyness:)) }

    /// Future hours come from the forecast (live data only exists for "now").
    private var displayedSource: CrowdDataSource? {
        guard let report else { return nil }
        if hourOffset == 0 || report.source == .estimate { return report.source }
        return .forecast
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(safeSystemName: place.category.symbolName)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(level?.color ?? .gray, in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(place.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(place.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 8) {
                if let busyness {
                    CrowdPill(busyness: busyness)
                } else if isLoading {
                    ProgressView().controlSize(.small)
                    Text("Checking crowd…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No crowd data").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let displayedSource {
                    SourceBadge(source: displayedSource)
                }
            }

            HStack(spacing: 4) {
                if let level {
                    Image(systemName: level.adviceSymbolName)
                        .foregroundStyle(level.color)
                    Text(hourOffset == 0 ? level.advice : "In \(hourOffset) h: \(level.title.lowercased())")
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let rating = place.rating {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text(ratingText(rating)).foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.medium))
        }
        .padding(12)
        .frame(width: 285, alignment: .leading)
        .floatingPanel()
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isSelected ? (level?.color ?? .accentColor) : .clear, lineWidth: 2)
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows crowd details")
    }

    private func ratingText(_ rating: Double) -> String {
        let value = rating.formatted(.number.precision(.fractionLength(1)))
        guard let count = place.userRatingCount else { return value }
        return "\(value) (\(count.formatted(.number.notation(.compactName))))"
    }
}

/// "Crowd at: Now · +1h · +2h …" selector.
struct TimeSelector: View {
    @Binding var hourOffset: Int
    @Binding var sortOrder: PlaceSortOrder

    private let offsets = [0, 1, 2, 3, 4, 6, 8, 12]

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(offsets, id: \.self) { offset in
                        let isSelected = offset == hourOffset
                        Button {
                            withAnimation(.snappy) { hourOffset = offset }
                        } label: {
                            Text(offset == 0 ? "Now" : "+\(offset)h")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                .background(isSelected ? Color.accentColor : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(offset == 0 ? "Crowd now" : "Crowd in \(offset) hours")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 10)
            }

            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(PlaceSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
            }
            .padding(.trailing, 8)
            .accessibilityLabel("Sort results")
        }
        .frame(height: 42)
        .floatingPanel(cornerRadius: 21)
    }
}

/// Shown before the first search.
struct WelcomeCard: View {
    let usesRealData: Bool
    let onExample: (String) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.3.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        LinearGradient(colors: [CrowdLevel.quiet.color, CrowdLevel.veryBusy.color],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("How crowded is it?").font(.headline)
                    Text("Search any place or city before you go.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(QuickSearch.examples, id: \.self) { example in
                        Button(example) { onExample(example) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                    }
                }
            }

            if !usesRealData {
                Button(action: onOpenSettings) {
                    Label("Showing estimates. Add a free BestTime key for real foot-traffic data.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            CrowdLegend()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingPanel()
    }
}
