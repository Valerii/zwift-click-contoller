#!/usr/bin/env bash
set -euo pipefail

BINARY_NAME="ZwiftClickV2"
INSTALL_PATH="/usr/local/bin/$BINARY_NAME"
PLIST_LABEL="com.zwiftclickv2"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

echo "Stopping and removing $BINARY_NAME..."

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
echo "$BINARY_NAME uninstalled."
echo "Your config at ~/.config/zwift-click-v2/config.json was not removed."
echo "Delete it manually if you no longer need it."
