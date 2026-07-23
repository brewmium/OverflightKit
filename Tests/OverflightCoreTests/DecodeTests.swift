import XCTest
@testable import OverflightCore

final class DecodeTests: XCTestCase {
	func decodeAircraft(_ json: String) throws -> Aircraft {
		try JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
	}

	func testAltBaroGround() throws {
		let a = try decodeAircraft(#"{"hex":"0d099a","alt_baro":"ground","alt_geom":575,"lat":32.89,"lon":-97.04,"gs":37.5}"#)
		XCTAssertEqual(a.altBaro, .ground)
		XCTAssertEqual(a.altGeomFt, 575)
	}

	func testAltBaroFeet() throws {
		let a = try decodeAircraft(#"{"hex":"adddfe","alt_baro":5825,"lat":36.66,"lon":-94.82}"#)
		XCTAssertEqual(a.altBaro, .feet(5825))
	}

	func testAltBaroMissing() throws {
		let a = try decodeAircraft(#"{"hex":"abc123","lat":36.6,"lon":-94.7}"#)
		XCTAssertNil(a.altBaro)
	}

	func testFlightTrimmedSquawkPreserved() throws {
		let a = try decodeAircraft(#"{"hex":"a95161","flight":"N7RP    ","squawk":"0231","lat":36.8,"lon":-94.6}"#)
		XCTAssertEqual(a.flight, "N7RP")
		XCTAssertEqual(a.squawk, "0231")
	}

	func testEmptyFlightBecomesNil() throws {
		let a = try decodeAircraft(#"{"hex":"a95161","flight":"        ","lat":36.8,"lon":-94.6}"#)
		XCTAssertNil(a.flight)
	}

	// Trimmed from a live api.adsb.lol response captured 2026-07-23.
	func testEnvelopeDecode() throws {
		let json = #"""
		{"ac":[
		{"hex":"adddfe","type":"adsb_icao","flight":"N993CD  ","r":"N993CD","t":"C82S","alt_baro":5825,"alt_geom":6125,"gs":138.6,"track":239.18,"baro_rate":0,"squawk":"4634","lat":36.664263,"lon":-94.820193,"seen_pos":0.223,"messages":17114,"rssi":-22.3,"dst":5.230,"dir":311.3},
		{"hex":"0d099a","type":"adsb_icao","flight":"VIV7826 ","r":"XA-VAR","t":"A320","alt_baro":"ground","alt_geom":575,"gs":37.5,"track":180.0,"baro_rate":-128,"lat":32.892473,"lon":-97.037}
		],"msg":"No error","now":1784833477243,"total":2,"ctime":1784833477243,"ptime":0}
		"""#
		let resp = try JSONDecoder().decode(PointResponse.self, from: Data(json.utf8))
		XCTAssertEqual(resp.ac.count, 2)
		XCTAssertEqual(resp.ac[0].altBaro, .feet(5825))
		XCTAssertEqual(resp.ac[0].flight, "N993CD")
		XCTAssertEqual(resp.ac[0].typeCode, "C82S")
		XCTAssertEqual(resp.ac[0].seenPos ?? 0, 0.223, accuracy: 0.001)
		XCTAssertEqual(resp.ac[1].altBaro, .ground)
	}

	func testMissingAcArrayTolerated() throws {
		let resp = try JSONDecoder().decode(PointResponse.self, from: Data(#"{"msg":"No error","total":0}"#.utf8))
		XCTAssertTrue(resp.ac.isEmpty)
	}
}
