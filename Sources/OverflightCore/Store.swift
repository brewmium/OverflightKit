import Foundation

public struct PollRecord: Sendable {
	public var ts: Int64
	public var source: String
	public var httpStatus: Int?
	public var error: String?
	public var aircraftCount: Int
	public var latencyMs: Int?

	public init(ts: Int64, source: String, httpStatus: Int?, error: String?, aircraftCount: Int, latencyMs: Int?) {
		self.ts = ts
		self.source = source
		self.httpStatus = httpStatus
		self.error = error
		self.aircraftCount = aircraftCount
		self.latencyMs = latencyMs
	}
}

public struct AircraftObservation: Sendable, Equatable {
	public var id: Int64
	public var pollId: Int64
	public var ts: Int64
	public var hex: String
	public var flight: String?
	public var reg: String?
	public var typeCode: String?
	public var lat: Double
	public var lon: Double
	public var altBaroFt: Int?
	public var onGround: Bool
	public var altGeomFt: Int?
	public var gsKt: Double?
	public var trackDeg: Double?
	public var baroRateFpm: Int?
	public var squawk: String?
	public var seenPos: Double?
	public var rssi: Double?

	public init(
		id: Int64 = 0, pollId: Int64 = 0, ts: Int64, hex: String,
		flight: String? = nil, reg: String? = nil, typeCode: String? = nil,
		lat: Double, lon: Double, altBaroFt: Int? = nil, onGround: Bool = false,
		altGeomFt: Int? = nil, gsKt: Double? = nil, trackDeg: Double? = nil,
		baroRateFpm: Int? = nil, squawk: String? = nil, seenPos: Double? = nil,
		rssi: Double? = nil
	) {
		self.id = id
		self.pollId = pollId
		self.ts = ts
		self.hex = hex
		self.flight = flight
		self.reg = reg
		self.typeCode = typeCode
		self.lat = lat
		self.lon = lon
		self.altBaroFt = altBaroFt
		self.onGround = onGround
		self.altGeomFt = altGeomFt
		self.gsKt = gsKt
		self.trackDeg = trackDeg
		self.baroRateFpm = baroRateFpm
		self.squawk = squawk
		self.seenPos = seenPos
		self.rssi = rssi
	}
}

public struct MetarSample: Sendable, Equatable {
	public var ts: Int64
	public var altimHpa: Double

	public init(ts: Int64, altimHpa: Double) {
		self.ts = ts
		self.altimHpa = altimHpa
	}
}

public struct PollStats: Sendable {
	public var totalPolls: Int
	public var okPolls: Int
	public var errorPolls: Int
	public var firstTs: Int64
	public var lastTs: Int64
	public var gapCount: Int
	public var longestGapS: Int64
	public var currentSource: String
	public var totalObservations: Int
	public var distinctAircraft: Int
	/// Fraction of the polls expected at the configured cadence that actually landed.
	public var coverageFraction: Double
}

public actor Store {
	private let db: Database
	public let path: String

	public init(path: String, readOnly: Bool = false) throws {
		self.path = path
		db = try Database(path: path, readOnly: readOnly)
		try db.exec("PRAGMA busy_timeout=5000;")
		if !readOnly {
			try db.exec("PRAGMA journal_mode=WAL;")
			try db.exec("PRAGMA synchronous=NORMAL;")
			try db.exec("PRAGMA foreign_keys=ON;")
			try Store.migrate(db)
		}
	}

	public func close() {
		db.close()
	}

	private static func migrate(_ db: Database) throws {
		try db.exec("""
			CREATE TABLE IF NOT EXISTS poll (
				id            INTEGER PRIMARY KEY,
				ts            INTEGER NOT NULL,
				source        TEXT    NOT NULL,
				http_status   INTEGER,
				error         TEXT,
				aircraft_count INTEGER NOT NULL DEFAULT 0,
				latency_ms    INTEGER
			);
			CREATE TABLE IF NOT EXISTS observation (
				id          INTEGER PRIMARY KEY,
				poll_id     INTEGER NOT NULL REFERENCES poll(id),
				ts          INTEGER NOT NULL,
				hex         TEXT    NOT NULL,
				flight      TEXT,
				reg         TEXT,
				type_code   TEXT,
				lat         REAL    NOT NULL,
				lon         REAL    NOT NULL,
				alt_baro_ft INTEGER,
				on_ground   INTEGER NOT NULL DEFAULT 0,
				alt_geom_ft INTEGER,
				gs_kt       REAL,
				track_deg   REAL,
				baro_rate   INTEGER,
				squawk      TEXT,
				seen_pos    REAL,
				rssi        REAL
			);
			CREATE INDEX IF NOT EXISTS idx_obs_hex_ts ON observation(hex, ts);
			CREATE INDEX IF NOT EXISTS idx_obs_ts     ON observation(ts);
			CREATE TABLE IF NOT EXISTS metar (
				id        INTEGER PRIMARY KEY,
				ts        INTEGER NOT NULL,
				station   TEXT    NOT NULL,
				altim_hpa REAL,
				raw       TEXT
			);
			CREATE INDEX IF NOT EXISTS idx_metar_ts ON metar(ts);
			PRAGMA user_version=1;
			""")
	}

	// MARK: - Writes

	/// One poll attempt and its aircraft, in a single transaction.
	/// Aircraft without a position are counted in `aircraft_count` but produce no observation row.
	@discardableResult
	public func record(poll: PollRecord, aircraft: [Aircraft]) throws -> Int64 {
		try db.exec("BEGIN IMMEDIATE;")
		do {
			let pollStmt = try db.prepare("""
				INSERT INTO poll (ts, source, http_status, error, aircraft_count, latency_ms)
				VALUES (?,?,?,?,?,?);
				""")
			pollStmt.bind(1, poll.ts)
			pollStmt.bind(2, poll.source)
			pollStmt.bind(3, poll.httpStatus)
			pollStmt.bind(4, poll.error)
			pollStmt.bind(5, poll.aircraftCount)
			pollStmt.bind(6, poll.latencyMs)
			try pollStmt.step()
			let pollId = db.lastInsertRowID

			if !aircraft.isEmpty {
				let obsStmt = try db.prepare("""
					INSERT INTO observation (poll_id, ts, hex, flight, reg, type_code, lat, lon,
						alt_baro_ft, on_ground, alt_geom_ft, gs_kt, track_deg, baro_rate,
						squawk, seen_pos, rssi)
					VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
					""")
				for a in aircraft {
					guard let lat = a.lat, let lon = a.lon else { continue }
					obsStmt.reset()
					var altBaroFt: Int?
					var onGround = false
					switch a.altBaro {
					case .ground: onGround = true
					case .feet(let ft): altBaroFt = ft
					case nil: break
					}
					obsStmt.bind(1, pollId)
					obsStmt.bind(2, poll.ts)
					obsStmt.bind(3, a.hex)
					obsStmt.bind(4, a.flight)
					obsStmt.bind(5, a.registration)
					obsStmt.bind(6, a.typeCode)
					obsStmt.bind(7, lat)
					obsStmt.bind(8, lon)
					obsStmt.bind(9, altBaroFt)
					obsStmt.bind(10, Int64(onGround ? 1 : 0))
					obsStmt.bind(11, a.altGeomFt)
					obsStmt.bind(12, a.groundSpeedKt)
					obsStmt.bind(13, a.trackDeg)
					obsStmt.bind(14, a.baroRateFpm)
					obsStmt.bind(15, a.squawk)
					obsStmt.bind(16, a.seenPos)
					obsStmt.bind(17, a.rssi)
					try obsStmt.step()
				}
			}
			try db.exec("COMMIT;")
			return pollId
		} catch {
			try? db.exec("ROLLBACK;")
			throw error
		}
	}

	public func record(metarTs: Int64, station: String, altimHpa: Double?, raw: String?) throws {
		let stmt = try db.prepare("INSERT INTO metar (ts, station, altim_hpa, raw) VALUES (?,?,?,?);")
		stmt.bind(1, metarTs)
		stmt.bind(2, station)
		stmt.bind(3, altimHpa)
		stmt.bind(4, raw)
		try stmt.step()
	}

	public func latestMetarTs(station: String) throws -> Int64? {
		let stmt = try db.prepare("SELECT ts FROM metar WHERE station = ? ORDER BY ts DESC LIMIT 1;")
		stmt.bind(1, station)
		return try stmt.step() ? stmt.int64(0) : nil
	}

	// MARK: - Reads

	public func observations(from: Int64, to: Int64) throws -> [AircraftObservation] {
		let stmt = try db.prepare("""
			SELECT id, poll_id, ts, hex, flight, reg, type_code, lat, lon,
				alt_baro_ft, on_ground, alt_geom_ft, gs_kt, track_deg, baro_rate,
				squawk, seen_pos, rssi
			FROM observation WHERE ts >= ? AND ts <= ? ORDER BY hex, ts;
			""")
		stmt.bind(1, from)
		stmt.bind(2, to)
		var out: [AircraftObservation] = []
		while try stmt.step() {
			out.append(AircraftObservation(
				id: stmt.int64(0),
				pollId: stmt.int64(1),
				ts: stmt.int64(2),
				hex: stmt.text(3) ?? "",
				flight: stmt.text(4),
				reg: stmt.text(5),
				typeCode: stmt.text(6),
				lat: stmt.double(7),
				lon: stmt.double(8),
				altBaroFt: stmt.intOrNil(9),
				onGround: stmt.int64(10) != 0,
				altGeomFt: stmt.intOrNil(11),
				gsKt: stmt.doubleOrNil(12),
				trackDeg: stmt.doubleOrNil(13),
				baroRateFpm: stmt.intOrNil(14),
				squawk: stmt.text(15),
				seenPos: stmt.doubleOrNil(16),
				rssi: stmt.doubleOrNil(17)
			))
		}
		return out
	}

	public func metarSamples(from: Int64, to: Int64) throws -> [MetarSample] {
		let stmt = try db.prepare("""
			SELECT ts, altim_hpa FROM metar
			WHERE altim_hpa IS NOT NULL AND ts >= ? AND ts <= ? ORDER BY ts;
			""")
		stmt.bind(1, from)
		stmt.bind(2, to)
		var out: [MetarSample] = []
		while try stmt.step() {
			out.append(MetarSample(ts: stmt.int64(0), altimHpa: stmt.double(1)))
		}
		return out
	}

	public func observationTimeBounds() throws -> (first: Int64, last: Int64)? {
		let stmt = try db.prepare("SELECT MIN(ts), MAX(ts) FROM observation;")
		guard try stmt.step(), !stmt.isNull(0) else { return nil }
		return (stmt.int64(0), stmt.int64(1))
	}

	public func pollStats(gapThresholdS: Int64 = 300, expectedIntervalS: Double = 10) throws -> PollStats? {
		let stmt = try db.prepare("SELECT ts, error, source FROM poll ORDER BY ts;")
		var total = 0
		var ok = 0
		var first: Int64 = 0
		var last: Int64 = 0
		var prev: Int64?
		var gaps = 0
		var longest: Int64 = 0
		var source = ""
		while try stmt.step() {
			let ts = stmt.int64(0)
			if total == 0 { first = ts }
			total += 1
			last = ts
			if stmt.isNull(1) { ok += 1 }
			source = stmt.text(2) ?? source
			if let p = prev {
				let gap = ts - p
				if gap > gapThresholdS { gaps += 1 }
				if gap > longest { longest = gap }
			}
			prev = ts
		}
		guard total > 0 else { return nil }

		let countStmt = try db.prepare("SELECT COUNT(*), COUNT(DISTINCT hex) FROM observation;")
		var obsCount = 0
		var distinct = 0
		if try countStmt.step() {
			obsCount = Int(countStmt.int64(0))
			distinct = Int(countStmt.int64(1))
		}

		let spanS = Double(last - first)
		let expected = spanS > 0 ? spanS / expectedIntervalS + 1 : 1
		return PollStats(
			totalPolls: total,
			okPolls: ok,
			errorPolls: total - ok,
			firstTs: first,
			lastTs: last,
			gapCount: gaps,
			longestGapS: longest,
			currentSource: source,
			totalObservations: obsCount,
			distinctAircraft: distinct,
			coverageFraction: min(1, Double(total) / expected)
		)
	}
}
