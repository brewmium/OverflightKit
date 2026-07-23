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

/// The leading tip of a still-active track: where the aircraft is right now,
/// and which way it's pointed.
struct TrackHead: Identifiable, Sendable {
	let id: String
	let lat: Double
	let lon: Double
	let headingDeg: Double?
	let cls: SegmentClass
	let colorIndex: Int
}

/// One currently-active aircraft (heard within the last two minutes),
/// for the "Active now" panel.
struct ActiveFlight: Identifiable, Sendable {
	let id: String
	let name: String
	let typeCode: String?
	let aglFt: Double?
	let altSource: AltitudeSource
	let onGround: Bool
	let gsKt: Double?
	let lastTs: Int64
	let colorIndex: Int
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
	private(set) var trackHeads: [TrackHead] = []
	private(set) var activeFlights: [ActiveFlight] = []
	private(set) var mapRevision = 0
	private(set) var lastLoaded: Date?

	var autoRefresh = true
	private var refreshTask: Task<Void, Never>?
	private var altimeters: AltimeterHistory?
	/// Sticky identity-color slot per aircraft hex, held while it stays active.
	private var identitySlots: [String: Int] = [:]

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
		rebuildTrackHeads()
		mapRevision += 1
	}

	/// Head markers and the "Active now" list for tracks still receiving
	/// observations — last point within two minutes of the newest poll.
	/// Historical tracks end without a head so weeks of accumulated lines
	/// don't sprout hundreds of triangles. Heads respect the band filters;
	/// the active list deliberately does not, so it always answers "what's
	/// up there right now."
	private func rebuildTrackHeads() {
		guard let nowTs = pollStats?.lastTs else {
			trackHeads = []
			activeFlights = []
			return
		}
		let cutoff = nowTs - 120
		let activeTracks = tracks.filter { ($0.points.last?.ts ?? 0) >= cutoff }

		// Color slots follow the aircraft (hex), not its list position: keep
		// existing assignments, release ones that went quiet, give newcomers
		// the lowest free slot. Past 8 live aircraft, hues repeat.
		let activeHexes = Set(activeTracks.map(\.hex))
		identitySlots = identitySlots.filter { activeHexes.contains($0.key) }
		for t in activeTracks where identitySlots[t.hex] == nil {
			let used = Set(identitySlots.values)
			identitySlots[t.hex] = (0..<8).first { !used.contains($0) } ?? identitySlots.count % 8
		}

		var heads: [TrackHead] = []
		var active: [ActiveFlight] = []
		for t in activeTracks {
			guard let last = t.points.last else { continue }
			let colorIndex = identitySlots[t.hex] ?? 0
			active.append(ActiveFlight(
				id: t.id, name: t.displayName, typeCode: t.typeCode,
				aglFt: last.aglFt, altSource: last.altSource, onGround: last.onGround,
				gsKt: last.gsKt, lastTs: last.ts, colorIndex: colorIndex
			))
			let cls: SegmentClass
			if last.onGround {
				cls = .ground
			} else if let agl = last.aglFt {
				cls = .band(AltitudeBand.classify(aglFt: agl).rawValue)
			} else {
				cls = .unknownAlt
			}
			guard isEnabled(cls) else { continue }
			var heading = last.trackDeg
			if heading == nil, t.points.count >= 2 {
				let prev = t.points[t.points.count - 2]
				heading = Geo.bearingDeg(lat1: prev.lat, lon1: prev.lon, lat2: last.lat, lon2: last.lon)
			}
			heads.append(TrackHead(
				id: t.id, lat: last.lat, lon: last.lon, headingDeg: heading,
				cls: cls, colorIndex: colorIndex
			))
		}
		trackHeads = heads
		// Lowest traffic first — that's the interesting end; ground and
		// unknown-altitude at the bottom.
		activeFlights = active.sorted { a, b in
			let ka = a.onGround ? 2.0e9 : (a.aglFt ?? 1.0e9)
			let kb = b.onGround ? 2.0e9 : (b.aglFt ?? 1.0e9)
			return ka < kb
		}
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

	/// Called only from the date pickers' binding setters, so programmatic
	/// writes during reload never masquerade as a user edit.
	func setCustomRange(start: Date? = nil, end: Date? = nil) {
		if let start { rangeStart = start }
		if let end { rangeEnd = end }
		rangePreset = .custom
		Task { await reload() }
	}
}
