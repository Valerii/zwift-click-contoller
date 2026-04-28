# Zwift Click - macOS BLE Listener

A macOS command-line tool that connects to a Zwift Click device over Bluetooth and injects keyboard events based on button presses. Runs silently in the background as a LaunchAgent and can automatically connect/disconnect based on whether a target app (e.g. MyWhoosh) is running.

## Features

- Connects to Zwift Click using the full ZAP encrypted BLE protocol (ECDH + AES-CCM)
- Tap vs. hold detection per button - four assignable actions total
- Injects real keyboard events system-wide via Accessibility API
- Auto-reconnects if the device disconnects or goes to sleep
- Optional app watcher: connect when a target app launches, disconnect when it quits
- JSON config file for all settings

## Requirements

- macOS 13 or later
- Xcode Command Line Tools

```
xcode-select --install
```

## Build

```
swift build -c release
```

The binary will be at `.build/release/ZwiftClick`.

To install system-wide:

```
cp .build/release/ZwiftClick /usr/local/bin/ZwiftClick
```

## Permissions

Two permissions are required on first run:

- **Bluetooth** - macOS will prompt automatically when the app first scans.
- **Accessibility** - required for keyboard injection. Go to **System Settings > Privacy & Security > Accessibility** and add your terminal (or the ZwiftClick binary if running as a LaunchAgent).

## Configuration

Generate a default config file:

```
ZwiftClick --write-config
```

This creates `~/.config/zwift-click/config.json`:

```json
{
  "holdMinus": "pagedown",
  "holdPlus": "pageup",
  "holdThreshold": 0.3,
  "tapMinus": "down",
  "tapPlus": "up",
  "watchApp": null
}
```

Edit this file to change key assignments and behavior.

### Config fields

| Field | Default | Description |
|---|---|---|
| `tapPlus` | `"up"` | Key sent on short press of `+` |
| `tapMinus` | `"down"` | Key sent on short press of `-` |
| `holdPlus` | `"pageup"` | Key sent on long press of `+` |
| `holdMinus` | `"pagedown"` | Key sent on long press of `-` |
| `holdThreshold` | `0.3` | Seconds before a press is considered a hold |
| `watchApp` | `null` | App name or bundle ID to watch (see below) |

### Available key names

```
up, down, left, right, pageup, pagedown, space, return, tab, escape
f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
a, b, c, d, e, f, g, h, i, j, k, l, m,
n, o, p, q, r, s, t, u, v, w, x, y, z
```

### Example: MyWhoosh Indoor Cycling App

The config below connects only when MyWhoosh is running. `k` shifts up, `i` shifts down (matching MyWhoosh's default keyboard shortcuts). Hold either button for Page Up / Page Down as a fallback.

```json
{
  "tapPlus": "k",
  "tapMinus": "i",
  "holdPlus": "k",
  "holdMinus": "i",
  "holdThreshold": 0.3,
  "watchApp": "com.whoosh.whooshgame"
}
```

To verify the bundle ID on a machine where MyWhoosh is installed, run:

```
osascript -e 'id of app "MyWhoosh"'
```

The `watchApp` field accepts either:
- The app's bundle ID (recommended), e.g. `"com.whoosh.whooshgame"`
- The app's display name, e.g. `"MyWhoosh"` or `"Zwift"`

When `watchApp` is set, ZwiftClick will:
- Wait idle on launch until the target app opens
- Connect to the Zwift Click when the target app launches
- Disconnect and release the BLE connection when the target app quits
- Reconnect automatically the next time the target app launches

When `watchApp` is `null`, ZwiftClick stays connected at all times.

### Custom config path

```
ZwiftClick --config /path/to/my-config.json
```

---

## Running as a LaunchAgent (start on login)

A LaunchAgent runs ZwiftClick silently in the background every time you log in - no terminal required. It will sit idle until MyWhoosh (or your configured app) launches.

### 1. Install the binary

```
cp .build/release/ZwiftClick /usr/local/bin/ZwiftClick
```

### 2. Create the LaunchAgent plist

Create the file `~/Library/LaunchAgents/com.zwiftclick.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.zwiftclick</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/ZwiftClick</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/zwift-click.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/zwift-click.log</string>
</dict>
</plist>
```

### 3. Load the agent

```
launchctl load ~/Library/LaunchAgents/com.zwiftclick.plist
```

### 4. Grant Accessibility permission to the binary

Go to **System Settings > Privacy & Security > Accessibility**, click `+`, and add `/usr/local/bin/ZwiftClick`.

### Managing the LaunchAgent

| Action | Command |
|---|---|
| Start | `launchctl load ~/Library/LaunchAgents/com.zwiftclick.plist` |
| Stop | `launchctl unload ~/Library/LaunchAgents/com.zwiftclick.plist` |
| View logs | `tail -f /tmp/zwift-click.log` |
| Restart after config change | `launchctl unload ... && launchctl load ...` |

---

## Usage without LaunchAgent

Run manually in a terminal:

```
ZwiftClick
```

Turn on your Zwift Click (hold the button until the LED pulses blue). The app connects automatically.

```
Loaded config from /Users/you/.config/zwift-click/config.json
Waiting for MyWhoosh to launch...
[MyWhoosh] launched - connecting Zwift Click.
Scanning for Zwift Click...
Found - connecting...
Encrypted handshake sent.
Ready. Listening for button events.
+ tap  -> pageup
- tap  -> pagedown
[MyWhoosh] quit - disconnecting Zwift Click.
BLE disabled - waiting for watched app to relaunch.
```

Press `Ctrl+C` to quit.

---

## How it works

The Zwift Click communicates over BLE using the Zwift Accessory Protocol (ZAP). Current firmware requires a full encrypted handshake:

1. Generate an ephemeral ECDH P-256 key pair
2. Subscribe to the async (button events) and sync-tx (handshake response) characteristics
3. Send `RideOn` + `\x01\x02` + 64-byte public key to the sync-rx characteristic
4. Device responds with its 64-byte public key on sync-tx
5. Derive a 36-byte shared key via HKDF-SHA256 (salt = device pub + our pub, no info string)
6. Button events arrive AES-CCM encrypted (32-byte key, 8-byte nonce, 4-byte tag)
7. Decrypted payload: `[0x37, 0x08, plusState, 0x10, minusState]` where `0` = pressed
