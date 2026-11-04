import CoreBluetooth
import CoreGraphics
import Foundation

/// Connects to a Zwift Click v1 and/or both Zwift Click v2 pucks and turns their button events
/// into key presses. Whichever controllers are switched on get connected, in any combination.
public final class ClickV2Manager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private final class Device {
        let kind: DeviceKind
        let peripheral: CBPeripheral
        var syncRx: CBCharacteristic?
        var pendingNotify = 0
        var handshakeSent = false
        var ready = false
        var battery: Int?
        // Click v2
        var lastMap: UInt32 = .max // all bits set = nothing pressed
        // Click v1
        let keyExchange = ZapKeyExchange()
        var crypto: ZapCrypto?

        init(kind: DeviceKind, peripheral: CBPeripheral) {
            self.kind = kind
            self.peripheral = peripheral
        }

        var name: String { kind.displayName }
    }

    private struct TrackerKey: Hashable {
        let kind: DeviceKind
        let button: Button
    }

    private var central: CBCentralManager!
    private var devices: [DeviceKind: Device] = [:]
    /// One handler per device and button, so a Click v1 "+" and a Click v2 "+" never mix up presses.
    private var trackers: [TrackerKey: ButtonHandler] = [:]
    private var enabled: Bool
    /// Controllers enabled in the config. Anything else is ignored and never connected.
    private let kinds: Set<DeviceKind>

    private var scanStartTime: Date?
    private var scanWarningTimer: Timer?
    private let scanWarningInterval: TimeInterval = 60

    // Lock watchdog: the left puck normally relays every right-puck press. If it stops doing so
    // while still connected, it has most likely locked itself (needs an unlock from the Zwift app).
    private var lastRelayPress: [Button: Date] = [:]
    private var missedRelays = 0
    private var lockWarned = false
    private let relayWindow: TimeInterval = 0.5
    private let missedRelaysBeforeWarning = 3

    public init(config: ResolvedConfig, startEnabled: Bool,
                sendKey: @escaping (CGKeyCode) -> Void = KeyInjector.send,
                postKey: @escaping (CGKeyCode, KeyEvent) -> Void = KeyInjector.post) {
        self.enabled = startEnabled
        self.kinds = config.kinds
        super.init()

        for kind in DeviceKind.allCases where kinds.contains(kind) {
            for button in kind.buttons {
                let action = config.actions[button]
                let label = button.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)
                let tag = kind.logTag
                let key = TrackerKey(kind: kind, button: button)

                if let press = action?.press {
                    let holder = KeyHolder { postKey(press.code, $0) }
                    holder.onDown = { Log.info("\(tag) \(label) down -> \(press.name)") }
                    holder.onUp = { Log.info("\(tag) \(label) up   (\(String(format: "%.1f", $0))s)") }
                    trackers[key] = holder
                    continue
                }

                let tracker = ButtonTracker(threshold: config.holdThreshold, repeatInterval: config.holdRepeatInterval)
                if let tap = action?.tap {
                    tracker.onTap = { Log.info("\(tag) \(label) tap  -> \(tap.name)"); sendKey(tap.code) }
                } else {
                    tracker.onTap = { Log.debug("\(tag) \(button.rawValue) tap (unassigned)") }
                }
                if let hold = action?.hold {
                    tracker.onHold = { Log.info("\(tag) \(label) hold -> \(hold.name)"); sendKey(hold.code) }
                }
                trackers[key] = tracker
            }
        }

        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Enable / disable (driven by AppWatcher)

    public func enable() {
        guard !enabled else { return }
        enabled = true
        startScan()
    }

    public func disable() {
        guard enabled else { return }
        enabled = false
        if central.state == .poweredOn { central.stopScan() }
        stopScanWarning()
        for device in devices.values { central.cancelPeripheralConnection(device.peripheral) }
        dropAll()
        Log.info("BLE disabled - waiting for watched app to relaunch.")
    }

    // MARK: Shutdown

    private var shutdownCompletion: (() -> Void)?

    /// Stops scanning, abandons held buttons and disconnects every controller so it is free for other
    /// apps right away. Calls `completion` once all report disconnected, or after `timeout`.
    public func shutdown(timeout: TimeInterval = 2, completion: @escaping () -> Void) {
        enabled = false
        if central.state == .poweredOn { central.stopScan() }
        stopScanWarning()
        trackers.values.forEach { $0.release() }

        let connected = Array(devices.values)
        guard !connected.isEmpty else { completion(); return }
        shutdownCompletion = completion
        connected.forEach { central.cancelPeripheralConnection($0.peripheral) }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finishShutdown()
        }
    }

    private func finishShutdown() {
        guard let completion = shutdownCompletion else { return }
        shutdownCompletion = nil
        completion()
    }

    // MARK: Scanning

    private var missingKinds: [DeviceKind] { DeviceKind.allCases.filter { kinds.contains($0) && devices[$0] == nil } }

    private var missingPucks: [DeviceKind] { missingKinds.filter { $0 != .clickV1 } }

    /// Versions turned off in the config. Still scanned for, but only to log a hint - never connected.
    private var disabledKinds: [DeviceKind] { DeviceKind.allCases.filter { !kinds.contains($0) } }

    /// Keep scanning while an enabled controller is missing, or while a version is disabled
    /// (to tell you when it is switched on and gets ignored).
    private var shouldScan: Bool { !missingKinds.isEmpty || !disabledKinds.isEmpty }

    /// Disabled devices already reported, by peripheral, so restarted scans can't spam the log.
    private var ignoredReported: [UUID: Date] = [:]
    private let ignoredReportInterval: TimeInterval = 60

    private static func versions(_ kinds: [DeviceKind]) -> String {
        Set(kinds.map { "Click \($0.version)" }).sorted().joined(separator: " + ")
    }

    private func startScan() {
        guard enabled, central.state == .poweredOn, shouldScan else { return }
        // Restart rather than continue: a scan that already reported a device may not report it again.
        // Scanning keeps running while anything is missing, so you can switch controllers any time.
        central.stopScan()
        central.scanForPeripherals(withServices: [ZwiftUUID.service, ZwiftUUID.serviceV1])
        if missingKinds.isEmpty {
            Log.info("Watching for disabled controllers (\(Self.versions(disabledKinds)))...")
        } else {
            Log.info("Scanning for \(scanDescription)...")
        }

        scanStartTime = Date()
        scanWarningTimer?.invalidate()
        scanWarningTimer = Timer.scheduledTimer(withTimeInterval: scanWarningInterval, repeats: true) { [weak self] _ in
            guard let self, self.enabled, let missing = self.missingWarningTarget else { return }
            let elapsed = Int(Date().timeIntervalSince(self.scanStartTime ?? Date()))
            Log.info("""
                ⚠️  Still searching for \(missing) (\(elapsed)s elapsed). Possible reasons:
                   - It is off or asleep. Press any of its buttons to wake it up.
                   - It is connected to another device or app (Zwift, BikeControl, a phone,
                     or the old ZwiftClick v1 app). Disconnect it there first.
                   - The battery is flat (CR2032).
                   Still scanning...
                """)
        }
    }

    private var scanDescription: String {
        var parts: [String] = []
        if missingKinds.contains(.clickV1) { parts.append("Click v1") }
        let pucks = missingPucks
        if pucks.count == 2 { parts.append("Click v2 (left + right puck)") }
        if pucks.count == 1 { parts.append(pucks[0].displayName) }
        return "Zwift " + parts.joined(separator: " and ")
    }

    /// What the periodic warning complains about. Only nags when nothing is connected, or when one
    /// v2 puck is connected but its partner is not - never about a controller you may not own.
    private var missingWarningTarget: String? {
        if devices.isEmpty {
            if !kinds.contains(.clickV1) { return "the Zwift Click v2 pucks" }
            if missingPucks.isEmpty { return "the Zwift Click v1" } // v1 only
            return "a Zwift Click (v1, or the v2 pucks)"
        }
        let pucks = missingPucks
        return pucks.count == 1 ? "the \(pucks[0].displayName)" : nil
    }

    private func stopScanWarning() {
        scanWarningTimer?.invalidate()
        scanWarningTimer = nil
        scanStartTime = nil
    }

    // MARK: Central

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScan()
        case .poweredOff:
            Log.info("Bluetooth is off - waiting for it to be turned on.")
            stopScanWarning()
            dropAll()
        case .unauthorized:
            Log.info("Bluetooth permission denied. Allow it in System Settings > Privacy & Security > Bluetooth.")
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard enabled else { return }
        let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let kind = DeviceKind(manufacturerData: data, serviceUUIDs: services, name: name)
        let verdict = kind.map { kinds.contains($0) ? $0.rawValue : "ignored (Click \($0.version) is disabled)" } ?? "ignored"
        Log.debug("Discovered \(name ?? "?") mfr=[\(data.map { ZwiftProtocol.hex([UInt8]($0)) } ?? "-")] "
                  + "services=\(services.map(\.uuidString)) -> \(verdict)")

        if let kind, !kinds.contains(kind) {
            reportIgnored(kind, peripheral: peripheral)
            return
        }
        guard let kind, devices[kind] == nil,
              !devices.values.contains(where: { $0.peripheral.identifier == peripheral.identifier }) else { return }

        devices[kind] = Device(kind: kind, peripheral: peripheral)
        peripheral.delegate = self
        Log.info("Found \(kind.displayName) - connecting...")
        central.connect(peripheral)

        if missingKinds.isEmpty {
            stopScanWarning()
            if !shouldScan { central.stopScan() }
        }
    }

    /// Tells you a controller of a disabled version is switched on, at most once a minute per device.
    private func reportIgnored(_ kind: DeviceKind, peripheral: CBPeripheral) {
        let now = Date()
        if let last = ignoredReported[peripheral.identifier], now.timeIntervalSince(last) < ignoredReportInterval { return }
        ignoredReported[peripheral.identifier] = now
        let enabledVersions = Self.versions(DeviceKind.allCases.filter { kinds.contains($0) })
        Log.info("⚠️  \(kind.displayName) is switched on nearby but ignored - only \(enabledVersions) is enabled "
                 + "(\"controllers\" setting or --only). Add \"\(kind.version)\" to \"controllers\" in the config to use it.")
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let device = device(for: peripheral) else { return }
        peripheral.discoverServices([device.kind.service])
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        lost(peripheral, reason: "disconnected", error: error)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        lost(peripheral, reason: "failed to connect", error: error)
    }

    private func lost(_ peripheral: CBPeripheral, reason: String, error: Error?) {
        guard let device = device(for: peripheral) else { return } // already dropped (e.g. by disable())
        drop(device)
        if shutdownCompletion != nil {
            if devices.isEmpty { finishShutdown() }
            return
        }
        guard enabled else { return }
        let detail = error.map { " (\($0.localizedDescription))" } ?? ""
        Log.info("\(device.name) \(reason)\(detail). Reconnecting...")
        startScan()
    }

    private func device(for peripheral: CBPeripheral) -> Device? {
        devices.values.first { $0.peripheral.identifier == peripheral.identifier }
    }

    /// Forgets a device and abandons its in-flight presses so no key keeps repeating.
    private func drop(_ device: Device) {
        device.kind.buttons.forEach { trackers[TrackerKey(kind: device.kind, button: $0)]?.release() }
        devices[device.kind] = nil
        if device.kind == .clickV2Left { resetWatchdog() }
    }

    private func dropAll() {
        devices.values.forEach(drop)
    }

    private func disconnect(_ device: Device, because message: String) {
        Log.info("\(device.name): \(message)")
        central.cancelPeripheralConnection(device.peripheral)
    }

    // MARK: Peripheral

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let device = device(for: peripheral) else { return }
        let uuid = device.kind.service
        guard let service = peripheral.services?.first(where: { $0.uuid == uuid }) else {
            disconnect(device, because: "Zwift service \(uuid.uuidString) not found\(error.map { " (\($0.localizedDescription))" } ?? "").")
            return
        }
        peripheral.discoverCharacteristics([ZwiftUUID.async, ZwiftUUID.syncRx, ZwiftUUID.syncTx], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard let device = device(for: peripheral) else { return }
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case ZwiftUUID.async, ZwiftUUID.syncTx:
                device.pendingNotify += 1
                peripheral.setNotifyValue(true, for: char)
            case ZwiftUUID.syncRx:
                device.syncRx = char
            default:
                break
            }
        }
        if device.syncRx == nil || device.pendingNotify != 2 {
            disconnect(device, because: "expected Zwift characteristics not found.")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let device = device(for: peripheral),
              [ZwiftUUID.async, ZwiftUUID.syncTx].contains(characteristic.uuid) else { return }
        if let error {
            disconnect(device, because: "could not subscribe to notifications (\(error.localizedDescription)).")
            return
        }
        device.pendingNotify -= 1
        guard device.pendingNotify == 0, !device.handshakeSent, let syncRx = device.syncRx else { return }
        device.handshakeSent = true

        let handshake: [UInt8]
        let type: CBCharacteristicWriteType
        if device.kind == .clickV1 {
            // Encrypted key exchange. The v1 app wrote it with response; fall back if unsupported.
            handshake = device.keyExchange.request
            type = syncRx.properties.contains(.write) ? .withResponse : .withoutResponse
        } else {
            // sync-rx only supports write-without-response on Click v2.
            handshake = ZwiftProtocol.handshake
            type = .withoutResponse
        }
        peripheral.writeValue(Data(handshake), for: syncRx, type: type)
        Log.debug("\(device.kind.rawValue) handshake sent: \(ZwiftProtocol.hex(handshake))")
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let error, let device = device(for: peripheral) else { return }
        disconnect(device, because: "handshake write failed (\(error.localizedDescription)).")
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard error == nil, let device = device(for: peripheral),
              let data = characteristic.value, !data.isEmpty else { return }
        let bytes = [UInt8](data)
        Log.debug("\(device.kind.rawValue) \(characteristic.uuid.uuidString.prefix(8)): \(ZwiftProtocol.hex(bytes))")

        if device.kind == .clickV1 {
            handleV1(bytes, on: characteristic.uuid, from: device)
            return
        }

        switch ZwiftProtocol.parse(bytes) {
        case .handshakeEcho:
            markReady(device)
        case .buttons(let map):
            handleButtons(map, from: device)
        case .battery(let level):
            report(battery: level, of: device)
        case .pressed, .other, nil:
            break
        }
    }

    private func handleV1(_ bytes: [UInt8], on characteristic: CBUUID, from device: Device) {
        if characteristic == ZwiftUUID.syncTx, ZapKeyExchange.isResponse(bytes) {
            guard device.crypto == nil else { return }
            do {
                device.crypto = try device.keyExchange.crypto(fromResponse: bytes)
                markReady(device)
            } catch {
                disconnect(device, because: "key exchange failed (\(error)).")
            }
            return
        }
        guard characteristic == ZwiftUUID.async, let crypto = device.crypto else { return }
        guard let plaintext = try? crypto.decrypt(bytes) else {
            Log.debug("clickV1: could not decrypt \(ZwiftProtocol.hex(bytes))")
            return
        }
        Log.debug("clickV1 decrypted: \(ZwiftProtocol.hex(plaintext))")
        switch ZwiftProtocol.parseV1(plaintext: plaintext) {
        case .pressed(let pressed):
            update(device, pressed: pressed)
        case .battery(let level):
            report(battery: level, of: device)
        default:
            break
        }
    }

    private func markReady(_ device: Device) {
        guard !device.ready else { return }
        device.ready = true
        if device.kind == .clickV1 {
            Log.info("Click v1 ready. Listening for button events.")
            return
        }
        Log.info("\(device.name) ready.")
        if let left = devices[.clickV2Left], let right = devices[.clickV2Right], left.ready, right.ready {
            Log.info("Click v2: both pucks ready. Listening for button events.")
        }
    }

    private func report(battery level: Int, of device: Device) {
        guard device.battery != level else { return }
        device.battery = level
        Log.info("\(device.name) battery: \(level)%")
    }

    // MARK: Buttons

    private func update(_ device: Device, pressed: Set<Button>) {
        for button in device.kind.buttons {
            trackers[TrackerKey(kind: device.kind, button: button)]?.update(pressed: pressed.contains(button))
        }
    }

    private func handleButtons(_ map: UInt32, from device: Device) {
        guard let side = device.kind.side else { return }
        let previous = device.lastMap
        device.lastMap = map

        // Each puck only drives its own buttons, so the left puck's relayed copies never double-fire.
        let own = ZwiftProtocol.pressed(map: map, side: side)
        update(device, pressed: own)

        let now = Date()
        switch side {
        case .left:
            let relayed = ZwiftProtocol.pressed(map: map, side: .right)
                .subtracting(ZwiftProtocol.pressed(map: previous, side: .right))
            relayed.forEach { lastRelayPress[$0] = now }
        case .right:
            let newlyPressed = own.subtracting(ZwiftProtocol.pressed(map: previous, side: .right))
            newlyPressed.forEach { checkRelay(of: $0, pressedAt: now) }
        }
    }

    private func checkRelay(of button: Button, pressedAt time: Date) {
        guard devices[.clickV2Left]?.ready == true else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + relayWindow) { [weak self] in
            guard let self, self.devices[.clickV2Left]?.ready == true else { return }
            let relayed = self.lastRelayPress[button].map { abs($0.timeIntervalSince(time)) <= self.relayWindow } ?? false
            if relayed {
                self.missedRelays = 0
                if self.lockWarned {
                    self.lockWarned = false
                    Log.info("Click v2 left puck is sending events again.")
                }
            } else {
                self.missedRelays += 1
                if self.missedRelays >= self.missedRelaysBeforeWarning, !self.lockWarned {
                    self.lockWarned = true
                    Log.info("""
                        ⚠️  The Click v2 left puck seems to have stopped sending button events (it is connected but \
                        did not relay the last \(self.missedRelays) right-puck presses). The Click v2 may need \
                        an unlock: open the Zwift app, connect the Click v2 for ~30s, then quit Zwift. \
                        The right puck keeps working meanwhile.
                        """)
                }
            }
        }
    }

    private func resetWatchdog() {
        lastRelayPress.removeAll()
        missedRelays = 0
        lockWarned = false
    }
}
