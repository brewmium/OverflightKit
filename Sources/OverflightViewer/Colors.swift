import AppKit
import SwiftUI
import OverflightCore

extension NSColor {
	convenience init(hex: UInt32) {
		self.init(
			srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
			green: CGFloat((hex >> 8) & 0xff) / 255,
			blue: CGFloat(hex & 0xff) / 255,
			alpha: 1
		)
	}

	static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
		NSColor(name: nil) { appearance in
			appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
				? NSColor(hex: dark)
				: NSColor(hex: light)
		}
	}
}

/// Altitude bands are ordinal magnitude, so they wear a single-hue blue ramp,
/// light (low) to dark (high), stepped per surface: one set validated against
/// the dark satellite basemap, one pair validated against the light/dark app
/// surfaces for the charts. Ground/unknown wear muted gray; status colors are
/// reserved for the collector health dot and warnings.
@MainActor
enum Viz {
	/// Dark-surface ordinal ramp — used on satellite imagery, low altitude lightest.
	static let mapBand: [NSColor] = [0xcde2fb, 0x86b6ef, 0x3987e5, 0x256abf, 0x184f95].map { NSColor(hex: $0) }
	static let mapGround = NSColor(hex: 0x898781)
	static let mapUnknown = NSColor(hex: 0x898781).withAlphaComponent(0.6)
	static let parcelFill = NSColor(hex: 0xeb6834).withAlphaComponent(0.12)
	static let parcelStroke = NSColor(hex: 0xeb6834)

	/// Per-mode band ramp for chart bars and legend swatches (light surface /
	/// dark surface steps of the same blue ramp).
	private static let chartBandHex: [(light: UInt32, dark: UInt32)] = [
		(0x86b6ef, 0xcde2fb),
		(0x5598e7, 0x86b6ef),
		(0x2a78d6, 0x3987e5),
		(0x1c5cab, 0x256abf),
		(0x104281, 0x184f95),
	]

	static func chartBand(_ band: AltitudeBand) -> Color {
		let hx = chartBandHex[band.rawValue]
		return Color(nsColor: .dynamic(light: hx.light, dark: hx.dark))
	}

	static let seriesBlue = Color(nsColor: .dynamic(light: 0x2a78d6, dark: 0x3987e5))
	static let ground = Color(nsColor: NSColor(hex: 0x898781))
	static let mutedInk = Color(nsColor: NSColor(hex: 0x898781))
	static let gridline = Color(nsColor: .dynamic(light: 0xe1e0d9, dark: 0x2c2c2a))

	// Status palette — good / warning / critical, always paired with a text label.
	static let statusGood = Color(nsColor: NSColor(hex: 0x0ca30c))
	static let statusWarning = Color(nsColor: NSColor(hex: 0xfab219))
	static let statusCritical = Color(nsColor: NSColor(hex: 0xd03b3b))
}
