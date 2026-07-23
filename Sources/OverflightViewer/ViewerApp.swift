import SwiftUI
import AppKit

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

@main
struct OverflightViewerApp: App {
	@State private var model = ViewerModel()

	init() {
		// Running from `swift run` there is no app bundle; promote to a
		// regular app so the window fronts and gets a menu bar.
		NSApplication.shared.setActivationPolicy(.regular)
	}

	var body: some Scene {
		WindowGroup("Overflight Viewer") {
			ContentView()
				.environment(model)
				.onAppear {
					NSApp.activate(ignoringOtherApps: true)
				}
		}
	}
}
