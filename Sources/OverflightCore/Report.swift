import Foundation

/// Renders the `--report` text output: poll health, coverage diagnostic,
/// and the two overflight histograms.
public enum Report {
	public static func generate(store: Store, config: Config, sinceDays: Int? = nil) async throws -> String {
		let stats = try await store.pollStats(gapThresholdS: 300, expectedIntervalS: config.pollIntervalS)
		let bounds = try await store.observationTimeBounds()

		var lines: [String] = []
		lines.append("OverflightKit report")
		lines.append("database: \(store.path)")

		guard let stats else {
			lines.append("")
			lines.append("No polls recorded yet — run the collector first.")
			return lines.joined(separator: "\n")
		}

		let to = stats.lastTs
		let from: Int64
		if let days = sinceDays {
			from = to - Int64(days) * 86_400
		} else {
			from = bounds?.first ?? stats.firstTs
		}

		let tz = config.timeZone
		let fmt = DateFormatter()
		fmt.dateFormat = "yyyy-MM-dd HH:mm zzz"
		fmt.timeZone = tz

		let spanDays = Double(to - from) / 86_400
		lines.append("window:   \(fmt.string(from: date(from))) .. \(fmt.string(from: date(to)))  (\(String(format: "%.1f", spanDays)) days)")
		lines.append("")

		lines.append("Collector")
		lines.append("  polls: \(num(stats.okPolls)) ok / \(num(stats.errorPolls)) error  (total \(num(stats.totalPolls)))")
		lines.append("  poll coverage: \(pct(stats.coverageFraction)) of expected at \(Int(config.pollIntervalS))s cadence")
		lines.append("  gaps > 5 min: \(stats.gapCount)  (longest \(duration(stats.longestGapS)))")
		lines.append("  current source: \(stats.currentSource)")
		lines.append("  observations: \(num(stats.totalObservations)) rows, \(num(stats.distinctAircraft)) distinct aircraft")
		lines.append("")

		let observations = try await store.observations(from: from, to: to)
		let metars = try await store.metarSamples(from: from - 10_800, to: to + 10_800)
		let altimeters = AltimeterHistory(samples: metars)

		let cov = Analysis.coverage(
			observations: observations,
			siteLat: config.site.lat, siteLon: config.site.lon,
			fieldElevationFt: config.site.fieldElevationFt, altimeters: altimeters
		)

		lines.append("Coverage diagnostic")
		lines.append("  airborne observations with usable altitude: \(num(cov.airborneWithAgl))")
		lines.append("  below 2,000 ft AGL: \(num(cov.below2000))  (\(pct(cov.fractionBelow2000)))")
		if let minAgl = cov.minAglWithin5nmFt {
			var detail = "\(num(Int(minAgl.rounded()))) ft"
			if let hex = cov.minAglHex { detail += "  hex \(hex)" }
			if let ts = cov.minAglTs { detail += "  \(fmt.string(from: date(ts)))" }
			if let src = cov.minAglSource { detail += "  (\(src.label))" }
			lines.append("  minimum AGL within 5 nm: \(detail)")
		} else {
			lines.append("  minimum AGL within 5 nm: no airborne observations within 5 nm")
		}
		let srcTotal = cov.sourceCounts.values.reduce(0, +)
		if srcTotal > 0 {
			let order: [AltitudeSource] = [.geometric, .baroCorrected, .baroUncorrected, .unknown]
			let parts = order.compactMap { src -> String? in
				guard let n = cov.sourceCounts[src], n > 0 else { return nil }
				return "\(src.label) \(pct(Double(n) / Double(srcTotal)))"
			}
			lines.append("  altitude sources: \(parts.joined(separator: " / "))")
		}
		if !cov.patternVisible {
			lines.append("")
			lines.append("  *** WARNING: no observations below 2,000 ft AGL in this window.")
			lines.append("  *** The aggregator likely cannot see pattern-altitude traffic at this site.")
			lines.append("  *** This dataset CANNOT answer the overflight question at pattern altitudes.")
		}
		lines.append("")

		let tracks = Analysis.tracks(
			from: observations, fieldElevationFt: config.site.fieldElevationFt, altimeters: altimeters
		)
		let overflights = Analysis.overflights(
			tracks: tracks, parcelLat: config.parcel.lat, parcelLon: config.parcel.lon,
			radiusM: config.parcel.radiusM
		)

		lines.append("Overflights  (parcel \(coord(config.parcel.lat)),\(coord(config.parcel.lon))  radius \(Int(config.parcel.radiusM)) m)")
		lines.append("  tracks through cylinder: \(num(overflights.count))")
		lines.append("")

		let hours = Analysis.hourHistogram(overflights, timeZone: tz)
		let hourMax = hours.max() ?? 0
		lines.append("  By hour of day (\(config.timezone))")
		for (h, n) in hours.enumerated() {
			lines.append("  \(String(format: "%02d", h)) |\(bar(n, max: hourMax)) \(n > 0 ? String(n) : "")")
		}
		lines.append("")

		let bands = Analysis.bandHistogram(overflights)
		let bandMax = bands.counts.max() ?? 0
		lines.append("  By altitude band at closest approach (ft AGL)")
		for band in AltitudeBand.allCases {
			let n = bands.counts[band.rawValue]
			let label = band.label.padding(toLength: 12, withPad: " ", startingAt: 0)
			lines.append("  \(label)|\(bar(n, max: bandMax)) \(n > 0 ? String(n) : "")")
		}
		if bands.unknownCount > 0 {
			lines.append("  unknown alt | \(bands.unknownCount) (closest approach had no usable altitude)")
		}
		lines.append("")

		return lines.joined(separator: "\n")
	}

	static func bar(_ count: Int, max: Int, width: Int = 40) -> String {
		guard count > 0, max > 0 else { return "" }
		let n = Swift.max(1, Int((Double(count) / Double(max) * Double(width)).rounded()))
		return String(repeating: "#", count: n) + " "
	}

	static func date(_ ts: Int64) -> Date {
		Date(timeIntervalSince1970: Double(ts))
	}

	static func num(_ n: Int) -> String {
		let f = NumberFormatter()
		f.numberStyle = .decimal
		return f.string(from: NSNumber(value: n)) ?? String(n)
	}

	static func pct(_ f: Double) -> String {
		String(format: "%.1f%%", f * 100)
	}

	static func coord(_ d: Double) -> String {
		String(format: "%.5f", d)
	}

	static func duration(_ s: Int64) -> String {
		if s < 60 { return "\(s)s" }
		if s < 3600 { return "\(s / 60)m \(s % 60)s" }
		return "\(s / 3600)h \((s % 3600) / 60)m"
	}
}
