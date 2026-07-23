#!/bin/sh
# Build the collector in release mode, install it under ~/.overflight, and
# load one LaunchAgent per site so each runs headless and restarts on
# failure/login.
#
#   scripts/install-agent.sh            # agents for every configured site
#   scripts/install-agent.sh toledo     # just that site
set -eu
cd "$(dirname "$0")/.."

INSTALL_DIR="$HOME/.overflight"

echo "Building OverflightCollector (release)..."
swift build -c release --product OverflightCollector
BIN_DIR="$(swift build -c release --product OverflightCollector --show-bin-path)"
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/log" "$HOME/Library/LaunchAgents"

# Unload everything that might hold the old binary open, including the
# pre-multi-site unsuffixed label.
launchctl bootout "gui/$(id -u)/com.overflightkit.collector" 2>/dev/null || true
for existing in "$HOME"/Library/LaunchAgents/com.overflightkit.collector.*.plist; do
	[ -e "$existing" ] || continue
	launchctl bootout "gui/$(id -u)/$(basename "$existing" .plist)" 2>/dev/null || true
done
rm -f "$HOME/Library/LaunchAgents/com.overflightkit.collector.plist"

cp "$BIN_DIR/OverflightCollector" "$INSTALL_DIR/bin/"

if [ $# -gt 0 ]; then
	SLUGS="$*"
else
	SLUGS="$("$INSTALL_DIR/bin/OverflightCollector" --list-sites | cut -f1)"
fi

for SLUG in $SLUGS; do
	LABEL="com.overflightkit.collector.$SLUG"
	PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
	sed -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" -e "s|__SLUG__|$SLUG|g" \
		launchd/com.overflightkit.collector.plist.template > "$PLIST_DEST"
	launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
	echo "started $LABEL -> log/$SLUG.log"
done

echo ""
echo "Useful commands:"
echo "  tail -f $INSTALL_DIR/log/<slug>.log"
echo "  $INSTALL_DIR/bin/OverflightCollector --report --site <slug>"
echo "  scripts/uninstall-agent.sh [slug]"
