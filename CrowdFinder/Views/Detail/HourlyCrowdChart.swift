import SwiftUI
import Charts

/// Bar chart of one day's crowd pattern (6 AM → 5 AM), like Google's "Popular times".
struct HourlyCrowdChart: View {
    let hours: [HourValue]
    /// Clock hour to highlight ("now"), if the chart shows today.
    let currentHour: Int?
    /// Live value to draw on top of the current hour.
    let liveBusyness: Int?

    private static let labeledHours: Set<Int> = [6, 9, 12, 15, 18, 21, 0, 3]

    private var yMax: Int { max(100, liveBusyness ?? 0, hours.map(\.busyness).max() ?? 0) }

    var body: some View {
        Chart {
            ForEach(hours, id: \.hour) { item in
                BarMark(
                    x: .value("Hour", label(item.hour)),
                    y: .value("Busyness", item.busyness)
                )
                .foregroundStyle(CrowdLevel(busyness: item.busyness).color)
                .opacity(currentHour == nil || currentHour == item.hour ? 1 : 0.55)
                .cornerRadius(3)
                .accessibilityLabel(label(item.hour))
                .accessibilityValue("\(item.busyness) percent, \(CrowdLevel(busyness: item.busyness).title)")
            }

            if let currentHour {
                RuleMark(x: .value("Hour", label(currentHour)))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center) {
                        Text(liveBusyness == nil ? "Now" : "Live \(liveBusyness ?? 0)%")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(liveBusyness == nil ? Color.secondary : CrowdDataSource.live.color)
                    }
            }

            if let currentHour, let liveBusyness {
                PointMark(
                    x: .value("Hour", label(currentHour)),
                    y: .value("Busyness", liveBusyness)
                )
                .symbol(.circle)
                .symbolSize(70)
                .foregroundStyle(CrowdDataSource.live.color)
                .accessibilityLabel("Live now")
                .accessibilityValue("\(liveBusyness) percent")
            }
        }
        .chartYScale(domain: 0...yMax)
        .chartXAxis {
            AxisMarks(values: hours.filter { Self.labeledHours.contains($0.hour) }.map { label($0.hour) }) { _ in
                AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Int.self) { Text("\(percent)%") }
                }
            }
        }
        .frame(height: 170)
    }

    private func label(_ hour: Int) -> String {
        HourFormatter.string(for: hour)
    }
}
