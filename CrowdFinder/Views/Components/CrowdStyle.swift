import SwiftUI
import UIKit

// Colors follow the Google Maps palette so markers feel at home on the map.
extension CrowdLevel {
    var uiColor: UIColor {
        switch self {
        case .empty: UIColor(hex: 0x80868B)
        case .quiet: UIColor(hex: 0x1E8E3E)
        case .moderate: UIColor(hex: 0xF9AB00)
        case .busy: UIColor(hex: 0xE8710A)
        case .veryBusy: UIColor(hex: 0xD93025)
        }
    }

    var color: Color { Color(uiColor: uiColor) }

    /// Text color with enough contrast on top of `color`.
    var onColor: Color { self == .moderate ? .black : .white }
}

extension CrowdDataSource {
    var color: Color {
        switch self {
        case .live: Color(uiColor: UIColor(hex: 0xD93025))
        case .forecast: Color(uiColor: UIColor(hex: 0x1A73E8))
        case .estimate: .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .forecast: "chart.bar.fill"
        case .estimate: "wand.and.stars"
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Image {
    /// An SF Symbol that falls back to a generic pin if the symbol is missing on this iOS version.
    init(safeSystemName name: String, fallback: String = "mappin") {
        self.init(systemName: UIImage(systemName: name) == nil ? fallback : name)
    }
}

/// "LIVE" / "FORECAST" / "ESTIMATE" pill.
struct SourceBadge: View {
    let source: CrowdDataSource

    var body: some View {
        Label(source.badgeTitle, systemImage: source.symbolName)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(source.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(source.color.opacity(0.12), in: Capsule())
            .accessibilityLabel(source.explanation)
    }
}

/// Colored pill such as "72% · Busy".
struct CrowdPill: View {
    let busyness: Int
    var compact = false

    private var level: CrowdLevel { CrowdLevel(busyness: busyness) }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(busyness)%")
                .monospacedDigit()
            if !compact {
                Text("·")
                Text(level.title)
            }
        }
        .font(.system(size: compact ? 12 : 13, weight: .bold, design: .rounded))
        .foregroundStyle(level.onColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(level.color, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(level.title), \(busyness) percent busy")
    }
}

/// Small colored legend for the map.
struct CrowdLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(CrowdLevel.legendLevels, id: \.self) { level in
                HStack(spacing: 4) {
                    Circle().fill(level.color).frame(width: 8, height: 8)
                    Text(level.title)
                }
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Legend: green quiet, yellow moderate, orange busy, red very busy")
    }
}

/// Rounded "glass" background used by the floating panels.
struct FloatingPanel: ViewModifier {
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

extension View {
    func floatingPanel(cornerRadius: CGFloat = 18) -> some View {
        modifier(FloatingPanel(cornerRadius: cornerRadius))
    }

    /// Reports this view's height (used to keep the Google logo and markers clear of overlays).
    func onHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { action(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, newHeight in action(newHeight) }
            }
        )
    }
}
