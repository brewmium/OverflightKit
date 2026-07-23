import XCTest
@testable import OverflightCore

final class CylinderTests: XCTestCase {
	static let parcelLat = 36.6
	static let parcelLon = -94.7

	/// Build a point offset east of the parcel by a given number of meters.
	func point(ts: Int64, eastM: Double, aglFt: Double?, onGround: Bool = false) -> TrackPoint {
		let lat = Self.parcelLat
		let lon = Self.parcelLon + eastM / (111_320 * cos(lat * .pi / 180))
		return TrackPoint(
			ts: ts, lat: lat, lon: lon, aglFt: aglFt,
			altSource: aglFt != nil ? .geometric : .unknown, onGround: onGround
		)
	}

	func testTrackThroughCylinderDetected() throws {
		let track = Track(hex: "abc123", points: [
			point(ts: 0, eastM: 1000, aglFt: 1500),
			point(ts: 10, eastM: 200, aglFt: 1200),
			point(ts: 20, eastM: 600, aglFt: 1400),
		])
		let hits = Analysis.overflights(
			tracks: [track], parcelLat: Self.parcelLat, parcelLon: Self.parcelLon, radiusM: 400
		)
		XCTAssertEqual(hits.count, 1)
		let hit = try XCTUnwrap(hits.first)
		XCTAssertEqual(hit.closestDistanceM, 200, accuracy: 5)
		XCTAssertEqual(hit.closestPoint.aglFt, 1200)
		XCTAssertEqual(hit.insidePointCount, 1)
	}

	func testTrackOutsideRadiusExcluded() {
		let track = Track(hex: "abc123", points: [
			point(ts: 0, eastM: 1000, aglFt: 1500),
			point(ts: 10, eastM: 450, aglFt: 1200),
		])
		let hits = Analysis.overflights(
			tracks: [track], parcelLat: Self.parcelLat, parcelLon: Self.parcelLon, radiusM: 400
		)
		XCTAssertTrue(hits.isEmpty)
	}

	func testGroundPointsNeverQualify() {
		// Taxiing straight through the parcel is not an overflight.
		let taxiing = Track(hex: "abc123", points: [
			point(ts: 0, eastM: 50, aglFt: 0, onGround: true),
			point(ts: 10, eastM: 10, aglFt: 0, onGround: true),
		])
		XCTAssertTrue(Analysis.overflights(
			tracks: [taxiing], parcelLat: Self.parcelLat, parcelLon: Self.parcelLon, radiusM: 400
		).isEmpty)

		// Ground point inside, airborne points outside: still no overflight.
		let mixed = Track(hex: "bbb222", points: [
			point(ts: 0, eastM: 100, aglFt: 0, onGround: true),
			point(ts: 10, eastM: 900, aglFt: 800),
		])
		XCTAssertTrue(Analysis.overflights(
			tracks: [mixed], parcelLat: Self.parcelLat, parcelLon: Self.parcelLon, radiusM: 400
		).isEmpty)
	}

	func testAltitudeBandBoundaries() {
		XCTAssertEqual(AltitudeBand.classify(aglFt: 999), .below1000)
		XCTAssertEqual(AltitudeBand.classify(aglFt: 1000), .from1000to2000)
		XCTAssertEqual(AltitudeBand.classify(aglFt: 1999), .from1000to2000)
		XCTAssertEqual(AltitudeBand.classify(aglFt: 2000), .from2000to5000)
		XCTAssertEqual(AltitudeBand.classify(aglFt: 5000), .from5000to10000)
		XCTAssertEqual(AltitudeBand.classify(aglFt: 10_000), .from5000to10000)
		XCTAssertEqual(AltitudeBand.classify(aglFt: 10_001), .above10000)
	}

	func testHourHistogramUsesLocalTime() {
		// 2026-07-23 19:00 UTC == 14:00 America/Chicago (CDT)
		let ts: Int64 = 1_784_833_200
		let track = Track(hex: "abc123", points: [point(ts: ts, eastM: 100, aglFt: 1000)])
		let hits = Analysis.overflights(
			tracks: [track], parcelLat: Self.parcelLat, parcelLon: Self.parcelLon, radiusM: 400
		)
		let hist = Analysis.hourHistogram(hits, timeZone: TimeZone(identifier: "America/Chicago")!)
		XCTAssertEqual(hist[14], 1)
		XCTAssertEqual(hist.reduce(0, +), 1)
	}
}
