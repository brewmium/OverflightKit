import Foundation

/// Collector + viewer configuration, loaded from ~/.overflight/config.json.
/// Every field has a KGMJ default so a partial file (or none) still works.
public struct Config: Codable, Sendable, Equatable {
	public struct Site: Codable, Sendable, Equatable {
		public var lat: Double
		public var lon: Double
		public var fieldElevationFt: Double

		enum CodingKeys: String, CodingKey {
			case lat, lon
			case fieldElevationFt = "field_elevation_ft"
		}

		public init(lat: Double, lon: Double, fieldElevationFt: Double) {
			self.lat = lat
			self.lon = lon
			self.fieldElevationFt = fieldElevationFt
		}
	}

	public struct Parcel: Codable, Sendable, Equatable {
		public var lat: Double
		public var lon: Double
		public var radiusM: Double

		enum CodingKeys: String, CodingKey {
			case lat, lon
			case radiusM = "radius_m"
		}

		public init(lat: Double, lon: Double, radiusM: Double) {
			self.lat = lat
			self.lon = lon
			self.radiusM = radiusM
		}
	}

	public var site: Site
	public var radiusNm: Double
	public var parcel: Parcel
	public var pollIntervalS: Double
	public var dbPath: String
	public var primarySource: String
	public var fallbackSource: String
	public var metarStation: String
	public var timezone: String

	enum CodingKeys: String, CodingKey {
		case site, parcel, timezone
		case radiusNm = "radius_nm"
		case pollIntervalS = "poll_interval_s"
		case dbPath = "db_path"
		case primarySource = "primary_source"
		case fallbackSource = "fallback_source"
		case metarStation = "metar_station"
	}

	public init(
		site: Site, radiusNm: Double, parcel: Parcel, pollIntervalS: Double,
		dbPath: String, primarySource: String, fallbackSource: String,
		metarStation: String, timezone: String
	) {
		self.site = site
		self.radiusNm = radiusNm
		self.parcel = parcel
		self.pollIntervalS = pollIntervalS
		self.dbPath = dbPath
		self.primarySource = primarySource
		self.fallbackSource = fallbackSource
		self.metarStation = metarStation
		self.timezone = timezone
	}

	public init(from decoder: Decoder) throws {
		let d = Config.kgmjDefault
		let c = try decoder.container(keyedBy: CodingKeys.self)
		site = try c.decodeIfPresent(Site.self, forKey: .site) ?? d.site
		radiusNm = try c.decodeIfPresent(Double.self, forKey: .radiusNm) ?? d.radiusNm
		parcel = try c.decodeIfPresent(Parcel.self, forKey: .parcel) ?? d.parcel
		pollIntervalS = try c.decodeIfPresent(Double.self, forKey: .pollIntervalS) ?? d.pollIntervalS
		dbPath = try c.decodeIfPresent(String.self, forKey: .dbPath) ?? d.dbPath
		primarySource = try c.decodeIfPresent(String.self, forKey: .primarySource) ?? d.primarySource
		fallbackSource = try c.decodeIfPresent(String.self, forKey: .fallbackSource) ?? d.fallbackSource
		metarStation = try c.decodeIfPresent(String.self, forKey: .metarStation) ?? d.metarStation
		timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? d.timezone
	}

	public static let kgmjDefault = Config(
		site: Site(lat: 36.6067, lon: -94.7386, fieldElevationFt: 832),
		radiusNm: 15,
		parcel: Parcel(lat: 36.6067, lon: -94.7386, radiusM: 400),
		pollIntervalS: 10,
		dbPath: "~/.overflight/overflight.db",
		primarySource: "adsb.lol",
		fallbackSource: "airplanes.live",
		metarStation: "KGMJ",
		timezone: "America/Chicago"
	)

	public static let defaultPath = "~/.overflight/config.json"

	public var expandedDbPath: String {
		(dbPath as NSString).expandingTildeInPath
	}

	public var timeZone: TimeZone {
		TimeZone(identifier: timezone) ?? .current
	}

	/// Known aggregator hosts. A source name that is already a URL is used as-is,
	/// so a config can point at any ADSBExchange-v2-compatible endpoint.
	public static func baseURL(forSource name: String) -> String? {
		switch name {
		case "adsb.lol": return "https://api.adsb.lol"
		case "airplanes.live": return "https://api.airplanes.live"
		default:
			if name.hasPrefix("http://") || name.hasPrefix("https://") {
				return name.hasSuffix("/") ? String(name.dropLast()) : name
			}
			return nil
		}
	}

	public static func load(path: String? = nil) throws -> Config {
		let p = ((path ?? defaultPath) as NSString).expandingTildeInPath
		guard FileManager.default.fileExists(atPath: p) else {
			throw OverflightError.notFound("config not found at \(p)")
		}
		let data = try Data(contentsOf: URL(fileURLWithPath: p))
		return try JSONDecoder().decode(Config.self, from: data)
	}

	/// Load the config, writing the KGMJ defaults out first if no file exists.
	public static func loadOrCreate(path: String? = nil) throws -> Config {
		let p = ((path ?? defaultPath) as NSString).expandingTildeInPath
		if !FileManager.default.fileExists(atPath: p) {
			try kgmjDefault.save(path: p)
		}
		return try load(path: p)
	}

	public func save(path: String? = nil) throws {
		let p = ((path ?? Config.defaultPath) as NSString).expandingTildeInPath
		let dir = (p as NSString).deletingLastPathComponent
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		let enc = JSONEncoder()
		enc.outputFormatting = [.prettyPrinted, .sortedKeys]
		try enc.encode(self).write(to: URL(fileURLWithPath: p), options: .atomic)
	}
}
