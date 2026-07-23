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
		var name = e.name ?? icao.uppercased()
		if name.hasSuffix(", US") {
			name = String(name.dropLast(4))
		}
		return StationInfo(
			icao: e.icaoId ?? icao.uppercased(),
			name: name,
			lat: lat, lon: lon,
			elevFt: (e.elev ?? 0) * 3.28084
		)
	}
}
