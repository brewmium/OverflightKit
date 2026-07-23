import Foundation
import OverflightCore

/// Installs and starts the LaunchAgent for a site from inside the viewer, so
/// a freshly added site can begin collecting without a trip to the terminal.
/// Requires the collector binary that scripts/install-agent.sh places under
/// ~/.overflight/bin on its first run.
enum AgentInstaller {
	static func startCollector(site: SiteConfig) async throws {
		let home = NSHomeDirectory()
		let installDir = home + "/.overflight"
		let binPath = installDir + "/bin/OverflightCollector"
		guard FileManager.default.fileExists(atPath: binPath) else {
			throw OverflightError.notFound(
				"collector binary not installed — run scripts/install-agent.sh from the repo once, then this button works for every new site"
			)
		}
		try FileManager.default.createDirectory(atPath: installDir + "/log", withIntermediateDirectories: true)
		let agentsDir = home + "/Library/LaunchAgents"
		try FileManager.default.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)

		let label = "com.overflightkit.collector.\(site.slug)"
		let plist = """
		<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
		<plist version="1.0">
		<dict>
			<key>Label</key>
			<string>\(label)</string>
			<key>ProgramArguments</key>
			<array>
				<string>\(binPath)</string>
				<string>--site</string>
				<string>\(site.slug)</string>
			</array>
			<key>RunAtLoad</key>
			<true/>
			<key>KeepAlive</key>
			<true/>
			<key>ThrottleInterval</key>
			<integer>10</integer>
			<key>ProcessType</key>
			<string>Background</string>
			<key>StandardOutPath</key>
			<string>\(installDir)/log/\(site.slug).log</string>
			<key>StandardErrorPath</key>
			<string>\(installDir)/log/\(site.slug).err.log</string>
		</dict>
		</plist>
		"""
		let plistPath = agentsDir + "/\(label).plist"
		try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)

		let domain = "gui/\(getuid())"
		_ = launchctl(["bootout", "\(domain)/\(label)"])
		// bootout is asynchronous — wait for any old instance to finish
		// unloading, then retry the bootstrap through the transient EIO.
		for _ in 0..<10 where launchctl(["print", "\(domain)/\(label)"]) == 0 {
			try await Task.sleep(for: .seconds(1))
		}
		var status: Int32 = -1
		for attempt in 0..<5 {
			if attempt > 0 {
				try await Task.sleep(for: .seconds(1))
			}
			status = launchctl(["bootstrap", domain, plistPath])
			if status == 0 { break }
		}
		guard status == 0 else {
			throw OverflightError.badResponse("launchctl bootstrap failed with status \(status)")
		}
	}

	private static func launchctl(_ args: [String]) -> Int32 {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
		p.arguments = args
		p.standardOutput = FileHandle.nullDevice
		p.standardError = FileHandle.nullDevice
		do {
			try p.run()
		} catch {
			return -1
		}
		p.waitUntilExit()
		return p.terminationStatus
	}
}
