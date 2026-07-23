import Foundation

public enum Geo {
	public static let metersPerNm = 1852.0
	public static let earthRadiusM = 6_371_000.0

	/// Initial great-circle bearing from point 1 to point 2, degrees clockwise from true north.
	public static func bearingDeg(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
		let p1 = lat1 * .pi / 180
		let p2 = lat2 * .pi / 180
		let dLon = (lon2 - lon1) * .pi / 180
		let y = sin(dLon) * cos(p2)
		let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dLon)
		let deg = atan2(y, x) * 180 / .pi
		return deg < 0 ? deg + 360 : deg
	}

	/// Haversine great-circle distance in meters.
	public static func distanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
		let dLat = (lat2 - lat1) * .pi / 180
		let dLon = (lon2 - lon1) * .pi / 180
		let a = sin(dLat / 2) * sin(dLat / 2)
			+ cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
		return 2 * earthRadiusM * asin(min(1, sqrt(a)))
	}
}
