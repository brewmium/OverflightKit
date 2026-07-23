#!/bin/sh
# Build the collector in release mode, install it under ~/.overflight, and
# load it as a LaunchAgent so it runs headless and restarts on failure/login.
set -eu
cd "$(dirname "$0")/.."

INSTALL_DIR="$HOME/.overflight"
LABEL="com.overflightkit.collector"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "Building OverflightCollector (release)..."
swift build -c release --product OverflightCollector

BIN_DIR="$(swift build -c release --product OverflightCollector --show-bin-path)"
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/log" "$HOME/Library/LaunchAgents"

# Unload any existing agent before replacing the running binary.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

cp "$BIN_DIR/OverflightCollector" "$INSTALL_DIR/bin/"
sed "s|__INSTALL_DIR__|$INSTALL_DIR|g" launchd/$LABEL.plist.template > "$PLIST_DEST"

launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

echo ""
echo "Installed and started. Useful commands:"
echo "  tail -f $INSTALL_DIR/log/collector.log        # watch it work"
echo "  launchctl print gui/$(id -u)/$LABEL           # agent status"
echo "  $INSTALL_DIR/bin/OverflightCollector --report # histograms + coverage"
echo "  scripts/uninstall-agent.sh                    # stop and remove"
echo ""
echo "Config: $INSTALL_DIR/config.json (created with KGMJ defaults on first run)"
