#!/bin/sh
# Stop the collector LaunchAgent and remove it. Data, config, and logs under
# ~/.overflight are left in place.
set -eu

LABEL="com.overflightkit.collector"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "Agent stopped and removed. Database and config remain in ~/.overflight/"
