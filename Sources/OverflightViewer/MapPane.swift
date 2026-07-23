import SwiftUI
import MapKit
import OverflightCore

struct MapPane: NSViewRepresentable {
	@Environment(ViewerModel.self) private var model

	final class BandMultiPolyline: MKMultiPolyline {
		var segmentClass: SegmentClass = .unknownAlt
	}

	final class ParcelAnnotation: MKPointAnnotation {}
	final class SiteAnnotation: MKPointAnnotation {}

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> MKMapView {
		let map = MKMapView()
		map.mapType = .satellite
		map.delegate = context.coordinator
		map.showsCompass = true
		map.showsZoomControls = true
		context.coordinator.model = model

		let center = CLLocationCoordinate2D(latitude: model.config.site.lat, longitude: model.config.site.lon)
		let spanM = model.config.radiusNm * Geo.metersPerNm * 2.2
		map.setRegion(
			MKCoordinateRegion(center: center, latitudinalMeters: spanM, longitudinalMeters: spanM),
			animated: false
		)

		let site = SiteAnnotation()
		site.coordinate = center
		site.title = "Field"
		map.addAnnotation(site)

		return map
	}

	func updateNSView(_ map: MKMapView, context: Context) {
		let coord = context.coordinator
		coord.model = model
		if coord.overlayRevision != model.mapRevision {
			coord.overlayRevision = model.mapRevision
			coord.rebuildTrackOverlays(map, segments: model.segmentsByClass)
		}
		coord.syncParcel(map, lat: model.parcelLat, lon: model.parcelLon, radiusM: model.parcelRadiusM)
	}

	@MainActor
	final class Coordinator: NSObject, @preconcurrency MKMapViewDelegate {
		var model: ViewerModel?
		var overlayRevision = -1
		private var parcelAnnotation: ParcelAnnotation?
		private var parcelCircle: MKCircle?
		private var lastParcel: (lat: Double, lon: Double, radiusM: Double) = (.nan, .nan, .nan)

		func rebuildTrackOverlays(_ map: MKMapView, segments: [SegmentClass: [[CLLocationCoordinate2D]]]) {
			map.removeOverlays(map.overlays.filter { $0 is BandMultiPolyline })
			// Draw order: ground first, then high bands down to low, so the
			// low-altitude traffic — the interesting signal — sits on top.
			var order: [SegmentClass] = [.ground, .unknownAlt]
			order += AltitudeBand.allCases.reversed().map { .band($0.rawValue) }
			for cls in order {
				guard let runs = segments[cls], !runs.isEmpty else { continue }
				let polylines = runs.map { run in
					MKPolyline(coordinates: run, count: run.count)
				}
				let multi = BandMultiPolyline(polylines)
				multi.segmentClass = cls
				map.addOverlay(multi, level: .aboveLabels)
			}
		}

		func syncParcel(_ map: MKMapView, lat: Double, lon: Double, radiusM: Double) {
			guard lastParcel != (lat, lon, radiusM) else { return }
			lastParcel = (lat, lon, radiusM)

			let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
			if parcelAnnotation == nil {
				let ann = ParcelAnnotation()
				ann.title = "Parcel"
				parcelAnnotation = ann
				map.addAnnotation(ann)
			}
			parcelAnnotation?.coordinate = coordinate

			if let old = parcelCircle {
				map.removeOverlay(old)
			}
			let circle = MKCircle(center: coordinate, radius: radiusM)
			map.addOverlay(circle, level: .aboveLabels)
			parcelCircle = circle
		}

		func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
			if let multi = overlay as? BandMultiPolyline {
				let r = MKMultiPolylineRenderer(multiPolyline: multi)
				switch multi.segmentClass {
				case .band(let i):
					r.strokeColor = Viz.mapBand[min(max(i, 0), Viz.mapBand.count - 1)]
				case .ground:
					r.strokeColor = Viz.mapGround
				case .unknownAlt:
					r.strokeColor = Viz.mapUnknown
				}
				r.lineWidth = 2
				return r
			}
			if let circle = overlay as? MKCircle {
				let r = MKCircleRenderer(circle: circle)
				r.fillColor = Viz.parcelFill
				r.strokeColor = Viz.parcelStroke
				r.lineWidth = 1.5
				return r
			}
			return MKOverlayRenderer(overlay: overlay)
		}

		func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
			if annotation is ParcelAnnotation {
				let id = "parcel"
				let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
					?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
				view.annotation = annotation
				view.isDraggable = true
				view.canShowCallout = false
				view.markerTintColor = Viz.parcelStroke
				view.glyphImage = NSImage(systemSymbolName: "scope", accessibilityDescription: "parcel")
				return view
			}
			if annotation is SiteAnnotation {
				let id = "site"
				let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
					?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
				view.annotation = annotation
				view.isDraggable = false
				view.canShowCallout = true
				view.markerTintColor = .gray
				view.glyphImage = NSImage(systemSymbolName: "airplane", accessibilityDescription: "field")
				return view
			}
			return nil
		}

		func mapView(
			_ mapView: MKMapView, annotationView view: MKAnnotationView,
			didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState
		) {
			guard view.annotation is ParcelAnnotation else { return }
			switch newState {
			case .ending:
				view.setDragState(.none, animated: true)
				if let coordinate = view.annotation?.coordinate {
					model?.parcelMoved(lat: coordinate.latitude, lon: coordinate.longitude)
				}
			case .canceling:
				view.setDragState(.none, animated: false)
			default:
				break
			}
		}
	}
}
