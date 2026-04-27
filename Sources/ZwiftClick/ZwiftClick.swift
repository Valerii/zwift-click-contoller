import ApplicationServices
import CoreBluetooth
import CoreGraphics
import CryptoKit
import CryptoSwift
import Foundation

// MARK: - Constants

private let zapServiceUUID = CBUUID(string: "00000001-19ca-4651-86e5-fa29dcdd09d1")
private let zapAsyncUUID   = CBUUID(string: "00000002-19ca-4651-86e5-fa29dcdd09d1")
private let zapSyncRxUUID  = CBUUID(string: "00000003-19ca-4651-86e5-fa29dcdd09d1")
private let zapSyncTxUUID  = CBUUID(string: "00000004-19ca-4651-86e5-fa29dcdd09d1")
private let deviceName     = "Zwift Click"

// Tap: up/down arrow. Hold (>0.5s): page up/page down.
private let tapThreshold: TimeInterval = 0.5
private let tapUpKey:     CGKeyCode    = 126   // arrow up
private let tapDownKey:   CGKeyCode    = 125   // arrow down
private let holdUpKey:    CGKeyCode    = 116   // page up
private let holdDownKey:  CGKeyCode    = 121   // page down

// MARK: - Crypto

private struct ZapCrypto {
    let aesKey:   [UInt8]
    let ivPrefix: [UInt8]

    // HKDF-SHA256: salt = devPubWire(64) + ourPubWire(64), info = ""
    init(sharedSecret: [UInt8], devPubWire: [UInt8], ourPubWire: [UInt8]) throws {
        let derived = try HKDF(password: sharedSecret,
                               salt: devPubWire + ourPubWire,
                               info: [], keyLength: 36,
                               variant: .sha2(.sha256)).calculate()
        aesKey   = Array(derived[0..<32])
        ivPrefix = Array(derived[32..<36])
    }

    func decrypt(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count > 8 else { throw Err.tooShort }
        let counter  = Array(data[0..<4])
        let ctAndTag = Array(data[4...])
        let ct       = Array(ctAndTag.dropLast(4))
        let tag      = Array(ctAndTag.suffix(4))
        let nonce    = ivPrefix + counter
        return try AES(key: aesKey,
                       blockMode: CCM(iv: nonce, tagLength: 4, messageLength: ct.count),
                       padding: .noPadding).decrypt(ct + tag)
    }

    enum Err: Error { case tooShort }
}

// MARK: - Keyboard injection

private func sendKey(_ keyCode: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
}

private func checkAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    if !AXIsProcessTrustedWithOptions(options as CFDictionary) {
        print("Accessibility permission required for keyboard injection.")
        print("Grant access in System Settings > Privacy & Security > Accessibility, then relaunch.")
    }
}

// MARK: - Button state tracker (hold detection)

private final class ButtonTracker {
    enum Action { case tap, hold }

    private var pressTime: Date?
    private var wasPressed = false

    // Call on every decrypted payload. Returns an action on the rising or falling edge.
    func update(pressed: Bool) -> Action? {
        defer { wasPressed = pressed }

        if pressed && !wasPressed {
            // Rising edge - record press time
            pressTime = Date()
            return nil
        }

        if !pressed && wasPressed {
            // Falling edge - determine tap vs hold
            let duration = Date().timeIntervalSince(pressTime ?? Date())
            pressTime = nil
            return duration >= tapThreshold ? .hold : .tap
        }

        return nil
    }
}

// MARK: - Button event handler

private final class ButtonHandler {
    private let plusTracker  = ButtonTracker()
    private let minusTracker = ButtonTracker()

    func process(plaintext: [UInt8]) {
        // Format: [0x37, 0x08, plusState, 0x10, minusState]  0=pressed 1=released
        guard plaintext.count >= 5, plaintext[0] == 0x37 else { return }

        let plusPressed  = plaintext[2] == 0x00
        let minusPressed = plaintext[4] == 0x00

        if let action = plusTracker.update(pressed: plusPressed) {
            switch action {
            case .tap:
                print("UP (tap) -> arrow up")
                sendKey(tapUpKey)
            case .hold:
                print("UP (hold) -> page up")
                sendKey(holdUpKey)
            }
        }

        if let action = minusTracker.update(pressed: minusPressed) {
            switch action {
            case .tap:
                print("DOWN (tap) -> arrow down")
                sendKey(tapDownKey)
            case .hold:
                print("DOWN (hold) -> page down")
                sendKey(holdDownKey)
            }
        }
    }
}

// MARK: - BLE Manager

final class ZwiftClickManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var syncRxChar: CBCharacteristic?
    private var privateKey  = P256.KeyAgreement.PrivateKey()
    private var crypto: ZapCrypto?
    private var pendingCCCD = 0
    private var handshakeSent = false
    private let buttonHandler = ButtonHandler()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        print("Scanning for \(deviceName)...")
        central.scanForPeripherals(withServices: [zapServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.name == deviceName else { return }
        self.peripheral = peripheral
        central.stopScan()
        central.connect(peripheral)
        print("Found - connecting...")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([zapServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Disconnected. Reconnecting...")
        reset()
        central.scanForPeripherals(withServices: [zapServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        reset()
        central.scanForPeripherals(withServices: [zapServiceUUID])
    }

    private func reset() {
        syncRxChar = nil; crypto = nil
        pendingCCCD = 0; handshakeSent = false
        privateKey = P256.KeyAgreement.PrivateKey()
    }

    // MARK: Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == zapServiceUUID }) else { return }
        peripheral.discoverCharacteristics([zapAsyncUUID, zapSyncRxUUID, zapSyncTxUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars {
            switch char.uuid {
            case zapAsyncUUID, zapSyncTxUUID:
                pendingCCCD += 1
                peripheral.setNotifyValue(true, for: char)
            case zapSyncRxUUID:
                syncRxChar = char
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard [zapAsyncUUID, zapSyncTxUUID].contains(characteristic.uuid) else { return }
        pendingCCCD -= 1
        if pendingCCCD <= 0 && !handshakeSent { sendHandshake(peripheral) }
    }

    private func sendHandshake(_ peripheral: CBPeripheral) {
        guard let syncRx = syncRxChar else { return }
        handshakeSent = true
        let pubWire = Array(privateKey.publicKey.x963Representation[1...])
        let payload = Array("RideOn".utf8) + [0x01, 0x02] + pubWire
        peripheral.writeValue(Data(payload), for: syncRx, type: .withResponse)
        print("Encrypted handshake sent.")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error { print("Write error: \(e.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let bytes = [UInt8](data)

        switch characteristic.uuid {
        case zapSyncTxUUID:
            handleHandshakeResponse(bytes)
        case zapAsyncUUID:
            guard let crypto else { return }
            if let plain = try? crypto.decrypt(bytes) {
                buttonHandler.process(plaintext: plain)
            }
        default: break
        }
    }

    private func handleHandshakeResponse(_ bytes: [UInt8]) {
        let header = Array("RideOn\u{01}\u{03}".utf8)
        guard bytes.count == 72, Array(bytes[0..<8]) == header else { return }
        let devPubWire = Array(bytes[8...])
        do {
            let devPubKey    = try P256.KeyAgreement.PublicKey(x963Representation: Data([0x04] + devPubWire))
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: devPubKey)
            let ssBytes      = sharedSecret.withUnsafeBytes { Array($0) }
            let ourPubWire   = Array(privateKey.publicKey.x963Representation[1...])
            crypto = try ZapCrypto(sharedSecret: ssBytes, devPubWire: devPubWire, ourPubWire: ourPubWire)
            print("Key exchange complete. Press + or - on your Zwift Click.")
            print("  tap  -> arrow up / arrow down")
            print("  hold -> page up  / page down")
        } catch {
            print("Key exchange failed: \(error)")
        }
    }
}

// MARK: - Entry point

@main
struct ZwiftClick {
    static func main() {
        checkAccessibility()
        let manager = ZwiftClickManager()
        _ = manager
        RunLoop.main.run()
    }
}
