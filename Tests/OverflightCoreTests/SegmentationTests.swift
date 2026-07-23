import XCTest
@testable import OverflightCore

final class SegmentationTests: XCTestCase {
	func obs(hex: String, ts: Int64, altGeomFt: Int? = 2000, altBaroFt: Int? = nil, onGround: Bool = false) -> AircraftObservation {
		AircraftObservation(ts: ts, hex: hex, lat: 36.6, lon: -94.7, altBaroFt: altBaroFt, onGround: onGround, altGeomFt: altGeomFt)
	}

	func testSplitsAtGapOver300s() {
		let observations = [
			obs(hex: "abc123", ts: 0),
			obs(hex: "abc123", ts: 100),
			obs(hex: "abc123", ts: 200),
			obs(hex: "abc123", ts: 501),   // 301s after previous -> new track
			obs(hex: "abc123", ts: 601),
		]
		let tracks = Analysis.tracks(from: observations, fieldElevationFt: 832, altimeters: nil)
		XCTAssertEqual(tracks.count, 2)
		XCTAssertEqual(tracks[0].points.count, 3)
		XCTAssertEqual(tracks[1].points.count, 2)
		XCTAssertEqual(tracks[1].points.first?.ts, 501)
	}

	func testGapOfExactly300sDoesNotSplit() {
		let observations = [
			obs(hex: "abc123", ts: 0),
			obs(hex: "abc123", ts: 300),
			obs(hex: "abc123", ts: 600),
		]
		let tracks = Analysis.tracks(from: observations, fieldElevationFt: 832, altimeters: nil)
		XCTAssertEqual(tracks.count, 1)
		XCTAssertEqual(tracks[0].points.count, 3)
	}

	func testInterleavedAircraftSeparate() {
		let observations = [
			obs(hex: "aaaaaa", ts: 0),
			obs(hex: "bbbbbb", ts: 5),
			obs(hex: "aaaaaa", ts: 10),
			obs(hex: "bbbbbb", ts: 15),
		]
		let tracks = Analysis.tracks(from: observations, fieldElevationFt: 832, altimeters: nil)
		XCTAssertEqual(tracks.count, 2)
		XCTAssertEqual(Set(tracks.map(\.hex)), ["aaaaaa", "bbbbbb"])
		XCTAssertTrue(tracks.allSatisfy { $0.points.count == 2 })
	}

	func testUnsortedInputIsSortedWithinTrack() {
		let observations = [
			obs(hex: "abc123", ts: 200),
			obs(hex: "abc123", ts: 0),
			obs(hex: "abc123", ts: 100),
		]
		let tracks = Analysis.tracks(from: observations, fieldElevationFt: 832, altimeters: nil)
		XCTAssertEqual(tracks.count, 1)
		XCTAssertEqual(tracks[0].points.map(\.ts), [0, 100, 200])
	}

	// MARK: AGL source selection

	func testAglPrefersGeometric() {
		let o = obs(hex: "abc123", ts: 0, altGeomFt: 2832, altBaroFt: 2600)
		let (agl, source) = Analysis.agl(for: o, fieldElevationFt: 832, altimeters: nil)
		XCTAssertEqual(agl, 2000)
		XCTAssertEqual(source, .geometric)
	}

	func testAglBaroCorrectedWithAltimeter() {
		// 1018.7 hPa = 30.082 inHg -> +162 ft over the 29.92 reference
		let o = obs(hex: "abc123", ts: 1000, altGeomFt: nil, altBaroFt: 2600)
		let history = AltimeterHistory(samples: [MetarSample(ts: 900, altimHpa: 1018.7)])
		let (agl, source) = Analysis.agl(for: o, fieldElevationFt: 832, altimeters: history)
		XCTAssertEqual(source, .baroCorrected)
		XCTAssertEqual(agl!, 2600 + 162.2 - 832, accuracy: 2)
	}

	func testAglBaroUncorrectedWithoutAltimeter() {
		let o = obs(hex: "abc123", ts: 1000, altGeomFt: nil, altBaroFt: 2600)
		let (agl, source) = Analysis.agl(for: o, fieldElevationFt: 832, altimeters: nil)
		XCTAssertEqual(source, .baroUncorrected)
		XCTAssertEqual(agl, 2600 - 832)
	}

	func testAglStaleAltimeterFallsBackToUncorrected() {
		let o = obs(hex: "abc123", ts: 100_000, altGeomFt: nil, altBaroFt: 2600)
		let history = AltimeterHistory(samples: [MetarSample(ts: 0, altimHpa: 1018.7)])
		let (_, source) = Analysis.agl(for: o, fieldElevationFt: 832, altimeters: history)
		XCTAssertEqual(source, .baroUncorrected)
	}

	func testAglGround() {
		let o = obs(hex: "abc123", ts: 0, altGeomFt: 575, onGround: true)
		let (agl, source) = Analysis.agl(for: o, fieldElevationFt: 832, altimeters: nil)
		XCTAssertEqual(agl, 0)
		XCTAssertEqual(source, .ground)
	}
}
