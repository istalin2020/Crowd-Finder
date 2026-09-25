import SwiftUI
import UIKit

/// The pin drawn on the Google map: category icon + crowd percentage, colored by crowd level.
struct CrowdMarkerView: View {
    let category: PlaceCategory
    let busyness: Int?
    let isSelected: Bool

    static let shadowPadding: CGFloat = 4
    static let pointerHeight: CGFloat = 7

    private var level: CrowdLevel? { busyness.map(CrowdLevel.init(busyness:)) }
    private var fill: Color { level?.color ?? Color(uiColor: UIColor(hex: 0x5F6368)) }
    private var foreground: Color { level?.onColor ?? .white }

    var body: some View {
        VStack(spacing: -1) {
            HStack(spacing: 4) {
                Image(safeSystemName: category.symbolName)
                    .font(.system(size: 11, weight: .bold))
                Text(busyness.map { "\($0)%" } ?? "···")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(.white, lineWidth: isSelected ? 3 : 2))

            MarkerPointer()
                .fill(fill)
                .frame(width: 12, height: Self.pointerHeight)
        }
        .scaleEffect(isSelected ? 1.18 : 1, anchor: .bottom)
        .padding(.horizontal, isSelected ? 10 : Self.shadowPadding)
        .padding(.top, isSelected ? 8 : Self.shadowPadding)
        .padding(.bottom, Self.shadowPadding)
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

private struct MarkerPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Renders `CrowdMarkerView` to images for `GMSMarker.icon`, with a small cache.
@MainActor
enum CrowdMarkerRenderer {
    private struct Key: Hashable {
        let category: PlaceCategory
        let busyness: Int?
        let isSelected: Bool
        let scale: CGFloat
    }

    private static var cache: [Key: UIImage] = [:]

    static func image(category: PlaceCategory, busyness: Int?, isSelected: Bool, scale: CGFloat) -> UIImage {
        let key = Key(category: category, busyness: busyness, isSelected: isSelected, scale: scale)
        if let cached = cache[key] { return cached }

        let renderer = ImageRenderer(content: CrowdMarkerView(category: category, busyness: busyness, isSelected: isSelected))
        renderer.scale = scale
        let image = renderer.uiImage ?? UIImage()
        if cache.count > 300 { cache.removeAll() }
        cache[key] = image
        return image
    }

    /// Where the pointer tip sits inside the image (for `GMSMarker.groundAnchor`).
    static func groundAnchor(for image: UIImage) -> CGPoint {
        guard image.size.height > 0 else { return CGPoint(x: 0.5, y: 1) }
        let tipY = image.size.height - CrowdMarkerView.shadowPadding
        return CGPoint(x: 0.5, y: tipY / image.size.height)
    }
}
