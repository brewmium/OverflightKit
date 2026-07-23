import Foundation
import Observation
import CoreLocation
import OverflightCore

enum SegmentClass: Hashable, Sendable {
	case band(Int)
	case ground
	case unknownAlt
}

enum RangePreset: Hashable {
	case day, week, month, all, custom
}

@MainActor
@Observable
final class ViewerModel {
	var config: Config
	private(set) var store: Store?
	private(set) var loadError: String?
	private(set) var loading = false

	// Filters
	var rangeStart: Date
	var rangeEnd: Date
	var rangePreset: RangePreset = .week
	/// Guard so programmatic date writes don't re-trigger the custom-range path.
	private(set) var settingDatesProgrammatically = false
	var enabledBands: Set<AltitudeBand> = Set(AltitudeBand.allCases)
	var showGround = false

	// Parcel
	var parcelLat: Double
	var parcelLon: Double
	var parcelRadiusM: Double

	// Data
	private(set) var tracks: [Track] = []
	private(set) var overflights: [Overflight] = []
	private(set) var hourHist: [Int] = Array(repeating: 0, count: 24)
	private(set) var bandHist = BandHistogram()
	private(set) var coverage: CoverageDiagnostic?
	private(set) var pollStats: PollStats?
	private(set) var segmentsByClass: [SegmentClass: [[CLLocationCoordinate2D]]] = [:]
	private(set) var mapRevision = 0
	private(set) var lastLoaded: Date?

	var autoRefresh = true
	private var refreshTask: Task<Void, Never>?
	private var altimeters: AltimeterHistory?

	init() {
		let cfg = (try? Config.load()) ?? .kgmjDefault
		config = cfg
		parcelLat = cfg.parcel.lat
		parcelLon = cfg.parcel.lon
		parcelRadiusM = cfg.parcel.radiusM
		let now = Date()
		rangeEnd = now
		rangeStart = now.addingTimeInterval(-7 * 86_400)
	}

	func start() {
		guard refreshTask == nil else { return }
		refreshTask = Task { [weak self] in
			while !Task.isCancelled {
				guard let self else { return }
				if self.autoRefresh || self.lastLoaded == nil {
					await self.reload()
				}
				try? await Task.sleep(for: .seconds(30))
			}
		}
	}

	func reload() async {
		guard !loading else { return }
		loading = true
		defer { loading = false }
		do {
			if store == nil {
				store = try Store(path: config.expandedDbPath, readOnly: true)
			}
			guard let store else { return }

			if rangePreset != .custom {
				settingDatesProgrammatically = true
				rangeEnd = Date()
				switch rangePreset {
				case .day: rangeStart = rangeEnd.addingTimeInterval(-86_400)
				case .week: rangeStart = rangeEnd.addingTimeInterval(-7 * 86_400)
				case .month: rangeStart = rangeEnd.addingTimeInterval(-30 * 86_400)
				case .all:
					if let bounds = try await store.observationTimeBounds() {
						rangeStart = Date(timeIntervalSince1970: Double(bounds.first))
					}
				case .custom: break
				}
				settingDatesProgrammatically = false
			}

			let from = Int64(rangeStart.timeIntervalSince1970)
			let to = Int64(rangeEnd.timeIntervalSince1970)
			let obs = try await store.observations(from: from, to: to)
			let metars = try await store.metarSamples(from: from - 10_800, to: to + 10_800)
			pollStats = try await store.pollStats(gapThresholdS: 300, expectedIntervalS: config.pollIntervalS)

			let cfg = config
			let alts = AltimeterHistory(samples: metars)
			altimeters = alts
			let built = await Task.detached {
				let t = Analysis.tracks(from: obs, fieldElevationFt: cfg.site.fieldElevationFt, altimeters: alts)
				let c = Analysis.coverage(
					observations: obs, siteLat: cfg.site.lat, siteLon: cfg.site.lon,
					fieldElevationFt: cfg.site.fieldElevationFt, altimeters: alts
				)
				return (t, c)
			}.value

			tracks = built.0
			coverage = built.1
			recomputeStats()
			rebuildSegments()
			loadError = nil
			lastLoaded = Date()
		} catch {
			loadError = "\(error)"
			store = nil
		}
	}

	/// Overflights + histograms. Cheap enough to run on every parcel move.
	func recomputeStats() {
		let ofs = Analysis.overflights(
			tracks: tracks, parcelLat: parcelLat, parcelLon: parcelLon, radiusM: parcelRadiusM
		)
		overflights = ofs
		hourHist = Analysis.hourHistogram(ofs, timeZone: config.timeZone)
		bandHist = Analysis.bandHistogram(ofs)
	}

	/// Map polyline geometry, split wherever the altitude band changes so each
	/// run can wear its band color; disabled bands are dropped here.
	func rebuildSegments() {
		var out: [SegmentClass: [[CLLocationCoordinate2D]]] = [:]
		for t in tracks {
			var runClass: SegmentClass?
			var run: [CLLocationCoordinate2D] = []

			func flush() {
				if run.count >= 2, let rc = runClass, isEnabled(rc) {
					out[rc, default: []].append(run)
				}
			}

			for p in t.points {
				let cls: SegmentClass
				if p.onGround {
					cls = .ground
				} else if let agl = p.aglFt {
					cls = .band(AltitudeBand.classify(aglFt: agl).rawValue)
				} else {
					cls = .unknownAlt
				}
				let coord = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
				if cls != runClass {
					flush()
					// Carry the previous point over so the polyline stays continuous
					// across a band change.
					var newRun: [CLLocationCoordinate2D] = []
					if let lastCoord = run.last { newRun.append(lastCoord) }
					newRun.append(coord)
					run = newRun
					runClass = cls
				} else {
					run.append(coord)
				}
			}
			flush()
		}
		segmentsByClass = out
		mapRevision += 1
	}

	private func isEnabled(_ cls: SegmentClass) -> Bool {
		switch cls {
		case .band(let i):
			guard let band = AltitudeBand(rawValue: i) else { return false }
			return enabledBands.contains(band)
		case .ground:
			return showGround
		case .unknownAlt:
			return true
		}
	}

	/// Overflight list filtered by the enabled-band toggles (closest-approach band).
	var visibleOverflights: [Overflight] {
		overflights.filter { of in
			guard let agl = of.closestPoint.aglFt else { return true }
			return enabledBands.contains(AltitudeBand.classify(aglFt: agl))
		}
	}

	func bandFilterChanged() {
		rebuildSegments()
	}

	func parcelMoved(lat: Double, lon: Double) {
		parcelLat = lat
		parcelLon = lon
		recomputeStats()
	}

	func resetParcelToSite() {
		parcelLat = config.site.lat
		parcelLon = config.site.lon
		recomputeStats()
	}

	func saveParcelToConfig() {
		config.parcel = Config.Parcel(lat: parcelLat, lon: parcelLon, radiusM: parcelRadiusM)
		do {
			try config.save()
		} catch {
			loadError = "saving config: \(error)"
		}
	}

	func setPreset(_ p: RangePreset) {
		rangePreset = p
		Task { await reload() }
	}

	func customRangeEdited() {
		guard !settingDatesProgrammatically else { return }
		rangePreset = .custom
		Task { await reload() }
	}
}
