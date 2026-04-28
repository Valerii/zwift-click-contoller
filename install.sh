#!/usr/bin/env bash
set -euo pipefail

BINARY_NAME="ZwiftClick"
INSTALL_PATH="/usr/local/bin/$BINARY_NAME"
PLIST_LABEL="com.zwiftclick"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
CONFIG_PATH="$HOME/.config/zwift-click/config.json"
LOG_PATH="/tmp/zwift-click.log"

# ── 1. Build ──────────────────────────────────────────────────────────────────
echo "Building $BINARY_NAME..."
swift build -c release
echo "Build complete."

# ── 2. Install binary ─────────────────────────────────────────────────────────
echo "Installing binary to $INSTALL_PATH..."
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

    <key>KeepAlive</key>
    <true/>

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
# Unload first in case it was already loaded
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
echo "LaunchAgent loaded."

# ── 6. Done ───────────────────────────────────────────────────────────────────
echo ""
echo "Done! ZwiftClick is now running in the background."
echo ""
echo "Next steps:"
echo "  1. Edit your config:  open $CONFIG_PATH"
echo "  2. Grant Accessibility permission to $INSTALL_PATH"
echo "     System Settings > Privacy & Security > Accessibility > (+) $INSTALL_PATH"
echo "  3. After editing config, restart:"
echo "     launchctl unload $PLIST_PATH && launchctl load $PLIST_PATH"
echo "  4. View logs: tail -f $LOG_PATH"
