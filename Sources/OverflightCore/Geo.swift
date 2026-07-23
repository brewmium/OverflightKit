import Foundation

public enum Geo {
	public static let metersPerNm = 1852.0
	public static let earthRadiusM = 6_371_000.0

	/// Haversine great-circle distance in meters.
	public static func distanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
		let dLat = (lat2 - lat1) * .pi / 180
		let dLon = (lon2 - lon1) * .pi / 180
		let a = sin(dLat / 2) * sin(dLat / 2)
			+ cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
		return 2 * earthRadiusM * asin(min(1, sqrt(a)))
	}
}
