import Foundation
import OverflightCore

func log(_ msg: String) {
	let fmt = ISO8601DateFormatter()
	fmt.formatOptions = [.withInternetDateTime]
	fputs("\(fmt.string(from: Date())) \(msg)\n", stdout)
	fflush(stdout)
}

func makeSignalSource(_ sig: Int32, cancelling task: Task<Void, Never>) -> DispatchSourceSignal {
	signal(sig, SIG_IGN)
	let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
	src.setEventHandler { task.cancel() }
	src.resume()
	return src
}

struct PollOutcome: Sendable {
	var record: PollRecord
	var aircraft: [Aircraft]
}

struct CollectorLoop: Sendable {
	let config: Config
	let store: Store
	let session: URLSession

	init(config: Config, store: Store) {
		self.config = config
		self.store = store
		let sc = URLSessionConfiguration.ephemeral
		sc.timeoutIntervalForRequest = 8
		sc.httpAdditionalHeaders = ["User-Agent": "OverflightKit/1.0 (+https://github.com/brewmium/OverflightKit)"]
		session = URLSession(configuration: sc)
	}

	func pollSource(named name: String) async -> PollOutcome {
		let ts = Int64(Date().timeIntervalSince1970)
		func failed(_ status: Int?, _ error: String, _ ms: Int?) -> PollOutcome {
			PollOutcome(
				record: PollRecord(ts: ts, source: name, httpStatus: status, error: error, aircraftCount: 0, latencyMs: ms),
				aircraft: []
			)
		}
		guard let base = Config.baseURL(forSource: name),
			let url = URL(string: "\(base)/v2/point/\(config.site.lat)/\(config.site.lon)/\(Int(config.radiusNm.rounded()))")
		else {
			return failed(nil, "unknown source '\(name)'", nil)
		}
		let start = Date()
		do {
			let (data, resp) = try await session.data(from: url)
			let ms = Int(Date().timeIntervalSince(start) * 1000)
			let status = (resp as? HTTPURLResponse)?.statusCode
			guard status == 200 else {
				return failed(status, "http \(status.map(String.init) ?? "?")", ms)
			}
			do {
				let decoded = try JSONDecoder().decode(PointResponse.self, from: data)
				return PollOutcome(
					record: PollRecord(ts: ts, source: name, httpStatus: 200, error: nil, aircraftCount: decoded.ac.count, latencyMs: ms),
					aircraft: decoded.ac
				)
			} catch {
				return failed(200, "decode: \(error)", ms)
			}
		} catch {
			let ms = Int(Date().timeIntervalSince(start) * 1000)
			return failed(nil, "transport: \(error.localizedDescription)", ms)
		}
	}

	func pollOnce() async throws {
		let outcome = await pollSource(named: config.primarySource)
		try await store.record(poll: outcome.record, aircraft: outcome.aircraft)
		if let err = outcome.record.error {
			log("\(config.primarySource): ERROR \(err)")
		} else {
			log("\(config.primarySource): \(outcome.record.aircraftCount) aircraft, \(outcome.record.latencyMs ?? 0)ms")
			for a in outcome.aircraft {
				let alt: String
				switch a.altBaro {
				case .ground: alt = "ground"
				case .feet(let f): alt = "\(f) ft"
				case nil: alt = a.altGeomFt.map { "\($0) ft geom" } ?? "alt?"
				}
				log("  \(a.hex) \(a.flight ?? a.registration ?? "") \(alt)")
			}
		}
	}

	func run() async {
		var activePrimary = true
		var failStreak = 0
		var backoffS = 0.0
		var pollsUntilPrimaryProbe = 0
		var pollCount = 0
		var okSinceLastSummary = 0
		var acSinceLastSummary = 0
		var lastMetarAttempt: Int64 = 0
		if let ts = try? await store.latestMetarTs(station: config.metarStation) {
			lastMetarAttempt = ts
		}

		while !Task.isCancelled {
			let probing = !activePrimary && pollsUntilPrimaryProbe <= 0
			let sourceName = (activePrimary || probing) ? config.primarySource : config.fallbackSource

			let outcome = await pollSource(named: sourceName)
			do {
				try await store.record(poll: outcome.record, aircraft: outcome.aircraft)
			} catch {
				log("db write failed: \(error)")
			}

			pollCount += 1
			if outcome.record.error == nil {
				okSinceLastSummary += 1
				acSinceLastSummary += outcome.record.aircraftCount
				failStreak = 0
				backoffS = 0
				if probing {
					activePrimary = true
					log("primary \(config.primarySource) recovered — switching back")
				}
			} else {
				log("\(sourceName): \(outcome.record.error ?? "?")")
				if probing {
					// Primary still down; keep riding the fallback and try again later.
					pollsUntilPrimaryProbe = 30
				} else {
					failStreak += 1
					backoffS = min(backoffS == 0 ? config.pollIntervalS * 2 : backoffS * 2, 300)
					if activePrimary, failStreak >= 3 {
						activePrimary = false
						pollsUntilPrimaryProbe = 30
						failStreak = 0
						backoffS = 0
						log("switching to fallback \(config.fallbackSource)")
					}
				}
			}
			if !activePrimary, !probing {
				pollsUntilPrimaryProbe -= 1
			}

			if pollCount % 60 == 0 {
				log("\(pollCount) polls, last 60: \(okSinceLastSummary) ok, \(acSinceLastSummary) aircraft rows, source \(sourceName)")
				okSinceLastSummary = 0
				acSinceLastSummary = 0
			}

			let now = Int64(Date().timeIntervalSince1970)
			if now - lastMetarAttempt >= 3600 {
				do {
					let (sample, raw) = try await MetarClient.fetchLatest(station: config.metarStation, session: session)
					try await store.record(metarTs: sample.ts, station: config.metarStation, altimHpa: sample.altimHpa, raw: raw)
					lastMetarAttempt = now
					log("metar \(config.metarStation): altim \(sample.altimHpa) hPa")
				} catch {
					// Retry in 5 minutes rather than a full hour.
					lastMetarAttempt = now - 3600 + 300
					log("metar fetch failed: \(error)")
				}
			}

			let base = backoffS > 0 ? backoffS : config.pollIntervalS
			// Jitter so requests don't land on a fixed phase; never below 1s
			// (airplanes.live hard limit is 1 request/second).
			let delay = max(1.0, base + Double.random(in: -1...1))
			do {
				try await Task.sleep(for: .seconds(delay))
			} catch {
				break
			}
		}
	}
}

@main
struct OverflightCollectorMain {
	static func main() async {
		do {
			try await run()
		} catch {
			log("fatal: \(error)")
			exit(1)
		}
	}

	static func usage() -> String {
		"""
		OverflightCollector — ADS-B overflight sampler

		usage:
		  OverflightCollector [--config PATH]            run the collector loop
		  OverflightCollector --once [--config PATH]     single poll, print aircraft, exit
		  OverflightCollector --report [--days N] [--config PATH]
		                                                 print histograms + coverage diagnostic

		config defaults to \(Config.defaultPath) and is created with KGMJ defaults if missing.
		"""
	}

	static func run() async throws {
		var configPath: String?
		var report = false
		var once = false
		var days: Int?

		var args = ArraySlice(CommandLine.arguments.dropFirst())
		while let arg = args.popFirst() {
			switch arg {
			case "--config":
				guard let v = args.popFirst() else { throw OverflightError.usage("--config requires a path") }
				configPath = v
			case "--report":
				report = true
			case "--once":
				once = true
			case "--days":
				guard let v = args.popFirst(), let n = Int(v), n > 0 else {
					throw OverflightError.usage("--days requires a positive integer")
				}
				days = n
			case "--help", "-h":
				print(usage())
				return
			default:
				throw OverflightError.usage("unknown argument '\(arg)'\n\n\(usage())")
			}
		}

		let config = try Config.loadOrCreate(path: configPath)

		if report {
			let store = try Store(path: config.expandedDbPath, readOnly: true)
			let text = try await Report.generate(store: store, config: config, sinceDays: days)
			await store.close()
			print(text)
			return
		}

		let store = try Store(path: config.expandedDbPath, readOnly: false)
		let loop = CollectorLoop(config: config, store: store)

		if once {
			try await loop.pollOnce()
			await store.close()
			return
		}

		log("collector starting: \(config.site.lat),\(config.site.lon) r=\(Int(config.radiusNm))nm every \(Int(config.pollIntervalS))s -> \(config.expandedDbPath)")
		let task = Task { await loop.run() }
		let sigint = makeSignalSource(SIGINT, cancelling: task)
		let sigterm = makeSignalSource(SIGTERM, cancelling: task)
		defer {
			sigint.cancel()
			sigterm.cancel()
		}
		await task.value
		await store.close()
		log("collector stopped")
	}
}
