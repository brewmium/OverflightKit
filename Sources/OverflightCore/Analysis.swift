import Foundation

/// Which altitude source produced a point's AGL value. Surfaced everywhere an
/// altitude is shown — a corrected and an uncorrected altitude are never
/// presented as equivalent.
public enum AltitudeSource: String, Sendable, Equatable {
	case geometric
	case baroCorrected
	case baroUncorrected
	case ground
	case unknown

	public var label: String {
		switch self {
		case .geometric: return "GNSS"
		case .baroCorrected: return "baro, corrected"
		case .baroUncorrected: return "baro, uncorrected"
		case .ground: return "on ground"
		case .unknown: return "no altitude"
		}
	}
}

/// Time-indexed altimeter settings from stored METARs; lookup picks the
/// nearest sample to an observation's timestamp, so corrections use the
/// pressure that was actually in effect, not today's.
public struct AltimeterHistory: Sendable {
	public let samples: [MetarSample]

	public init(samples: [MetarSample]) {
		self.samples = samples.sorted { $0.ts < $1.ts }
	}

	public func altimHpa(near ts: Int64, maxAgeS: Int64 = 10_800) -> Double? {
		guard !samples.isEmpty else { return nil }
		var lo = 0
		var hi = samples.count - 1
		while lo < hi {
			let mid = (lo + hi) / 2
			if samples[mid].ts < ts { lo = mid + 1 } else { hi = mid }
		}
		var best = samples[lo]
		if lo > 0, abs(samples[lo - 1].ts - ts) < abs(best.ts - ts) {
			best = samples[lo - 1]
		}
		return abs(best.ts - ts) <= maxAgeS ? best.altimHpa : nil
	}
}

public struct TrackPoint: Sendable, Equatable {
	public var ts: Int64
	public var lat: Double
	public var lon: Double
	public var aglFt: Double?
	public var altSource: AltitudeSource
	public var onGround: Bool
	public var gsKt: Double?
	public var trackDeg: Double?
	public var baroRateFpm: Int?

	public init(
		ts: Int64, lat: Double, lon: Double, aglFt: Double?,
		altSource: AltitudeSource, onGround: Bool = false,
		gsKt: Double? = nil, trackDeg: Double? = nil, baroRateFpm: Int? = nil
	) {
		self.ts = ts
		self.lat = lat
		self.lon = lon
		self.aglFt = aglFt
		self.altSource = altSource
		self.onGround = onGround
		self.gsKt = gsKt
		self.trackDeg = trackDeg
		self.baroRateFpm = baroRateFpm
	}
}

public struct Track: Sendable, Identifiable, Equatable {
	public var hex: String
	public var flight: String?
	public var reg: String?
	public var typeCode: String?
	public var points: [TrackPoint]

	public var id: String { "\(hex)-\(points.first?.ts ?? 0)" }

	public var displayName: String {
		flight ?? reg ?? hex
	}

	public init(hex: String, flight: String? = nil, reg: String? = nil, typeCode: String? = nil, points: [TrackPoint]) {
		self.hex = hex
		self.flight = flight
		self.reg = reg
		self.typeCode = typeCode
		self.points = points
	}
}

public enum AltitudeBand: Int, CaseIterable, Sendable, Hashable {
	case below1000 = 0
	case from1000to2000 = 1
	case from2000to5000 = 2
	case from5000to10000 = 3
	case above10000 = 4

	public static func classify(aglFt: Double) -> AltitudeBand {
		switch aglFt {
		case ..<1000: return .below1000
		case ..<2000: return .from1000to2000
		case ..<5000: return .from2000to5000
		case ...10_000: return .from5000to10000
		default: return .above10000
		}
	}

	public var label: String {
		switch self {
		case .below1000: return "<1000"
		case .from1000to2000: return "1000-2000"
		case .from2000to5000: return "2000-5000"
		case .from5000to10000: return "5000-10000"
		case .above10000: return ">10000"
		}
	}
}

public struct Overflight: Sendable, Identifiable, Equatable {
	public var track: Track
	public var closestDistanceM: Double
	public var closestPoint: TrackPoint
	public var insidePointCount: Int

	public var id: String { track.id }

	public init(track: Track, closestDistanceM: Double, closestPoint: TrackPoint, insidePointCount: Int) {
		self.track = track
		self.closestDistanceM = closestDistanceM
		self.closestPoint = closestPoint
		self.insidePointCount = insidePointCount
	}
}

public struct BandHistogram: Sendable, Equatable {
	/// Indexed by AltitudeBand.rawValue.
	public var counts: [Int]
	/// Overflights whose closest-approach point had no usable altitude.
	public var unknownCount: Int

	public init(counts: [Int] = Array(repeating: 0, count: AltitudeBand.allCases.count), unknownCount: Int = 0) {
		self.counts = counts
		self.unknownCount = unknownCount
	}
}

public struct CoverageDiagnostic: Sendable {
	public var airborneWithAgl: Int
	public var below2000: Int
	public var fractionBelow2000: Double
	public var minAglWithin5nmFt: Double?
	public var minAglHex: String?
	public var minAglTs: Int64?
	public var minAglSource: AltitudeSource?
	/// Airborne observation counts per altitude source, for the "which altitude
	/// am I actually looking at" breakdown.
	public var sourceCounts: [AltitudeSource: Int]

	/// False means the aggregator never saw anything below 2,000 ft AGL here —
	/// the dataset cannot answer questions about pattern-altitude traffic.
	public var patternVisible: Bool { below2000 > 0 }
}

public enum Analysis {
	static let inHgPerHpa = 0.029529983071445

	/// AGL for one observation, preferring GNSS altitude, then altimeter-corrected
	/// baro, then uncorrected baro. Returns the source used alongside the value.
	public static func agl(
		for o: AircraftObservation, fieldElevationFt: Double, altimeters: AltimeterHistory?
	) -> (aglFt: Double?, source: AltitudeSource) {
		if o.onGround { return (0, .ground) }
		if let g = o.altGeomFt {
			return (Double(g) - fieldElevationFt, .geometric)
		}
		if let b = o.altBaroFt {
			if let hpa = altimeters?.altimHpa(near: o.ts) {
				// alt_baro is pressure altitude (29.92 reference). True altitude
				// ~= pressure altitude + 1000 ft per inHg above standard.
				let corrected = Double(b) + (hpa * inHgPerHpa - 29.92) * 1000
				return (corrected - fieldElevationFt, .baroCorrected)
			}
			return (Double(b) - fieldElevationFt, .baroUncorrected)
		}
		return (nil, .unknown)
	}

	/// Group observations by hex and split into tracks wherever the gap between
	/// consecutive observations exceeds `gapS` seconds.
	public static func tracks(
		from observations: [AircraftObservation], gapS: Int64 = 300,
		fieldElevationFt: Double, altimeters: AltimeterHistory?
	) -> [Track] {
		var byHex: [String: [AircraftObservation]] = [:]
		for o in observations {
			byHex[o.hex, default: []].append(o)
		}

		var out: [Track] = []
		for (hex, group) in byHex {
			let sorted = group.sorted { $0.ts < $1.ts }
			var points: [TrackPoint] = []
			var flight: String?
			var reg: String?
			var typeCode: String?
			var lastTs: Int64?

			func flush() {
				if !points.isEmpty {
					out.append(Track(hex: hex, flight: flight, reg: reg, typeCode: typeCode, points: points))
				}
				points = []
				flight = nil
				reg = nil
				typeCode = nil
			}

			for o in sorted {
				if let lt = lastTs, o.ts - lt > gapS {
					flush()
				}
				let (aglFt, source) = agl(for: o, fieldElevationFt: fieldElevationFt, altimeters: altimeters)
				points.append(TrackPoint(
					ts: o.ts, lat: o.lat, lon: o.lon, aglFt: aglFt, altSource: source,
					onGround: o.onGround, gsKt: o.gsKt, trackDeg: o.trackDeg, baroRateFpm: o.baroRateFpm
				))
				if let f = o.flight { flight = f }
				if let r = o.reg { reg = r }
				if let t = o.typeCode { typeCode = t }
				lastTs = o.ts
			}
			flush()
		}
		out.sort { ($0.points.first?.ts ?? 0) < ($1.points.first?.ts ?? 0) }
		return out
	}

	/// Every track with at least one airborne observation inside the cylinder of
	/// `radiusM` around the parcel centroid, with closest approach distance and
	/// the point (altitude included) at closest approach. Ground observations
	/// never qualify — a taxiing aircraft is not an overflight.
	public static func overflights(
		tracks: [Track], parcelLat: Double, parcelLon: Double, radiusM: Double
	) -> [Overflight] {
		var out: [Overflight] = []
		for t in tracks {
			var minD = Double.greatestFiniteMagnitude
			var minP: TrackPoint?
			var inside = 0
			for p in t.points where !p.onGround {
				let d = Geo.distanceM(lat1: parcelLat, lon1: parcelLon, lat2: p.lat, lon2: p.lon)
				if d <= radiusM { inside += 1 }
				if d < minD {
					minD = d
					minP = p
				}
			}
			if inside > 0, let mp = minP {
				out.append(Overflight(track: t, closestDistanceM: minD, closestPoint: mp, insidePointCount: inside))
			}
		}
		out.sort { $0.closestPoint.ts < $1.closestPoint.ts }
		return out
	}

	/// Overflight counts bucketed by hour of day in the given timezone,
	/// timed at closest approach.
	public static func hourHistogram(_ overflights: [Overflight], timeZone: TimeZone) -> [Int] {
		var cal = Calendar(identifier: .gregorian)
		cal.timeZone = timeZone
		var counts = Array(repeating: 0, count: 24)
		for o in overflights {
			let hour = cal.component(.hour, from: Date(timeIntervalSince1970: Double(o.closestPoint.ts)))
			counts[hour] += 1
		}
		return counts
	}

	/// Overflight counts bucketed by AGL band at closest approach.
	public static func bandHistogram(_ overflights: [Overflight]) -> BandHistogram {
		var h = BandHistogram()
		for o in overflights {
			if let agl = o.closestPoint.aglFt {
				h.counts[AltitudeBand.classify(aglFt: agl).rawValue] += 1
			} else {
				h.unknownCount += 1
			}
		}
		return h
	}

	/// The sanity check on whether the aggregator can see pattern traffic here at all.
	public static func coverage(
		observations: [AircraftObservation], siteLat: Double, siteLon: Double,
		fieldElevationFt: Double, altimeters: AltimeterHistory?
	) -> CoverageDiagnostic {
		var withAgl = 0
		var below2000 = 0
		var minAgl: Double?
		var minHex: String?
		var minTs: Int64?
		var minSource: AltitudeSource?
		var sourceCounts: [AltitudeSource: Int] = [:]
		let fiveNmM = 5 * Geo.metersPerNm

		for o in observations where !o.onGround {
			let (aglFt, source) = agl(for: o, fieldElevationFt: fieldElevationFt, altimeters: altimeters)
			sourceCounts[source, default: 0] += 1
			guard let agl = aglFt else { continue }
			withAgl += 1
			if agl < 2000 { below2000 += 1 }
			let d = Geo.distanceM(lat1: siteLat, lon1: siteLon, lat2: o.lat, lon2: o.lon)
			if d <= fiveNmM, agl < (minAgl ?? .greatestFiniteMagnitude) {
				minAgl = agl
				minHex = o.hex
				minTs = o.ts
				minSource = source
			}
		}

		return CoverageDiagnostic(
			airborneWithAgl: withAgl,
			below2000: below2000,
			fractionBelow2000: withAgl > 0 ? Double(below2000) / Double(withAgl) : 0,
			minAglWithin5nmFt: minAgl,
			minAglHex: minHex,
			minAglTs: minTs,
			minAglSource: minSource,
			sourceCounts: sourceCounts
		)
	}
}
