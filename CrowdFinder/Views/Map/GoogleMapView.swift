import SwiftUI
import GoogleMaps

/// SwiftUI wrapper around the Google Maps SDK `GMSMapView`.
///
/// Markers are updated in place (not cleared and re-added on every change), so the map
/// stays smooth while crowd levels stream in.
struct GoogleMapView: UIViewRepresentable {
    var annotations: [CrowdAnnotation]
    var cameraCommand: MapCameraCommand?
    /// Space covered by floating panels. Keeps the Google logo visible and markers clear of the UI.
    var padding: UIEdgeInsets
    var showsUserLocation: Bool
    var onMarkerTap: (String) -> Void
    var onCameraIdle: (Coordinate, Double) -> Void
    var onMapTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> GMSMapView {
        let options = GMSMapViewOptions()
        // World view until we know where the user is or what they searched.
        options.camera = GMSCameraPosition(latitude: 20, longitude: 20, zoom: 1.8)

        let mapView = GMSMapView(options: options)
        mapView.delegate = context.coordinator
        mapView.overrideUserInterfaceStyle = .unspecified // follow light / dark mode
        mapView.settings.compassButton = true
        mapView.settings.myLocationButton = false // we show our own button
        mapView.settings.rotateGestures = true
        mapView.settings.tiltGestures = false
        mapView.padding = padding
        return mapView
    }

    func updateUIView(_ mapView: GMSMapView, context: Context) {
        context.coordinator.parent = self
        if mapView.padding != padding {
            mapView.padding = padding
        }
        if mapView.isMyLocationEnabled != showsUserLocation {
            mapView.isMyLocationEnabled = showsUserLocation
        }
        context.coordinator.sync(annotations, on: mapView)
        context.coordinator.apply(cameraCommand, on: mapView)
    }

    final class Coordinator: NSObject, GMSMapViewDelegate {
        var parent: GoogleMapView

        private struct Entry {
            let marker: GMSMarker
            let circle: GMSCircle
            var annotation: CrowdAnnotation
        }

        private var entries: [String: Entry] = [:]
        private var lastCommandID: UUID?

        init(parent: GoogleMapView) {
            self.parent = parent
        }

        // MARK: Markers

        @MainActor
        func sync(_ annotations: [CrowdAnnotation], on mapView: GMSMapView) {
            let wanted = Set(annotations.map(\.id))
            for (id, entry) in entries where !wanted.contains(id) {
                entry.marker.map = nil
                entry.circle.map = nil
                entries[id] = nil
            }

            let scale = mapView.traitCollection.displayScale > 0 ? mapView.traitCollection.displayScale : 3
            for annotation in annotations {
                if var entry = entries[annotation.id] {
                    guard entry.annotation != annotation else { continue }
                    configure(entry.marker, entry.circle, with: annotation, scale: scale)
                    entry.annotation = annotation
                    entries[annotation.id] = entry
                } else {
                    let position = annotation.coordinate.clLocationCoordinate
                    let marker = GMSMarker(position: position)
                    marker.userData = annotation.id
                    marker.appearAnimation = .pop
                    let circle = GMSCircle(position: position, radius: 100)
                    configure(marker, circle, with: annotation, scale: scale)
                    circle.map = mapView
                    marker.map = mapView
                    entries[annotation.id] = Entry(marker: marker, circle: circle, annotation: annotation)
                }
            }
        }

        /// A crowd "aura" around each place: bigger and stronger when busier.
        @MainActor
        private func configure(_ marker: GMSMarker, _ circle: GMSCircle, with annotation: CrowdAnnotation, scale: CGFloat) {
            let icon = CrowdMarkerRenderer.image(
                category: annotation.category,
                busyness: annotation.busyness,
                isSelected: annotation.isSelected,
                scale: scale
            )
            marker.icon = icon
            marker.groundAnchor = CrowdMarkerRenderer.groundAnchor(for: icon)
            marker.title = annotation.name
            marker.zIndex = annotation.isSelected ? 1_000 : Int32(annotation.busyness ?? 0)

            let busyness = Double(min(max(annotation.busyness ?? 0, 0), 120))
            let color = annotation.level?.uiColor ?? UIColor(hex: 0x5F6368)
            circle.position = annotation.coordinate.clLocationCoordinate
            circle.radius = 60 + busyness * 2.5
            circle.fillColor = color.withAlphaComponent(annotation.busyness == nil ? 0.05 : 0.10 + busyness / 100 * 0.15)
            circle.strokeColor = color.withAlphaComponent(0.45)
            circle.strokeWidth = 1
        }

        // MARK: Camera

        @MainActor
        func apply(_ command: MapCameraCommand?, on mapView: GMSMapView) {
            guard let command, command.id != lastCommandID else { return }
            lastCommandID = command.id

            switch command.kind {
            case let .focus(coordinate, zoom):
                let camera = GMSCameraPosition(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    zoom: zoom ?? max(mapView.camera.zoom, 15)
                )
                mapView.animate(to: camera)

            case let .fit(coordinates):
                guard let first = coordinates.first else { return }
                if coordinates.count == 1 {
                    mapView.animate(to: GMSCameraPosition(latitude: first.latitude, longitude: first.longitude, zoom: 15))
                    return
                }
                var bounds = GMSCoordinateBounds(coordinate: first.clLocationCoordinate, coordinate: first.clLocationCoordinate)
                for coordinate in coordinates.dropFirst() {
                    bounds = bounds.includingCoordinate(coordinate.clLocationCoordinate)
                }
                mapView.animate(with: GMSCameraUpdate.fit(bounds, withPadding: 48))
            }
        }

        // MARK: GMSMapViewDelegate

        func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
            if let id = marker.userData as? String {
                parent.onMarkerTap(id)
            }
            return true // we show our own detail sheet instead of the default info window
        }

        func mapView(_ mapView: GMSMapView, didTapAt coordinate: CLLocationCoordinate2D) {
            parent.onMapTap()
        }

        func mapView(_ mapView: GMSMapView, idleAt position: GMSCameraPosition) {
            let center = Coordinate(position.target)
            let farCorner = Coordinate(mapView.projection.visibleRegion().farRight)
            parent.onCameraIdle(center, center.distance(to: farCorner))
        }
    }
}
