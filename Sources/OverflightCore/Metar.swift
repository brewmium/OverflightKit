import Foundation

/// A reporting station's identity and location, for ICAO-based site autofill.
public struct StationInfo: Sendable {
	public let icao: String
	public let name: String
	public let lat: Double
	public let lon: Double
	public let elevFt: Double
}

/// Fetches the latest METAR for a station from aviationweather.gov.
/// `altim` in that API is the altimeter setting in hectopascals;
/// `obsTime` is a unix epoch in seconds; `elev` is meters. Verified against
/// live output 2026-07-23.
public enum MetarClient {
	public static func fetchLatest(station: String, session: URLSession = .shared) async throws -> (sample: MetarSample, rawOb: String?) {
		var comps = URLComponents(string: "https://aviationweather.gov/api/data/metar")!
		comps.queryItems = [
			URLQueryItem(name: "ids", value: station),
			URLQueryItem(name: "format", value: "json"),
		]
		let (data, resp) = try await session.data(from: comps.url!)
		guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
			throw OverflightError.badResponse("metar fetch: http \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
		}
		struct Entry: Decodable {
			let obsTime: Int64?
			let altim: Double?
			let rawOb: String?
		}
		let entries = try JSONDecoder().decode([Entry].self, from: data)
		guard let e = entries.first, let ts = e.obsTime, let altim = e.altim else {
			throw OverflightError.badResponse("metar fetch: no report or missing altimeter for \(station)")
		}
		return (MetarSample(ts: ts, altimHpa: altim), e.rawOb)
	}

	/// Look up a station's coordinates, elevation, and name from its latest
	/// METAR — enough to autofill a new site from an ICAO identifier.
	public static func stationInfo(icao: String, session: URLSession = .shared) async throws -> StationInfo {
		var comps = URLComponents(string: "https://aviationweather.gov/api/data/metar")!
		comps.queryItems = [
			URLQueryItem(name: "ids", value: icao),
			URLQueryItem(name: "format", value: "json"),
		]
		let (data, resp) = try await session.data(from: comps.url!)
		guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
			throw OverflightError.badResponse("station lookup: http \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
		}
		struct Entry: Decodable {
			let icaoId: String?
			let name: String?
			let lat: Double?
			let lon: Double?
			let elev: Double?
		}
		let entries = try JSONDecoder().decode([Entry].self, from: data)
		guard let e = entries.first, let lat = e.lat, let lon = e.lon else {
			throw OverflightError.badResponse("no reporting station found for '\(icao)' — check the identifier")
		}
		return StationInfo(
			icao: e.icaoId ?? icao.uppercased(),
			name: cleanName(e.name) ?? icao.uppercased(),
			lat: lat, lon: lon,
			elevFt: (e.elev ?? 0) * 3.28084
		)
	}

	/// Nearest METAR-reporting station to a coordinate (bbox search, roughly
	/// 80 km), for place-name site autofill. Returns nil when nothing reports
	/// nearby.
	public static func nearestStation(lat: Double, lon: Double, session: URLSession = .shared) async throws -> StationInfo? {
		let d = 0.75
		var comps = URLComponents(string: "https://aviationweather.gov/api/data/metar")!
		comps.queryItems = [
			URLQueryItem(name: "bbox", value: String(format: "%.3f,%.3f,%.3f,%.3f", lat - d, lon - d, lat + d, lon + d)),
			URLQueryItem(name: "format", value: "json"),
		]
		let (data, resp) = try await session.data(from: comps.url!)
		guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
			throw OverflightError.badResponse("station search: http \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
		}
		struct Entry: Decodable {
			let icaoId: String?
			let name: String?
			let lat: Double?
			let lon: Double?
			let elev: Double?
		}
		let entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
		let best = entries.compactMap { e -> (StationInfo, Double)? in
			guard let id = e.icaoId, let elat = e.lat, let elon = e.lon else { return nil }
			let info = StationInfo(
				icao: id, name: cleanName(e.name) ?? id,
				lat: elat, lon: elon, elevFt: (e.elev ?? 0) * 3.28084
			)
			return (info, Geo.distanceM(lat1: lat, lon1: lon, lat2: elat, lon2: elon))
		}
		.min { $0.1 < $1.1 }
		return best?.0
	}

	private static func cleanName(_ name: String?) -> String? {
		guard var name else { return nil }
		if name.hasSuffix(", US") {
			name = String(name.dropLast(4))
		}
		return name
	}
}
