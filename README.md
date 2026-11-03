# Zwift Click v1 + v2 - macOS BLE Listener

A macOS command-line tool that connects to a **Zwift Click v1** and/or both **Zwift Click v2** controllers ("pucks") over Bluetooth and injects keyboard events based on button presses. It runs silently in the background as a LaunchAgent and can connect/disconnect automatically based on whether a target app (e.g. MyWhoosh) is running.

Successor of [zwift-click-contoller](https://github.com/Valerii/zwift-click-contoller) (Click v1 only). It replaces it: uninstall the old app, otherwise both race for the Click v1 (see [Known Behavior](#only-one-app-per-controller)).

## Features

- Works with whichever controllers are switched on - Click v1, Click v2, or both at once. Switch between them any time without restarting
- Can be limited to only Click v1 or only Click v2 (see [Choosing controller versions](#choosing-controller-versions))
- **Click v1**: `plus`, `minus` (encrypted protocol, handled automatically)
- **Click v2**: both pucks, 10 buttons total:
  - Left puck: `up`, `down`, `left`, `right`, `minus`
  - Right puck: `y`, `z`, `b`, `a`, `plus`
- Every log line says which controller it came from (`[Click v1]`, `[Click v2 left]`, `[Click v2 right]`)
- Tap vs. hold detection per button, with auto-repeat while held
- Pressing several buttons at once works
- Each controller reconnects independently - if one sleeps or drops, the others keep working
- Warns when the left puck looks "locked" (see [Known Behavior](#left-puck-lock))
- Optional app watcher: connect when a target app launches, disconnect when it quits
- JSON config, validated at startup (typos in key names are reported)

## Requirements

- macOS 13 or later
- Xcode Command Line Tools: `xcode-select --install`

## Build and test

```
swift build -c release
./test.sh
```

The binary will be at `.build/release/ZwiftClickV2`.

## Permissions

- **Bluetooth** - macOS prompts automatically on first scan (for your terminal, or the binary when run as a LaunchAgent).
- **Accessibility** - required for keyboard injection. **System Settings > Privacy & Security > Accessibility**, add your terminal or `/usr/local/bin/ZwiftClickV2`. Re-add it after reinstalling: a rebuilt binary counts as a new app.

## Configuration

```
ZwiftClickV2 --write-config
```

creates `~/.config/zwift-click-v2/config.json` (it never overwrites an existing file):

```json
{
  "buttons" : {
    "a" :     { "tap" : "return" },
    "b" :     { "tap" : "escape" },
    "down" :  { "tap" : "down" },
    "left" :  { "tap" : "left" },
    "minus" : { "hold" : "i", "tap" : "i" },
    "plus" :  { "hold" : "k", "tap" : "k" },
    "right" : { "tap" : "right" },
    "up" :    { "tap" : "up" },
    "y" :     { "tap" : "space" },
    "z" :     { "tap" : "tab" }
  },
  "controllers" : [
    "v1",
    "v2"
  ],
  "holdRepeatInterval" : 0.2,
  "holdThreshold" : 0.3,
  "watchApp" : "com.whoosh.whooshgame" 
}
```

`plus`/`minus` default to `k`/`i`, MyWhoosh's shift up/down keys. The Click v1's `+`/`-` use the same `plus`/`minus` entries as the Click v2.

### Config fields

| Field | Default | Description |
|---|---|---|
| `buttons.<name>.tap` | see above | Key sent on a short press. `null` = do nothing |
| `buttons.<name>.hold` | same as `tap` | Key sent when held past `holdThreshold`, repeated every `holdRepeatInterval` |
| `controllers` | `["v1", "v2"]` | Controller versions to use: `"v1"`, `"v2"`, or both. See below |
| `holdThreshold` | `0.3` | Seconds before a press counts as a hold |
| `holdRepeatInterval` | `0.2` | Seconds between repeats while holding |
| `watchApp` | `null` | App name or bundle ID to watch (see below) |

Button names: `up`, `down`, `left`, `right`, `minus`, `y`, `z`, `b`, `a`, `plus`. A button left out of `buttons` does nothing. Every field is optional - missing ones use the defaults.

### Available key names

```
up, down, left, right, pageup, pagedown, space, return, tab, escape, delete
f1 ... f12
a ... z
0 ... 9
```

### Choosing controller versions

By default ZwiftClickV2 uses both versions and connects to whichever Click is switched on. To use only one, set `controllers`:

```json
{ "controllers": ["v2"] }
```

| Setting | Connects to |
|---|---|
| `["v1", "v2"]` (default, also when the field is missing) | Click v1 and both Click v2 pucks |
| `["v1"]` | Click v1 only |
| `["v2"]` | Click v2 pucks only |

A disabled version is never connected, so it stays free for other apps or devices. The startup log shows what is active:

```
15:20:01.125 Controllers: Click v2 only
```

ZwiftClickV2 keeps watching for the disabled version, so if one is switched on (LED blinking blue, waiting to pair) you can see in the log why it doesn't connect. Each device is reported at most once a minute:

```
15:21:10.402 ⚠️  Click v1 is switched on nearby but ignored - only Click v2 is enabled ("controllers" setting or --only). Add "v1" to "controllers" in the config to use it.
```

An unknown entry (e.g. `"v3"`) is reported as a config error and skipped. If nothing valid is left (e.g. `[]`), both versions are used, so a typo never leaves you with an app that connects to nothing. Restart after changing it (see the LaunchAgent table below).

To try one version without editing the config, use `--only` (it overrides `controllers`):

```
ZwiftClickV2 --only v1 --debug
```

### Watching an app (e.g. MyWhoosh)

```json
{ "watchApp": "com.whoosh.whooshgame" }
```

`watchApp` accepts a bundle ID (recommended - check it with `osascript -e 'id of app "MyWhoosh"'`) or a display name such as `"MyWhoosh"`. When set, ZwiftClickV2 waits idle, connects when the app launches and releases all controllers when it quits. When `null`, it stays connected all the time.

### Options

```
ZwiftClickV2 --config /path/to/config.json   # custom config path
ZwiftClickV2 --only v1                       # use only Click v1 (or v2), overrides "controllers"
ZwiftClickV2 --debug                         # log every raw BLE packet and discovered device
```

---

## Install as a LaunchAgent (start on login)

```
./install.sh
```

This builds the release binary, copies it to `/usr/local/bin/ZwiftClickV2`, creates a default config if there is none, writes `~/Library/LaunchAgents/com.zwiftclickv2.plist`, and starts the agent. Then grant Accessibility permission to `/usr/local/bin/ZwiftClickV2`. The agent restarts automatically if it crashes, but not after a normal quit.

| Action | Command |
|---|---|
| View logs | `tail -f /tmp/zwift-click-v2.log` |
| Restart after config change | `launchctl unload ~/Library/LaunchAgents/com.zwiftclickv2.plist && launchctl load ~/Library/LaunchAgents/com.zwiftclickv2.plist` |
| Stop | `launchctl unload ~/Library/LaunchAgents/com.zwiftclickv2.plist` |
| Start | `launchctl load ~/Library/LaunchAgents/com.zwiftclickv2.plist` |
| Uninstall | `./uninstall.sh` (keeps your config) |

---

## Usage without LaunchAgent

```
ZwiftClickV2
```

Wake your controller(s) by pressing any button (the LED flashes blue, then turns solid once connected). Click v2:

```
15:20:01.120 Loaded config from /Users/you/.config/zwift-click-v2/config.json
15:20:01.125 Controllers: Click v1 + Click v2
15:20:01.130 Scanning for Zwift Click v1 and Click v2 (left + right puck)...
15:20:02.010 Found Click v2 left puck - connecting...
15:20:02.300 Found Click v2 right puck - connecting...
15:20:03.400 Click v2 left puck ready.
15:20:04.100 Click v2 right puck ready.
15:20:04.100 Click v2: both pucks ready. Listening for button events.
15:20:04.200 Click v2 left puck battery: 100%
15:20:09.510 [Click v2 right] plus  tap  -> k
15:20:11.020 [Click v2 left] minus hold -> i
```

Click v1:

```
15:25:00.010 Found Click v1 - connecting...
15:25:01.200 Click v1 ready. Listening for button events.
15:25:03.480 [Click v1] plus  tap  -> k
```

Scanning continues while a controller is missing, so you can turn the Click v2 off and the Click v1 on (or the other way round) and it connects on its own.

Press `Ctrl+C` to quit.

---

## Known Behavior

### Left puck lock

Reports from other projects ([BikeControl #68](https://github.com/jonasbark/swiftcontrol/issues/68)) say the left puck stops sending button events about a minute after connecting, unless the Click v2 was connected to the official Zwift app within the last ~24 hours. The right puck is not affected.

This has **not** been reproduced on firmware 1.0.2: both pucks kept working for several minutes. If it does happen, ZwiftClickV2 detects it (the left puck stops relaying right-puck presses, see below) and logs:

```
⚠️  The Click v2 left puck seems to have stopped sending button events ...
```

To unlock: open the Zwift app (desktop or mobile, not Companion), log in (no subscription needed), connect your trainer and the Click v2, keep it connected for ~30 seconds, then quit Zwift completely.

### Firmware updates

Firmware 1.0.2 works without any unlock in testing. Later firmware has been reported to need the Zwift unlock more often, and updates can break third-party apps. Avoid updating via Zwift Companion unless you need to.

### Only one app per controller

A controller can be connected to only one app at a time. The old Click v1 app ([zwift-click-contoller](https://github.com/Valerii/zwift-click-contoller), LaunchAgent `com.zwiftclick`) would grab the Click v1 before ZwiftClickV2 sees it, so remove it: `launchctl unload ~/Library/LaunchAgents/com.zwiftclick.plist` (or its `uninstall.sh`). If you want to keep the old app for the Click v1, set `"controllers": ["v2"]` here instead so the two never compete.

### Only one copy runs at a time - the newest one wins

Likewise for two copies of ZwiftClickV2. If you start ZwiftClickV2 while another copy is running (e.g. `.build/release/ZwiftClickV2 --debug` while the LaunchAgent runs), the new copy stops the old one and takes over the controllers:

```
15:52:40.101 Another ZwiftClickV2 is running (PID 30562) - stopping it and taking over the controllers...
15:52:40.640 Scanning for Zwift Click v1 and Click v2 (left + right puck)...
```

If the replaced copy was the LaunchAgent, it stays stopped until your next login or `launchctl load ~/Library/LaunchAgents/com.zwiftclickv2.plist`. The lock lives in `~/Library/Caches/zwift-click-v2.lock` and is released automatically whenever the process exits.

### Quitting releases the controllers

On `Ctrl+C` or `launchctl unload`, ZwiftClickV2 disconnects every controller before exiting, so they are free for Zwift or another app straight away. Press `Ctrl+C` twice to quit immediately.

### Controller not found after 1 minute

ZwiftClickV2 logs a warning every minute when no controller is connected, or when one Click v2 puck is connected but its partner is not (it never nags about a controller you may not own). Common causes: the controller is asleep (press a button), it is connected to another app or device (Zwift, BikeControl, a phone, the old v1 app - BLE allows only one host), or its CR2032 battery is flat.

---

## How it works

### Click v2

Observed on firmware 1.0.2. Unlike v1, there is no encryption.

| | |
|---|---|
| Advertising | Each puck is a separate peripheral named "Zwift Click", advertising service `FC82`. Manufacturer data `4a 09 <type> ...` - company `0x094A` (Zwift), type `0x0B` = left, `0x0A` = right |
| Characteristics | `00000002-19ca-4651-86e5-fa29dcdd09d1` async (notify) · `...0003` sync-rx (write without response) · `...0004` sync-tx (indicate) |
| Handshake | Subscribe to async + sync-tx, write `RideOn` + `02 03` to sync-rx; the puck echoes it on sync-tx |
| Buttons | `0x23` + protobuf; field 1 is a bitmap where a **0** bit means pressed: left `0x001`, up `0x002`, right `0x004`, down `0x008`, a `0x010`, b `0x020`, y `0x040`, z `0x080`, minus `0x100`, plus `0x1000` |
| Relay | The left puck also reports the right puck's bits (~20-30 ms later). ZwiftClickV2 only takes each puck's own buttons, so presses never fire twice - and uses the relay to detect a locked left puck |
| Other | `0x19` battery (`19 10 64` = 100%), `0x2a` debug log text every ~5 s, `0xff` pairing data - ignored |

### Click v1

Same protocol as the v1 app, where it works on real hardware.

| | |
|---|---|
| Advertising | Named "Zwift Click", service `00000001-19ca-4651-86e5-fa29dcdd09d1`, manufacturer type `0x09` |
| Characteristics | Same as Click v2: `...0002` async, `...0003` sync-rx, `...0004` sync-tx |
| Handshake | Write `RideOn` + `01 02` + a fresh P-256 public key (64 bytes); the Click answers `RideOn` + `01 03` + its public key. ECDH + HKDF-SHA256 derive an AES key and IV prefix |
| Buttons | Async packets are AES-CCM encrypted (`counter(4)` + ciphertext + `tag(4)`). Decrypted: `0x37` + protobuf, field 1 = plus, field 2 = minus, `0` = pressed |

Detection uses the manufacturer type, so other Zwift devices (Play, Ride, Hub) are ignored. `--debug` logs every discovered advertisement.

Protocol details cross-checked with [BikeControl](https://github.com/jonasbark/swiftcontrol)'s Zwift Ride / Click v2 implementation.
