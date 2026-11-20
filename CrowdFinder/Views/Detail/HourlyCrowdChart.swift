import SwiftUI

/// One day's crowd pattern (6 AM → 5 AM next morning), one row per hour.
///
/// A row per hour keeps every time label readable on a phone; 24 labels side by side
/// under a bar chart don't fit and overlap.
struct HourlyCrowdChart: View {
    let hours: [HourValue]
    /// Clock hour to highlight ("now"), if the chart shows today.
    let currentHour: Int?
    /// Live value for the current hour, if any.
    let liveBusyness: Int?

    /// 100 % fills the bar; live values above 100 % are capped visually.
    private var scale: Double { Double(max(100, hours.map(\.busyness).max() ?? 0)) }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(hours, id: \.hour) { item in
                row(for: item)
            }
        }
    }

    private func row(for item: HourValue) -> some View {
        let isNow = item.hour == currentHour
        let value = isNow ? (liveBusyness ?? item.busyness) : item.busyness
        let level = CrowdLevel(busyness: value)
        let isLive = isNow && liveBusyness != nil

        return HStack(spacing: 10) {
            Text(HourFormatter.string(for: item.hour))
                .font(.caption.weight(isNow ? .bold : .regular))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(level.color.opacity(isNow || currentHour == nil ? 1 : 0.75))
                        .frame(width: proxy.size.width * min(1, Double(value) / scale))
                }
            }
            .frame(height: isNow ? 14 : 10)

            Group {
                if isNow {
                    Text(isLive ? "Live \(value)%" : "Now \(value)%")
                        .foregroundStyle(isLive ? CrowdDataSource.live.color : .primary)
                        .fontWeight(.bold)
                } else {
                    Text(value == 0 ? "–" : "\(value)%")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .monospacedDigit()
            .frame(width: 72, alignment: .leading)
            .lineLimit(1)
        }
        .padding(.vertical, isNow ? 5 : 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isNow ? level.color.opacity(0.15) : Color.clear)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HourFormatter.string(for: item.hour))
        .accessibilityValue(value == 0 ? "Usually empty" : "\(value) percent, \(level.title)\(isLive ? ", live" : "")")
    }
}
