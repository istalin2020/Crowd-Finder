import SwiftUI

/// "Live from visitors": shows recent reports and lets people at the place report the crowd.
struct LiveReportSection: View {
    let place: Place
    let model: CrowdMapViewModel

    @State private var scanner = NearbyDeviceScanner()

    private var report: CrowdReport? { model.report(for: place) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Live from visitors", systemImage: "person.3.fill")
                    .font(.headline)
                Spacer()
                if let refreshed = model.lastLiveRefresh {
                    Text("Updated \(minutesAgo(refreshed))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            summary

            Divider()

            reportControls

            if let feedback = model.reportFeedback, feedback.placeID == place.id {
                Label(feedback.text, systemImage: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(feedback.isError ? CrowdLevel.busy.color : CrowdLevel.quiet.color)
            }
            if let problem = model.communityProblem {
                Label("Live reports: \(problem)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onDisappear { scanner.stop() }
    }

    // MARK: - Parts

    @ViewBuilder
    private var summary: some View {
        if let live = report?.liveSummary {
            HStack(spacing: 8) {
                CrowdPill(busyness: live.busyness)
                Text("\(live.reportCount) report\(live.reportCount == 1 ? "" : "s") · newest \(minutesAgo(live.newestReportAt))")
                    .font(.subheadline)
            }
        } else {
            Text(model.supportsLiveReports
                 ? "No visitor reports in the last 90 minutes. The crowd shown is the usual pattern, not a live count."
                 : "Live reports are off, so the crowd shown is the usual pattern, not a live count.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var reportControls: some View {
        switch model.reportEligibility(for: place) {
        case .allowed:
            VStack(alignment: .leading, spacing: 10) {
                Text("You're here – how crowded is it right now?")
                    .font(.subheadline.weight(.semibold))
                levelButtons
                measureRow
            }
        case .notConfigured:
            hint("Turn on live reports in Settings → Live crowd reports, so visitors can share the crowd in real time.",
                 symbol: "gearshape")
        case .locationUnknown:
            hint("Allow location access to report the crowd here. Only people at the place can report.",
                 symbol: "location.slash")
        case .tooFar(let meters):
            hint("You're \(distanceText(meters)) away. Reports can only be sent from the place (within 1.5 km).",
                 symbol: "location")
        case .coolingDown(let minutes):
            hint("Thanks for reporting! You can report this place again in \(minutes) min.",
                 symbol: "checkmark.circle")
        }
    }

    private var levelButtons: some View {
        let suggested = scanner.suggestedLevel
        return HStack(spacing: 8) {
            ForEach(CommunityCrowdReport.reportableLevels, id: \.self) { level in
                Button {
                    model.submitLiveReport(level, for: place)
                } label: {
                    VStack(spacing: 2) {
                        Text(level.title)
                            .font(.footnote.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if level == suggested {
                            Text("suggested").font(.caption2)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .foregroundStyle(level.onColor)
                    .background(level.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary, lineWidth: level == suggested ? 2 : 0)
                    )
                }
                .buttonStyle(.plain)
                .disabled(model.submittingReportPlaceID != nil)
                .accessibilityLabel("Report \(level.title)")
            }
        }
        .overlay {
            if model.submittingReportPlaceID == place.id { ProgressView() }
        }
    }

    @ViewBuilder
    private var measureRow: some View {
        switch scanner.state {
        case .idle:
            Button {
                scanner.start()
            } label: {
                Label("Not sure? Measure around me (\(NearbyDeviceScanner.scanSeconds) s)",
                      systemImage: "dot.radiowaves.left.and.right")
                    .font(.footnote)
            }
        case .scanning(let secondsLeft):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Counting nearby phones and watches… \(secondsLeft) s")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .finished(let count):
            Text("About \(count) Bluetooth devices nearby → suggests \(NearbyDeviceScanner.level(forDeviceCount: count).title.lowercased()). A rough guide – please choose what you see.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .unavailable(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func hint(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func minutesAgo(_ date: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        return minutes == 0 ? "just now" : "\(minutes) min ago"
    }

    private func distanceText(_ meters: Double) -> String {
        meters < 1_000 ? "\(Int(meters)) m" : String(format: "%.1f km", meters / 1_000)
    }
}
