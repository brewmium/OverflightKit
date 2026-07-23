import SwiftUI
import OverflightCore

/// Landing view for a new (or re-targeted) window: pick an existing site —
/// including one already open elsewhere, which gives you a clone — or add a
/// new one, ideally by ICAO lookup.
struct SitePickerView: View {
	let onPick: (SiteConfig, Config) -> Void

	@State private var config: Config = (try? Config.loadOrCreate()) ?? .kgmjDefault
	@State private var showingAdd = false

	// Add-site form fields (strings so partial input never fights a formatter)
	@State private var icao = ""
	@State private var displayName = ""
	@State private var latText = ""
	@State private var lonText = ""
	@State private var elevText = ""
	@State private var radiusText = "15"
	@State private var metarStation = ""
	@State private var timezone = TimeZone.current.identifier
	@State private var lookupBusy = false
	@State private var formError: String?

	var body: some View {
		VStack(spacing: 0) {
			List {
				Section("Open a site") {
					ForEach(config.sites) { site in
						Button {
							onPick(site, config)
						} label: {
							VStack(alignment: .leading, spacing: 2) {
								Text(site.title)
									.font(.headline)
								Text("\(String(format: "%.4f, %.4f", site.lat, site.lon)) - \(Int(site.radiusNm)) nm - \(site.slug)")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
					}
				}

				Section {
					DisclosureGroup("Add site", isExpanded: $showingAdd) {
						addForm
					}
				}
			}
		}
		.frame(minWidth: 480, minHeight: 420)
		.navigationTitle("Overflight — pick a site")
	}

	@ViewBuilder
	private var addForm: some View {
		HStack {
			TextField("ICAO (e.g. KTOL)", text: $icao)
				.textFieldStyle(.roundedBorder)
				.frame(width: 140)
				.onSubmit { lookUp() }
			Button(lookupBusy ? "Looking up..." : "Look up") { lookUp() }
				.disabled(lookupBusy || icao.trimmingCharacters(in: .whitespaces).isEmpty)
			Spacer()
		}
		Text("Fills location, elevation, and name from the station's METAR.")
			.font(.caption2)
			.foregroundStyle(.secondary)
		TextField("Display name", text: $displayName)
		HStack {
			TextField("Latitude", text: $latText)
			TextField("Longitude", text: $lonText)
		}
		HStack {
			TextField("Field elevation (ft)", text: $elevText)
			TextField("Radius (nm)", text: $radiusText)
		}
		HStack {
			TextField("METAR station", text: $metarStation)
			TextField("Timezone", text: $timezone)
		}
		if let formError {
			Label(formError, systemImage: "exclamationmark.triangle.fill")
				.font(.caption)
				.foregroundStyle(Viz.statusCritical)
		}
		HStack {
			Spacer()
			Button("Create site") { create() }
				.keyboardShortcut(.defaultAction)
				.disabled(latText.isEmpty || lonText.isEmpty || displayName.isEmpty)
		}
		Text("The new site starts collecting once its agent is installed:\nscripts/install-agent.sh <slug>")
			.font(.caption2)
			.foregroundStyle(.secondary)
	}

	private func lookUp() {
		let id = icao.trimmingCharacters(in: .whitespaces).uppercased()
		guard !id.isEmpty else { return }
		lookupBusy = true
		formError = nil
		Task {
			defer { lookupBusy = false }
			do {
				let info = try await MetarClient.stationInfo(icao: id)
				icao = info.icao
				displayName = info.name
				latText = String(format: "%.4f", info.lat)
				lonText = String(format: "%.4f", info.lon)
				elevText = String(Int(info.elevFt.rounded()))
				metarStation = info.icao
			} catch {
				formError = "\(error)"
			}
		}
	}

	private func create() {
		guard let lat = Double(latText), let lon = Double(lonText) else {
			formError = "latitude/longitude must be numbers"
			return
		}
		guard TimeZone(identifier: timezone) != nil else {
			formError = "unknown timezone identifier '\(timezone)'"
			return
		}
		let cleanedIcao = icao.trimmingCharacters(in: .whitespaces).uppercased()
		let slugBase = cleanedIcao.isEmpty
			? displayName.lowercased().filter { $0.isLetter || $0.isNumber }
			: cleanedIcao.lowercased()
		var slug = slugBase.isEmpty ? "site" : slugBase
		var n = 2
		while config.sites.contains(where: { $0.slug == slug }) {
			slug = "\(slugBase)\(n)"
			n += 1
		}
		let site = SiteConfig(
			slug: slug,
			icao: cleanedIcao.isEmpty ? nil : cleanedIcao,
			displayName: displayName,
			lat: lat, lon: lon,
			fieldElevationFt: Double(elevText) ?? 0,
			radiusNm: Double(radiusText) ?? 15,
			metarStation: metarStation.isEmpty ? (cleanedIcao.isEmpty ? nil : cleanedIcao) : metarStation,
			timezone: timezone
		)
		var updated = config
		updated.upsert(site: site)
		do {
			try updated.save()
			config = updated
			onPick(site, updated)
		} catch {
			formError = "saving config: \(error)"
		}
	}
}
