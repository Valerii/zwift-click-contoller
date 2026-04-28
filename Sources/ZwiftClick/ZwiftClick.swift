import ApplicationServices
import CoreBluetooth
import CoreGraphics
import CryptoKit
import CryptoSwift
import Foundation
import AppKit

// MARK: - Key name map

private let keyNames: [String: CGKeyCode] = [
    "up":       126,
    "down":     125,
    "left":     123,
    "right":    124,
    "pageup":   116,
    "pagedown": 121,
    "space":    49,
    "return":   36,
    "tab":      48,
    "escape":   53,
    "f1":  122, "f2":  120, "f3":  99,  "f4":  118,
    "f5":  96,  "f6":  97,  "f7":  98,  "f8":  100,
    "f9":  101, "f10": 109, "f11": 103, "f12": 111,
    // letter keys (US ANSI scan codes)
    "a": 0,  "b": 11, "c": 8,  "d": 2,  "e": 14, "f": 3,
    "g": 5,  "h": 4,  "i": 34, "j": 38, "k": 40, "l": 37,
    "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15,
    "s": 1,  "t": 17, "u": 32, "v": 9,  "w": 13, "x": 7,
    "y": 16, "z": 6,
]

private func keyCode(for name: String) -> CGKeyCode? {
    keyNames[name.lowercased()]
}

// MARK: - JSON Config

struct Config: Codable {
    var tapPlus:       String  = "up"
    var tapMinus:      String  = "down"
    var holdPlus:      String  = "pageup"
    var holdMinus:     String  = "pagedown"
    var holdThreshold:       Double = 0.3
    var holdRepeatInterval:  Double = 0.2
    /// App name or bundle ID to watch. BLE connects when it launches, disconnects when it quits.
    /// Set to null to stay connected regardless of running apps.
    var watchApp:      String? = nil

    var tapPlusKey:   CGKeyCode    { keyCode(for: tapPlus)   ?? 126 }
    var tapMinusKey:  CGKeyCode    { keyCode(for: tapMinus)  ?? 125 }
    var holdPlusKey:  CGKeyCode    { keyCode(for: holdPlus)  ?? 116 }
    var holdMinusKey: CGKeyCode    { keyCode(for: holdMinus) ?? 121 }
    var threshold:      TimeInterval { holdThreshold }
    var repeatInterval: TimeInterval { holdRepeatInterval }

    static let defaultPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".config/zwift-click/config.json")

    static func load() -> Config {
        let path = configPath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            print("No config at \(path) - using defaults. Run --write-config to create one.")
            return Config()
        }
        do {
            let cfg = try JSONDecoder().decode(Config.self, from: data)
            print("Loaded config from \(path)")
            return cfg
        } catch {
            print("Config parse error: \(error). Using defaults.")
            return Config()
        }
    }

    func write() throws {
        let path = Config.configPath()
        let dir  = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: path))
        print("Default config written to \(path)")
    }

    private static func configPath() -> String {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--config"), args.index(after: idx) < args.endIndex {
            return args[args.index(after: idx)]
        }
        return defaultPath
    }
}

// MARK: - ZAP UUIDs

private let zapServiceUUID = CBUUID(string: "00000001-19ca-4651-86e5-fa29dcdd09d1")
private let zapAsyncUUID   = CBUUID(string: "00000002-19ca-4651-86e5-fa29dcdd09d1")
private let zapSyncRxUUID  = CBUUID(string: "00000003-19ca-4651-86e5-fa29dcdd09d1")
private let zapSyncTxUUID  = CBUUID(string: "00000004-19ca-4651-86e5-fa29dcdd09d1")
private let deviceName     = "Zwift Click"

// MARK: - Crypto

private struct ZapCrypto {
    let aesKey:   [UInt8]
    let ivPrefix: [UInt8]

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
        return try AES(key: aesKey,
                       blockMode: CCM(iv: ivPrefix + counter, tagLength: 4, messageLength: ct.count),
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

// MARK: - Hold detection

private final class ButtonTracker {
    var onTap:  (() -> Void)?
    var onHold: (() -> Void)?  // called on first trigger and every 100ms repeat while held

    private var pressTime: Date?
    private var wasPressed     = false
    private let threshold:      TimeInterval
    private let repeatInterval: TimeInterval
    private var holdTimer:      Timer?
    private var repeatTimer:    Timer?

    init(threshold: TimeInterval, repeatInterval: TimeInterval) {
        self.threshold      = threshold
        self.repeatInterval = repeatInterval
    }

    func update(pressed: Bool) {
        defer { wasPressed = pressed }

        if pressed && !wasPressed {
            // Rising edge: arm the hold timer
            pressTime = Date()
            holdTimer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.onHold?()
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: self.repeatInterval,
                                                        repeats: true) { [weak self] _ in
                    self?.onHold?()
                }
            }
        }

        if !pressed && wasPressed {
            // Falling edge: cancel timers, fire tap if threshold wasn't reached
            let duration = Date().timeIntervalSince(pressTime ?? Date())
            pressTime = nil
            holdTimer?.invalidate();  holdTimer  = nil
            repeatTimer?.invalidate(); repeatTimer = nil
            if duration < threshold { onTap?() }
        }
    }
}

// MARK: - Button handler

private final class ButtonHandler {
    private let plusTracker:  ButtonTracker
    private let minusTracker: ButtonTracker

    init(config: Config) {
        plusTracker  = ButtonTracker(threshold: config.threshold, repeatInterval: config.repeatInterval)
        minusTracker = ButtonTracker(threshold: config.threshold, repeatInterval: config.repeatInterval)

        plusTracker.onTap  = { print("+ tap  -> \(config.tapPlus)");  sendKey(config.tapPlusKey) }
        plusTracker.onHold = { print("+ hold -> \(config.holdPlus)"); sendKey(config.holdPlusKey) }

        minusTracker.onTap  = { print("- tap  -> \(config.tapMinus)");  sendKey(config.tapMinusKey) }
        minusTracker.onHold = { print("- hold -> \(config.holdMinus)"); sendKey(config.holdMinusKey) }
    }

    func process(plaintext: [UInt8]) {
        guard plaintext.count >= 5, plaintext[0] == 0x37 else { return }
        plusTracker.update(pressed:  plaintext[2] == 0x00)
        minusTracker.update(pressed: plaintext[4] == 0x00)
    }
}

// MARK: - App Watcher

/// Watches for a target app (by name or bundle ID) launching and quitting.
/// Calls `onLaunch` / `onQuit` on the main thread.
final class AppWatcher {
    private let target: String   // lowercased app name or bundle ID
    private var observers: [NSObjectProtocol] = []
    var onLaunch: (() -> Void)?
    var onQuit:   (() -> Void)?

    init(appNameOrBundleID: String) {
        self.target = appNameOrBundleID.lowercased()
    }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            self?.handle(note, event: .launch)
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            self?.handle(note, event: .quit)
        })

        // Fire immediately if the app is already running
        if isTargetRunning() {
            print("[\(target)] already running - connecting.")
            onLaunch?()
        } else {
            print("Waiting for \(target) to launch...")
        }
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    private enum Event { case launch, quit }

    private func handle(_ note: Notification, event: Event) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              matches(app) else { return }
        switch event {
        case .launch:
            print("[\(app.localizedName ?? target)] launched - connecting Zwift Click.")
            onLaunch?()
        case .quit:
            print("[\(app.localizedName ?? target)] quit - disconnecting Zwift Click.")
            onQuit?()
        }
    }

    private func matches(_ app: NSRunningApplication) -> Bool {
        (app.localizedName?.lowercased() == target) ||
        (app.bundleIdentifier?.lowercased() == target)
    }

    private func isTargetRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { matches($0) }
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
    private let buttonHandler: ButtonHandler

    // When true the manager is allowed to scan/connect; when false it stays idle.
    private var enabled = true

    private var scanStartTime: Date?
    private var scanWarningTimer: Timer?
    private let scanWarningInterval: TimeInterval = 60

    init(config: Config) {
        self.buttonHandler = ButtonHandler(config: config)
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // Called by AppWatcher when the watched app launches
    func enable() {
        guard !enabled else { return }
        enabled = true
        if central.state == .poweredOn { startScan() }
    }

    // Called by AppWatcher when the watched app quits
    func disable() {
        guard enabled else { return }
        enabled = false
        central.stopScan()
        stopScanWarning()
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        reset()
        print("BLE disabled - waiting for watched app to relaunch.")
    }

    // MARK: Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn, enabled else { return }
        startScan()
    }

    private func startScan() {
        print("Scanning for \(deviceName)...")
        scanStartTime = Date()
        central.scanForPeripherals(withServices: [zapServiceUUID])
        scanWarningTimer?.invalidate()
        scanWarningTimer = Timer.scheduledTimer(withTimeInterval: scanWarningInterval, repeats: true) { [weak self] _ in
            guard let self, self.enabled else { return }
            let elapsed = Int(Date().timeIntervalSince(self.scanStartTime ?? Date()))
            print("")
            print("⚠️  Still searching for \(deviceName) (\(elapsed)s elapsed).")
            print("   Possible reasons:")
            print("   - The Zwift Click is off or out of range. Press a button to wake it up.")
            print("   - The Zwift Click is already connected to another device (phone, tablet, or another instance of this app).")
            print("     Disconnect it from the other device, or quit any other ZwiftClick instance.")
            print("   - Bluetooth is blocked by system policy or another process.")
            print("   Still scanning...")
            print("")
        }
    }

    private func stopScanWarning() {
        scanWarningTimer?.invalidate()
        scanWarningTimer = nil
        scanStartTime = nil
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.name == deviceName else { return }
        self.peripheral = peripheral
        central.stopScan()
        stopScanWarning()
        central.connect(peripheral)
        print("Found - connecting...")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([zapServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        reset()
        guard enabled else { return }
        print("Disconnected. Reconnecting...")
        startScan()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        reset()
        guard enabled else { return }
        startScan()
    }

    private func reset() {
        stopScanWarning()
        syncRxChar = nil; crypto = nil
        pendingCCCD = 0; handshakeSent = false
        peripheral = nil
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
        peripheral.writeValue(Data(Array("RideOn".utf8) + [0x01, 0x02] + pubWire), for: syncRx, type: .withResponse)
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
            if let plain = try? crypto.decrypt(bytes) { buttonHandler.process(plaintext: plain) }
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
            crypto = try ZapCrypto(sharedSecret: ssBytes,
                                   devPubWire: devPubWire,
                                   ourPubWire: Array(privateKey.publicKey.x963Representation[1...]))
            print("Ready. Listening for button events.")
        } catch {
            print("Key exchange failed: \(error)")
        }
    }
}

// MARK: - Entry point

@main
struct ZwiftClick {
    static func main() {
        if CommandLine.arguments.contains("--write-config") {
            try? Config().write()
            return
        }

        let config = Config.load()
        checkAccessibility()

        let manager = ZwiftClickManager(config: config)

        if let appTarget = config.watchApp {
            // Start disabled - AppWatcher will enable/disable based on the watched app
            manager.disable()
            let watcher = AppWatcher(appNameOrBundleID: appTarget)
            watcher.onLaunch = { manager.enable() }
            watcher.onQuit   = { manager.disable() }
            watcher.start()
            // Keep watcher alive
            withExtendedLifetime(watcher) { RunLoop.main.run() }
        } else {
            RunLoop.main.run()
        }
    }
}
