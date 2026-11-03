#!/usr/bin/env bash
set -euo pipefail

BINARY_NAME="ZwiftClickV2"
INSTALL_PATH="/usr/local/bin/$BINARY_NAME"
PLIST_LABEL="com.zwiftclickv2"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
CONFIG_PATH="$HOME/.config/zwift-click-v2/config.json"
LOG_PATH="/tmp/zwift-click-v2.log"

# ── 1. Build ──────────────────────────────────────────────────────────────────
echo "Building $BINARY_NAME..."
swift build -c release
echo "Build complete."

# ── 2. Install binary ─────────────────────────────────────────────────────────
echo "Installing binary to $INSTALL_PATH..."
sudo mkdir -p "$(dirname "$INSTALL_PATH")"
sudo cp ".build/release/$BINARY_NAME" "$INSTALL_PATH"
sudo chmod +x "$INSTALL_PATH"
echo "Binary installed."

# ── 3. Generate default config (skip if already exists) ───────────────────────
if [ ! -f "$CONFIG_PATH" ]; then
    echo "Creating default config at $CONFIG_PATH..."
    "$INSTALL_PATH" --write-config
else
    echo "Config already exists at $CONFIG_PATH - skipping."
fi

# ── 4. Write LaunchAgent plist ────────────────────────────────────────────────
echo "Writing LaunchAgent plist to $PLIST_PATH..."
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_PATH</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <!-- Restart only after a crash. A normal exit (e.g. "already running") must not restart-loop. -->
    <key>KeepAlive</key>
    <dict>
        <key>Crashed</key>
        <true/>
    </dict>

    <key>StandardOutPath</key>
    <string>$LOG_PATH</string>

    <key>StandardErrorPath</key>
    <string>$LOG_PATH</string>
</dict>
</plist>
EOF
echo "Plist written."

# ── 5. Reload LaunchAgent ─────────────────────────────────────────────────────
echo "Loading LaunchAgent..."
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
echo "LaunchAgent loaded."

# ── 6. Done ───────────────────────────────────────────────────────────────────
echo ""
echo "Done! $BINARY_NAME is now running in the background."
echo ""
echo "Next steps:"
echo "  1. Edit your config:  open $CONFIG_PATH"
echo "  2. Grant Accessibility permission to $INSTALL_PATH"
echo "     System Settings > Privacy & Security > Accessibility > (+) $INSTALL_PATH"
echo "     (re-add it after every reinstall - a rebuilt binary counts as a new app)"
echo "  3. After editing config, restart:"
echo "     launchctl unload $PLIST_PATH && launchctl load $PLIST_PATH"
echo "  4. View logs: tail -f $LOG_PATH"
