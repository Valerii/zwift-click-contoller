# Zwift Click - macOS BLE Listener

A macOS command-line tool that connects to a Zwift Click device over Bluetooth and logs button presses to the console.

- `+` button pressed → prints `UP`
- `-` button pressed → prints `DOWN`

## Requirements

- macOS 13 or later
- Xcode Command Line Tools

Install if needed:

```
xcode-select --install
```

## Build

```
swift build -c release
```

## Run

```
.build/release/ZwiftClick
```

On first launch macOS will prompt for Bluetooth access - click **OK**.

## Usage

1. Turn on your Zwift Click (hold the button until the LED pulses blue).
2. Run the app - it connects automatically.
3. Press `+` or `-` and watch the console.
4. The app auto-reconnects if the device goes to sleep or disconnects.
5. Press `Ctrl+C` to quit.

Example output:

```
Scanning for Zwift Click...
Found - connecting...
Encrypted handshake sent.
Key exchange complete. Press + or - on your Zwift Click.
UP
DOWN
UP
```

## How it works

The Zwift Click uses the Zwift Accessory Protocol (ZAP) over BLE. Current firmware requires a full encrypted handshake before button events are delivered:

1. Subscribe to the async (button events) and sync-tx (handshake response) characteristics
2. Generate an ephemeral ECDH P-256 key pair
3. Send `RideOn` + `\x01\x02` + 64-byte public key to the sync-rx characteristic
4. Device responds with its own 64-byte public key on sync-tx
5. Derive a 36-byte shared key via HKDF-SHA256 (salt = device pub wire + our pub wire, no info string)
6. Button events arrive encrypted with AES-CCM (32-byte key, 8-byte nonce = 4-byte IV prefix + 4-byte counter, 4-byte tag)
7. Decrypted payload: `[0x37, 0x08, plusState, 0x10, minusState]` where `0` = pressed
