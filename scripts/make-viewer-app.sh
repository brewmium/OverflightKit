#!/bin/sh
# Wrap the viewer executable in a minimal .app bundle so it gets a Dock icon,
# a proper name, and normal window behavior. Output: "Overflight Viewer.app"
# in the repo root.
set -eu
cd "$(dirname "$0")/.."

echo "Building OverflightViewer (release)..."
swift build -c release --product OverflightViewer
BIN_DIR="$(swift build -c release --product OverflightViewer --show-bin-path)"

APP="Overflight Viewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/OverflightViewer" "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>OverflightViewer</string>
	<key>CFBundleIdentifier</key>
	<string>com.overflightkit.viewer</string>
	<key>CFBundleName</key>
	<string>Overflight Viewer</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

echo "Created $APP — open it, or copy to /Applications."
