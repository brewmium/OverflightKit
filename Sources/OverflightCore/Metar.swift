import Foundation

/// Fetches the latest METAR for a station from aviationweather.gov.
/// `altim` in that API is the altimeter setting in hectopascals;
/// `obsTime` is a unix epoch in seconds. Verified against live output 2026-07-23.
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
}
