import SwiftUI

/// Details for one place: crowd now, advice, hourly pattern and directions.
struct PlaceDetailView: View {
    let place: Place
    let model: CrowdMapViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var selectedWeekday: Int?

    private var report: CrowdReport? { model.report(for: place) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let report {
                        statusCard(report)
                        adviceCard(report)
                        if report.forecast != nil {
                            chartCard(report)
                        }
                        if let note = report.note {
                            Label(note, systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack {
                            ProgressView()
                            Text("Checking how crowded it is…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                    }
                    actions
                    Text(report?.source.explanation ?? CrowdDataSource.estimate.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle(place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.usesRealData {
                        Button {
                            model.loadLiveData(for: place)
                        } label: {
                            if model.isLoadingLive(place) {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(model.isLoadingLive(place))
                        .accessibilityLabel("Refresh live data")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(place.category.displayName, systemImage: place.category.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(place.address)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let rating = place.rating {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text(rating.formatted(.number.precision(.fractionLength(1))))
                    if let count = place.userRatingCount {
                        Text("(\(count.formatted()) Google reviews)").foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
        }
    }

    private func statusCard(_ report: CrowdReport) -> some View {
        let level = report.level
        let now = Date()
        return HStack(spacing: 16) {
            CrowdGauge(busyness: report.currentBusyness)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(level.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(level.color)
                    SourceBadge(source: report.source)
                }
                if let delta = report.liveDelta, let usual = report.usualBusyness {
                    Text(liveComparison(delta: delta, usual: usual))
                        .font(.subheadline)
                }
                if report.clock.differsFromDevice(at: now) {
                    Label("Local time \(report.clock.localTimeString(at: now))", systemImage: "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.isLoadingLive(place) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Getting live data…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(level.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func adviceCard(_ report: CrowdReport) -> some View {
        let advice = VisitAdvice(report: report, at: Date())
        let (symbol, tint) = adviceStyle(advice.verdict)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(advice.headline).font(.headline)
                Text(advice.detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func chartCard(_ report: CrowdReport) -> some View {
        let now = Date()
        let localHour = report.clock.localHour(at: now)
        let today = WeeklyForecast.dayWindowWeekday(for: localHour)
        let weekday = selectedWeekday ?? today
        let isToday = weekday == today

        return VStack(alignment: .leading, spacing: 10) {
            Text("Popular times").font(.headline)

            Picker("Day", selection: Binding(get: { weekday }, set: { selectedWeekday = $0 })) {
                ForEach(0..<7, id: \.self) { day in
                    Text(HourFormatter.weekdayName(day, short: true)).tag(day)
                }
            }
            .pickerStyle(.segmented)

            if let forecast = report.forecast {
                HourlyCrowdChart(
                    hours: forecast.dayWindow(weekday: weekday),
                    currentHour: isToday ? localHour.hour : nil,
                    liveBusyness: isToday && report.source == .live ? report.currentBusyness : nil
                )
                if let quiet = forecast.dayWindow(weekday: weekday).filter({ $0.busyness > 0 }).min(by: { $0.busyness < $1.busyness }),
                   let peak = forecast.dayWindow(weekday: weekday).max(by: { $0.busyness < $1.busyness }), peak.busyness > 0 {
                    HStack {
                        Label("Quietest \(HourFormatter.string(for: quiet.hour))", systemImage: "leaf.fill")
                            .foregroundStyle(CrowdLevel.quiet.color)
                        Spacer()
                        Label("Busiest \(HourFormatter.string(for: peak.hour))", systemImage: "flame.fill")
                            .foregroundStyle(CrowdLevel.veryBusy.color)
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Link(destination: GoogleMapsLinks.directions(to: place)) {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Link(destination: GoogleMapsLinks.place(place)) {
                Label("Google Maps", systemImage: "map.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            ShareLink(item: GoogleMapsLinks.place(place), message: Text(shareMessage)) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Share")
        }
        .controlSize(.large)
    }

    // MARK: - Helpers

    private var shareMessage: String {
        guard let report else { return place.name }
        return "\(place.name) is \(report.level.title.lowercased()) right now (\(report.currentBusyness)% busy) – checked with Crowd Finder."
    }

    private func liveComparison(delta: Int, usual: Int) -> String {
        switch delta {
        case 6...: "Busier than usual (usually \(usual)% now)"
        case ...(-6): "Quieter than usual (usually \(usual)% now)"
        default: "About as busy as usual"
        }
    }

    private func adviceStyle(_ verdict: VisitAdvice.Verdict) -> (String, Color) {
        switch verdict {
        case .goNow: ("checkmark.circle.fill", CrowdLevel.quiet.color)
        case .goLater: ("clock.badge.checkmark.fill", CrowdLevel.moderate.color)
        case .expectCrowds: ("person.3.fill", CrowdLevel.veryBusy.color)
        case .closedNow: ("moon.zzz.fill", CrowdLevel.empty.color)
        }
    }
}

/// Circular gauge showing the busyness percentage.
struct CrowdGauge: View {
    let busyness: Int

    private var level: CrowdLevel { CrowdLevel(busyness: busyness) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(level.color.opacity(0.18), lineWidth: 10)
            Circle()
                .trim(from: 0, to: CGFloat(min(busyness, 100)) / 100)
                .stroke(level.color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(busyness)%")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("busy")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 86, height: 86)
        .animation(.easeOut(duration: 0.6), value: busyness)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(busyness) percent busy")
    }
}
