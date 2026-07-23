import Foundation

public enum OverflightError: Error, CustomStringConvertible, Sendable {
	case sqlite(String)
	case notFound(String)
	case badResponse(String)
	case usage(String)

	public var description: String {
		switch self {
		case .sqlite(let m): return "sqlite: \(m)"
		case .notFound(let m): return m
		case .badResponse(let m): return m
		case .usage(let m): return m
		}
	}
}

/// `alt_baro` in the v2 API is either a number of feet or the literal string "ground".
public enum BaroAltitude: Equatable, Sendable {
	case ground
	case feet(Int)
}

/// One aircraft entry from an ADSBExchange-v2-compatible `/v2/point` response.
/// Field list verified against live api.adsb.lol and api.airplanes.live output 2026-07-23.
public struct Aircraft: Sendable, Equatable {
	public var hex: String
	public var flight: String?
	public var registration: String?
	public var typeCode: String?
	public var lat: Double?
	public var lon: Double?
	public var altBaro: BaroAltitude?
	public var altGeomFt: Int?
	public var groundSpeedKt: Double?
	public var trackDeg: Double?
	public var baroRateFpm: Int?
	public var squawk: String?
	public var seenPos: Double?
	public var rssi: Double?
	public var messages: Int?

	public init(
		hex: String, flight: String? = nil, registration: String? = nil,
		typeCode: String? = nil, lat: Double? = nil, lon: Double? = nil,
		altBaro: BaroAltitude? = nil, altGeomFt: Int? = nil,
		groundSpeedKt: Double? = nil, trackDeg: Double? = nil,
		baroRateFpm: Int? = nil, squawk: String? = nil,
		seenPos: Double? = nil, rssi: Double? = nil, messages: Int? = nil
	) {
		self.hex = hex
		self.flight = flight
		self.registration = registration
		self.typeCode = typeCode
		self.lat = lat
		self.lon = lon
		self.altBaro = altBaro
		self.altGeomFt = altGeomFt
		self.groundSpeedKt = groundSpeedKt
		self.trackDeg = trackDeg
		self.baroRateFpm = baroRateFpm
		self.squawk = squawk
		self.seenPos = seenPos
		self.rssi = rssi
		self.messages = messages
	}
}

extension Aircraft: Decodable {
	private enum CodingKeys: String, CodingKey {
		case hex, flight, r, t, lat, lon, gs, track, squawk, rssi, messages
		case altBaro = "alt_baro"
		case altGeom = "alt_geom"
		case baroRate = "baro_rate"
		case seenPos = "seen_pos"
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		hex = try c.decode(String.self, forKey: .hex)
		if let raw = try c.decodeIfPresent(String.self, forKey: .flight) {
			let trimmed = raw.trimmingCharacters(in: .whitespaces)
			flight = trimmed.isEmpty ? nil : trimmed
		}
		registration = try c.decodeIfPresent(String.self, forKey: .r)
		typeCode = try c.decodeIfPresent(String.self, forKey: .t)
		lat = try c.decodeIfPresent(Double.self, forKey: .lat)
		lon = try c.decodeIfPresent(Double.self, forKey: .lon)
		if let ft = try? c.decode(Double.self, forKey: .altBaro) {
			altBaro = .feet(Int(ft.rounded()))
		} else if let s = try? c.decode(String.self, forKey: .altBaro), s == "ground" {
			altBaro = .ground
		}
		altGeomFt = (try? c.decode(Double.self, forKey: .altGeom)).map { Int($0.rounded()) }
		groundSpeedKt = try c.decodeIfPresent(Double.self, forKey: .gs)
		trackDeg = try c.decodeIfPresent(Double.self, forKey: .track)
		baroRateFpm = (try? c.decode(Double.self, forKey: .baroRate)).map { Int($0.rounded()) }
		squawk = try c.decodeIfPresent(String.self, forKey: .squawk)
		seenPos = try c.decodeIfPresent(Double.self, forKey: .seenPos)
		rssi = try c.decodeIfPresent(Double.self, forKey: .rssi)
		messages = try c.decodeIfPresent(Int.self, forKey: .messages)
	}
}

/// Envelope: `{ "ac": [...], "msg": "No error", "now": <ms>, "total": n, ... }`
public struct PointResponse: Decodable, Sendable {
	public var ac: [Aircraft]
	public var now: Double?
	public var total: Int?

	private enum CodingKeys: String, CodingKey { case ac, now, total }

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		ac = try c.decodeIfPresent([Aircraft].self, forKey: .ac) ?? []
		now = try? c.decodeIfPresent(Double.self, forKey: .now)
		total = try? c.decodeIfPresent(Int.self, forKey: .total)
	}
}
