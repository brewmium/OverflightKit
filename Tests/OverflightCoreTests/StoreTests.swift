import XCTest
@testable import OverflightCore

final class StoreTests: XCTestCase {
	// Never the default path — tests must not touch the live database.
	func tempDbPath() -> String {
		NSTemporaryDirectory() + "overflight-test-\(UUID().uuidString)/test.db"
	}

	func testRoundTripWalAndConcurrentReader() async throws {
		let path = tempDbPath()
		defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

		let store = try Store(path: path)
		let aircraft = [
			Aircraft(
				hex: "adddfe", flight: "N993CD", registration: "N993CD", typeCode: "C82S",
				lat: 36.664, lon: -94.820, altBaro: .feet(5825), altGeomFt: 6125,
				groundSpeedKt: 138.6, trackDeg: 239.18, baroRateFpm: 0, squawk: "0463",
				seenPos: 0.223, rssi: -22.3
			),
			Aircraft(hex: "0d099a", lat: 32.892, lon: -97.037, altBaro: .ground, altGeomFt: 575),
			Aircraft(hex: "nopos1", altBaro: .feet(30000)),  // no position -> counted, not stored
		]
		try await store.record(
			poll: PollRecord(ts: 1000, source: "adsb.lol", httpStatus: 200, error: nil, aircraftCount: 3, latencyMs: 150),
			aircraft: aircraft
		)
		try await store.record(
			poll: PollRecord(ts: 1010, source: "adsb.lol", httpStatus: 429, error: "http 429", aircraftCount: 0, latencyMs: 90),
			aircraft: []
		)

		XCTAssertTrue(FileManager.default.fileExists(atPath: path + "-wal"), "WAL mode should be active")

		let obs = try await store.observations(from: 0, to: 2000)
		XCTAssertEqual(obs.count, 2)
		let n993 = try XCTUnwrap(obs.first { $0.hex == "adddfe" })
		XCTAssertEqual(n993.altBaroFt, 5825)
		XCTAssertEqual(n993.squawk, "0463")
		XCTAssertFalse(n993.onGround)
		let ground = try XCTUnwrap(obs.first { $0.hex == "0d099a" })
		XCTAssertTrue(ground.onGround)
		XCTAssertNil(ground.altBaroFt)
		XCTAssertEqual(ground.altGeomFt, 575)

		let stats = try await store.pollStats()
		XCTAssertEqual(stats?.totalPolls, 2)
		XCTAssertEqual(stats?.okPolls, 1)
		XCTAssertEqual(stats?.errorPolls, 1)
		XCTAssertEqual(stats?.totalObservations, 2)
		XCTAssertEqual(stats?.distinctAircraft, 2)

		// A second, read-only connection sees the same data while the writer is open.
		let reader = try Store(path: path, readOnly: true)
		let readerObs = try await reader.observations(from: 0, to: 2000)
		XCTAssertEqual(readerObs.count, 2)
		await reader.close()
		await store.close()
	}

	func testMetarRoundTrip() async throws {
		let path = tempDbPath()
		defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

		let store = try Store(path: path)
		try await store.record(metarTs: 5000, station: "KGMJ", altimHpa: 1018.7, raw: "METAR KGMJ ...")
		let latest = try await store.latestMetarTs(station: "KGMJ")
		XCTAssertEqual(latest, 5000)
		let samples = try await store.metarSamples(from: 0, to: 10_000)
		XCTAssertEqual(samples, [MetarSample(ts: 5000, altimHpa: 1018.7)])
		await store.close()
	}
}
