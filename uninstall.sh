#!/usr/bin/env bash
set -euo pipefail

BINARY_NAME="ZwiftClick"
INSTALL_PATH="/usr/local/bin/$BINARY_NAME"
PLIST_LABEL="com.zwiftclick"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

echo "Stopping and removing ZwiftClick..."

if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "LaunchAgent removed."
else
    echo "No LaunchAgent plist found - skipping."
fi

if [ -f "$INSTALL_PATH" ]; then
    sudo rm -f "$INSTALL_PATH"
    echo "Binary removed from $INSTALL_PATH."
else
    echo "No binary found at $INSTALL_PATH - skipping."
fi

echo ""
echo "ZwiftClick uninstalled."
echo "Your config at ~/.config/zwift-click/config.json was not removed."
echo "Delete it manually if you no longer need it."
