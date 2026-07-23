import SwiftUI
import AppKit
import OverflightCore

struct ContentView: View {
	@Environment(ViewerModel.self) private var model

	var body: some View {
		VStack(spacing: 0) {
			HSplitView {
				MapPane()
					.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
				SidePanel()
					.frame(minWidth: 320, idealWidth: 350, maxWidth: 420)
			}
			Divider()
			StatusStrip()
		}
		.frame(minWidth: 940, minHeight: 640)
		.task { model.start() }
	}
}

/// One window bound to one site. `.id(site.slug)` upstream guarantees a fresh
/// model whenever the site changes, and picking the already-active site from
/// another window simply yields a clone.
struct SiteWindow: View {
	let site: SiteConfig
	let config: Config
	let onSwitch: (SiteConfig, Config) -> Void
	@State private var model: ViewerModel

	init(site: SiteConfig, config: Config, onSwitch: @escaping (SiteConfig, Config) -> Void) {
		self.site = site
		self.config = config
		self.onSwitch = onSwitch
		_model = State(initialValue: ViewerModel(site: site, config: config))
	}

	var body: some View {
		ContentView()
			.environment(model)
			.navigationTitle(model.windowTitle)
			.toolbar {
				ToolbarItem {
					Menu {
						ForEach(config.sites) { s in
							Button {
								onSwitch(s, config)
							} label: {
								if s.slug == site.slug {
									Label(s.title, systemImage: "checkmark")
								} else {
									Text(s.title)
								}
							}
						}
						Divider()
						Button("Other site...") {
							onSwitch(site, config)
							// Handled by WindowRoot: clearing selection reopens the picker.
						}
					} label: {
						Label(site.icao ?? site.slug.uppercased(), systemImage: "airplane.circle")
					}
					.help("Switch this window to another site")
				}
			}
	}
}

struct WindowRoot: View {
	@State private var selection: (site: SiteConfig, config: Config)?
	@State private var showPicker = false

	var body: some View {
		Group {
			if let selection, !showPicker {
				SiteWindow(site: selection.site, config: selection.config) { site, config in
					if site.slug == selection.site.slug {
						showPicker = true
					} else {
						self.selection = (site, config)
					}
				}
				.id(selection.site.slug)
			} else {
				SitePickerView { site, config in
					selection = (site, config)
					showPicker = false
				}
			}
		}
	}
}

@main
struct OverflightViewerApp: App {
	init() {
		// Running from `swift run` there is no app bundle; promote to a
		// regular app so the window fronts and gets a menu bar.
		NSApplication.shared.setActivationPolicy(.regular)
	}

	var body: some Scene {
		WindowGroup {
			WindowRoot()
				.onAppear {
					NSApp.activate(ignoringOtherApps: true)
				}
		}
	}
}
