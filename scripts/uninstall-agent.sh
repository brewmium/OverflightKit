#!/bin/sh
# Stop collector LaunchAgents and remove them. Data, config, and logs under
# ~/.overflight are left in place.
#
#   scripts/uninstall-agent.sh          # all sites
#   scripts/uninstall-agent.sh toledo   # just that site
set -eu

remove() {
	LABEL="$1"
	launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
	rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
	echo "removed $LABEL"
}

if [ $# -gt 0 ]; then
	for SLUG in "$@"; do
		remove "com.overflightkit.collector.$SLUG"
	done
else
	remove "com.overflightkit.collector"
	for existing in "$HOME"/Library/LaunchAgents/com.overflightkit.collector.*.plist; do
		[ -e "$existing" ] || continue
		remove "$(basename "$existing" .plist)"
	done
fi

echo "Databases and config remain in ~/.overflight/"
