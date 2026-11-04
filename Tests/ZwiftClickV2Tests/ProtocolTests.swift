import CoreBluetooth
import CryptoKit
import CryptoSwift
import Foundation
import Testing
@testable import ZwiftClickV2Core

private func bytes(_ hex: String) -> [UInt8] {
    hex.split(separator: " ").map { UInt8($0, radix: 16)! }
}

private func pressed(_ hex: String, _ side: Side) -> Set<Button> {
    guard case .buttons(let map) = ZwiftProtocol.parse(bytes(hex)) else {
        Issue.record("not a button message: \(hex)")
        return []
    }
    return ZwiftProtocol.pressed(map: map, side: side)
}

// Packets below were captured from real Click v2 pucks (firmware 1.0.2).
@Suite struct ParserTests {
    @Test(arguments: [
        ("23 08 fd ff ff ff 0f", Button.up),
        ("23 08 f7 ff ff ff 0f", Button.down),
        ("23 08 fe ff ff ff 0f", Button.left),
        ("23 08 fb ff ff ff 0f", Button.right),
        ("23 08 ff fd ff ff 0f", Button.minus),
        ("23 08 bf ff ff ff 0f", Button.y),
        ("23 08 ff fe ff ff 0f", Button.z),
        ("23 08 df ff ff ff 0f", Button.b),
        ("23 08 ef ff ff ff 0f", Button.a),
        ("23 08 ff df ff ff 0f", Button.plus),
    ])
    func singleButton(packet: String, button: Button) {
        #expect(pressed(packet, button.side) == [button])
    }

    @Test func releasedMeansNothingPressed() {
        #expect(pressed("23 08 ff ff ff ff 0f", .left).isEmpty)
        #expect(pressed("23 08 ff ff ff ff 0f", .right).isEmpty)
    }

    @Test func comboIsSplitPerSide() {
        // Left puck report while Up (left) and Y (right, relayed) are both held.
        #expect(pressed("23 08 bd ff ff ff 0f", .left) == [.up])
        #expect(pressed("23 08 bd ff ff ff 0f", .right) == [.y])
        // Minus + Plus together.
        #expect(pressed("23 08 ff dd ff ff 0f", .left) == [.minus])
        #expect(pressed("23 08 ff dd ff ff 0f", .right) == [.plus])
    }

    @Test func relayedRightPressIsIgnoredForLeftSide() {
        #expect(pressed("23 08 ff df ff ff 0f", .left).isEmpty) // Plus relayed by the left puck
    }

    @Test func battery() {
        #expect(ZwiftProtocol.parse(bytes("19 10 64")) == .battery(100))
    }

    @Test func handshakeEcho() {
        #expect(ZwiftProtocol.parse(bytes("52 69 64 65 4f 6e 02 03")) == .handshakeEcho)
        #expect(ZwiftProtocol.parse(ZwiftProtocol.handshake) == .handshakeEcho)
    }

    @Test func otherMessages() {
        let log = "2a 08 02 12 15 22 13 42 61 74 74 2e 20 56 6f 6c 74 2e 20 32 39 35 37 20 6d 56"
        #expect(ZwiftProtocol.parse(bytes(log)) == .other(0x2a))
        #expect(ZwiftProtocol.parse(bytes("ff 03 00 0a 21")) == .other(0xff))
    }

    @Test(arguments: ["", "23", "23 08", "23 08 ff ff", "23 10 05", "23 0a 05 01", "19"])
    func malformedIsRejected(packet: String) {
        // Never report "every button pressed" for a broken packet.
        #expect(ZwiftProtocol.parse(packet.isEmpty ? [] : bytes(packet)) == nil)
    }
}

@Suite struct SideTests {
    @Test func fromManufacturerData() {
        #expect(Side(manufacturerData: Data(bytes("4a 09 0b f7 cb"))) == .left)
        #expect(Side(manufacturerData: Data(bytes("4a 09 0a 1a 61"))) == .right)
        #expect(Side(manufacturerData: Data(bytes("4a 09 09 00"))) == nil) // Click v1
        #expect(Side(manufacturerData: Data(bytes("4a 09 07"))) == nil)    // Zwift Ride
        #expect(Side(manufacturerData: Data(bytes("4c 00 0b"))) == nil)    // not Zwift
        #expect(Side(manufacturerData: Data(bytes("4a 09"))) == nil)
    }

    @Test func eachSideHasFiveButtons() {
        #expect(Set(Side.left.buttons) == [.up, .down, .left, .right, .minus])
        #expect(Set(Side.right.buttons) == [.y, .z, .b, .a, .plus])
    }
}

@Suite struct DeviceKindTests {
    private func kind(_ mfr: String?, services: [CBUUID] = [], name: String? = "Zwift Click") -> DeviceKind? {
        DeviceKind(manufacturerData: mfr.map { Data(bytes($0)) }, serviceUUIDs: services, name: name)
    }

    @Test func fromManufacturerData() {
        #expect(kind("4a 09 09 00") == .clickV1)
        #expect(kind("4a 09 0b f7 cb") == .clickV2Left)
        #expect(kind("4a 09 0a 1a 61") == .clickV2Right)
    }

    @Test func otherZwiftDevicesAreIgnored() {
        // Zwift manufacturer data decides, even if the v1 service is advertised too.
        #expect(kind("4a 09 07", services: [ZwiftUUID.serviceV1]) == nil) // Zwift Ride
        #expect(kind("4a 09 02", services: [ZwiftUUID.serviceV1]) == nil) // Zwift Play
    }

    @Test func v1FallbackWithoutManufacturerData() {
        // How the v1 app found the Click v1: its service plus the "Zwift Click" name.
        #expect(kind(nil, services: [ZwiftUUID.serviceV1]) == .clickV1)
        #expect(kind("4c 00 10 05", services: [ZwiftUUID.serviceV1]) == .clickV1) // non-Zwift data
        #expect(kind(nil, services: [ZwiftUUID.serviceV1], name: "Zwift Hub") == nil)
        #expect(kind(nil, services: [ZwiftUUID.service]) == nil)
    }

    @Test func buttonsPerKind() {
        #expect(DeviceKind.clickV1.buttons == [.plus, .minus])
        #expect(Set(DeviceKind.clickV2Left.buttons) == Set(Side.left.buttons))
        #expect(Set(DeviceKind.clickV2Right.buttons) == Set(Side.right.buttons))
        #expect(DeviceKind.clickV1.service == ZwiftUUID.serviceV1)
        #expect(DeviceKind.clickV2Left.service == ZwiftUUID.service)
    }

    @Test func logNamesSayWhichVersion() {
        for kind in DeviceKind.allCases {
            #expect(kind.displayName.contains(kind == .clickV1 ? "v1" : "v2"))
            #expect(kind.logTag.contains(kind == .clickV1 ? "v1" : "v2"))
        }
    }
}

// Decrypted Click v1 messages, same layout the v1 app reads (plaintext[2] = plus, [4] = minus).
@Suite struct ParserV1Tests {
    @Test func buttons() {
        #expect(ZwiftProtocol.parseV1(plaintext: bytes("37 08 00 10 01")) == .pressed([.plus]))
        #expect(ZwiftProtocol.parseV1(plaintext: bytes("37 08 01 10 00")) == .pressed([.minus]))
        #expect(ZwiftProtocol.parseV1(plaintext: bytes("37 08 00 10 00")) == .pressed([.plus, .minus]))
        #expect(ZwiftProtocol.parseV1(plaintext: bytes("37 08 01 10 01")) == .pressed([]))
    }

    @Test func batteryAndOther() {
        #expect(ZwiftProtocol.parseV1(plaintext: bytes("19 10 50")) == .battery(80))
        #expect(ZwiftProtocol.parseV1(plaintext: bytes("15 08 01")) == .other(0x15))
    }

    @Test(arguments: ["", "37", "37 08 00", "37 10 00", "37 08 80"])
    func malformedIsRejected(packet: String) {
        // A missing field must never read as "pressed".
        #expect(ZwiftProtocol.parseV1(plaintext: packet.isEmpty ? [] : bytes(packet)) == nil)
    }
}

@Suite struct ZapCryptoTests {
    /// Plays the Click v1's side of the key exchange and encrypts like the device does.
    private struct FakeClick {
        let key = P256.KeyAgreement.PrivateKey()
        var publicWire: [UInt8] { Array(key.publicKey.x963Representation.dropFirst()) }
        var response: [UInt8] { Array("RideOn".utf8) + [0x01, 0x03] + publicWire }

        func encrypt(_ plaintext: [UInt8], counter: [UInt8], hostRequest: [UInt8]) throws -> [UInt8] {
            let hostWire = Array(hostRequest.dropFirst(8))
            let hostKey = try P256.KeyAgreement.PublicKey(x963Representation: Data([0x04] + hostWire))
            let secret = try key.sharedSecretFromKeyAgreement(with: hostKey).withUnsafeBytes { Array($0) }
            let derived = try HKDF(password: secret, salt: publicWire + hostWire, info: [], keyLength: 36,
                                   variant: .sha2(.sha256)).calculate()
            let aes = try AES(key: Array(derived[0..<32]),
                              blockMode: CCM(iv: Array(derived[32..<36]) + counter, tagLength: 4,
                                             messageLength: plaintext.count),
                              padding: .noPadding)
            return counter + (try aes.encrypt(plaintext))
        }
    }

    @Test func requestFormat() {
        let request = ZapKeyExchange().request
        #expect(request.count == 72)
        #expect(Array(request.prefix(8)) == Array("RideOn".utf8) + [0x01, 0x02])
    }

    @Test func handshakeThenDecrypt() throws {
        let host = ZapKeyExchange()
        let click = FakeClick()
        let crypto = try host.crypto(fromResponse: click.response)
        for (i, plaintext) in [bytes("37 08 00 10 01"), bytes("37 08 01 10 01")].enumerated() {
            let packet = try click.encrypt(plaintext, counter: [0, 0, 0, UInt8(i + 1)], hostRequest: host.request)
            #expect(try crypto.decrypt(packet) == plaintext)
        }
    }

    @Test func tamperedPacketIsRejected() throws {
        let host = ZapKeyExchange()
        let click = FakeClick()
        let crypto = try host.crypto(fromResponse: click.response)
        var packet = try click.encrypt(bytes("37 08 00 10 01"), counter: [0, 0, 0, 1], hostRequest: host.request)
        packet[5] ^= 0xFF
        #expect(throws: (any Error).self) { try crypto.decrypt(packet) }
        #expect(throws: (any Error).self) { try crypto.decrypt([1, 2, 3]) }
    }

    @Test func badHandshakeIsRejected() {
        let host = ZapKeyExchange()
        #expect(!ZapKeyExchange.isResponse(ZwiftProtocol.handshake)) // a v2 echo is not a v1 response
        #expect(throws: (any Error).self) { try host.crypto(fromResponse: Array("RideOn".utf8) + [1, 3] + [UInt8](repeating: 0, count: 64)) }
    }
}

@Suite struct ConfigTests {
    @Test func defaultsResolveWithoutErrors() {
        let resolved = Config().resolve()
        #expect(resolved.errors.isEmpty)
        #expect(resolved.actions.count == Button.allCases.count)
        #expect(resolved.actions[.plus]?.tap?.name == "k")
    }

    @Test func holdDefaultsToTap() {
        let config = Config(buttons: ["a": ButtonAction(tap: "space")])
        #expect(config.resolve().actions[.a]?.hold?.name == "space")
    }

    @Test func unknownNamesAreReported() {
        let config = Config(buttons: ["plus": ButtonAction(tap: "kk"), "turbo": ButtonAction(tap: "k")])
        let errors = config.resolve().errors
        #expect(errors.contains { $0.contains("buttons.plus.tap") })
        #expect(errors.contains { $0.contains("buttons.turbo") })
    }

    @Test func missingButtonDoesNothing() {
        let config = Config(buttons: ["plus": ButtonAction(tap: "k")])
        #expect(config.resolve().actions[.minus] == nil)
    }

    @Test func partialFileUsesDefaults() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"watchApp":"MyWhoosh"}"#.utf8))
        #expect(config.watchApp == "MyWhoosh")
        #expect(config.buttons == Config.defaultButtons)
        #expect(config.holdThreshold == 0.3)
    }

    @Test func roundTripWritesNullWatchApp() throws {
        let json = String(decoding: try JSONEncoder().encode(Config()), as: UTF8.self)
        #expect(json.contains(#""watchApp":null"#))
        #expect(try JSONDecoder().decode(Config.self, from: Data(json.utf8)) == Config())
    }
}

@Suite struct ControllersSettingTests {
    private let all = Set(DeviceKind.allCases)

    @Test func defaultIsBothVersions() {
        #expect(Config().controllers == ["v1", "v2"])
        #expect(Config().resolve().kinds == all)
    }

    @Test func onlyOneVersion() {
        #expect(Config(controllers: ["v1"]).resolve().kinds == [.clickV1])
        #expect(Config(controllers: ["V2"]).resolve().kinds == [.clickV2Left, .clickV2Right])
        #expect(Config(controllers: ["v1"]).resolve().errors.isEmpty)
    }

    @Test func unknownEntryIsReportedAndSkipped() {
        let resolved = Config(controllers: ["v2", "v3"]).resolve()
        #expect(resolved.kinds == [.clickV2Left, .clickV2Right])
        #expect(resolved.errors.contains { $0.contains("\"v3\"") })
    }

    @Test(arguments: [[String](), ["v3"]])
    func nothingValidFallsBackToBoth(controllers: [String]) {
        let resolved = Config(controllers: controllers).resolve()
        #expect(resolved.kinds == all)
        #expect(resolved.errors.contains { $0.contains("using v1 and v2") })
    }

    @Test func fileWithoutFieldUsesBoth() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"watchApp":null}"#.utf8))
        #expect(config.controllers == ["v1", "v2"])
        let fromFile = try JSONDecoder().decode(Config.self, from: Data(#"{"controllers":["v1"]}"#.utf8))
        #expect(fromFile.controllers == ["v1"])
    }

    @Test func writtenConfigShowsTheOption() throws {
        let json = String(decoding: try JSONEncoder().encode(Config()), as: UTF8.self)
        #expect(json.contains(#""controllers":["v1","v2"]"#))
    }

    @Test func summaryForStartupLog() {
        #expect(DeviceKind.summary(of: [.clickV1]) == "Click v1 only")
        #expect(DeviceKind.summary(of: [.clickV2Left, .clickV2Right]) == "Click v2 only")
        #expect(DeviceKind.summary(of: all) == "Click v1 + Click v2")
    }
}

@Suite struct ButtonTrackerTests {
    @Test func quickPressFiresTapOnce() {
        let tracker = ButtonTracker(threshold: 10, repeatInterval: 1)
        var taps = 0
        tracker.onTap = { taps += 1 }
        tracker.update(pressed: true)
        tracker.update(pressed: true) // duplicate report
        tracker.update(pressed: false)
        tracker.update(pressed: false)
        #expect(taps == 1)
    }

    @Test func releaseAbandonsPressSilently() {
        let tracker = ButtonTracker(threshold: 10, repeatInterval: 1)
        var fired = 0
        tracker.onTap = { fired += 1 }
        tracker.onHold = { fired += 1 }
        tracker.update(pressed: true)
        tracker.release()
        tracker.update(pressed: false)
        #expect(fired == 0)
        #expect(!tracker.isPressed)
    }
}

@Suite struct KeyHolderTests {
    private final class Recorder {
        var events: [KeyEvent] = []
    }

    private func holder(_ recorder: Recorder, delay: TimeInterval = 10, interval: TimeInterval = 10) -> KeyHolder {
        KeyHolder(repeatDelay: delay, repeatInterval: interval) { recorder.events.append($0) }
    }

    @Test func pressAndReleaseLikeAKeyboardKey() {
        let recorder = Recorder()
        let key = holder(recorder)
        key.update(pressed: true)
        key.update(pressed: true) // duplicate report
        #expect(recorder.events == [.down(isRepeat: false)])
        key.update(pressed: false)
        key.update(pressed: false)
        #expect(recorder.events == [.down(isRepeat: false), .up])
    }

    @Test func releaseLiftsAHeldKey() {
        let recorder = Recorder()
        let key = holder(recorder)
        key.release() // not held: nothing to lift
        #expect(recorder.events.isEmpty)
        key.update(pressed: true)
        key.release() // e.g. the puck disconnected mid-press
        #expect(recorder.events == [.down(isRepeat: false), .up])
        #expect(!key.isPressed)
    }

    @MainActor @Test func autoRepeatsWhileHeldAndStopsOnRelease() {
        let recorder = Recorder()
        let key = holder(recorder, delay: 0.05, interval: 0.03)
        key.update(pressed: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        key.update(pressed: false)
        let count = recorder.events.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        #expect(recorder.events.first == .down(isRepeat: false))
        #expect(recorder.events.last == .up)
        let repeats = recorder.events.dropFirst().dropLast()
        #expect(repeats.count >= 2)
        #expect(repeats.allSatisfy { $0 == .down(isRepeat: true) })
        #expect(recorder.events.count == count) // nothing after the key went up
    }
}

@Suite struct PressModeConfigTests {
    @Test func arrowsDefaultToPress() {
        let actions = Config().resolve().actions
        for button in [Button.up, .down, .left, .right] {
            #expect(actions[button]?.press?.name == button.rawValue)
            #expect(actions[button]?.tap == nil)
        }
        #expect(actions[.plus]?.press == nil)
        #expect(actions[.plus]?.hold?.name == "k")
    }

    @Test func pressWinsOverTapAndIsReported() {
        let resolved = Config(buttons: ["left": ButtonAction(tap: "a", press: "left")]).resolve()
        #expect(resolved.actions[.left]?.press?.name == "left")
        #expect(resolved.actions[.left]?.tap == nil)
        #expect(resolved.errors.contains { $0.contains("buttons.left") && $0.contains("press") })
    }

    @Test func unknownPressKeyIsReported() {
        let errors = Config(buttons: ["left": ButtonAction(press: "lft")]).resolve().errors
        #expect(errors.contains { $0.contains("buttons.left.press") })
    }

    @Test func oldTapConfigStillWorks() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"buttons":{"left":{"tap":"left"}}}"#.utf8))
        let left = config.resolve().actions[.left]
        #expect(left?.tap?.name == "left")
        #expect(left?.hold?.name == "left")
        #expect(left?.press == nil)
    }

    @Test func pressIsWrittenOnlyWhereUsed() throws {
        let json = String(decoding: try JSONEncoder().encode(Config()), as: UTF8.self)
        #expect(json.contains(#""left":{"press":"left"}"#))
        #expect(!json.contains(#""tap":null"#))
        #expect(try JSONDecoder().decode(Config.self, from: Data(json.utf8)) == Config())
    }
}

@Suite(.serialized) struct InstanceLockTests {
    private func tempLockPath() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("zc2-lock-\(UUID().uuidString).lock")
    }

    @Test func secondCopyIsRefusedWhileLocked() throws {
        let path = tempLockPath()
        let first = try InstanceLock(path: path)
        #expect(throws: InstanceLock.LockError.alreadyRunning(pid: getpid())) { try InstanceLock(path: path) }
        withExtendedLifetime(first) {}
    }

    @Test func lockIsFreeAfterHolderGoesAway() throws {
        let path = tempLockPath()
        do { _ = try InstanceLock(path: path) } // released at end of scope
        _ = try InstanceLock(path: path)
    }

    @Test func takeOverNeverSignalsItself() throws {
        let path = tempLockPath()
        let held = try InstanceLock(path: path)
        #expect(throws: InstanceLock.LockError.alreadyRunning(pid: getpid())) {
            try InstanceLock.takeOver(path: path, timeout: 0.2)
        }
        withExtendedLifetime(held) {}
    }

    @Test func takeOverNeverKillsUnrelatedProcess() throws {
        let path = tempLockPath()
        // A non-ZwiftClickV2 process holding the lock and writing its PID, like a reused PID would look.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", #"use Fcntl ":flock"; open(F, "+>", $ARGV[0]) or die; flock(F, LOCK_EX) or die; print F "$$\n"; close(STDOUT); F->flush; sleep 30;"#, path]
        try holder.run()
        defer { holder.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while (try? InstanceLock(path: path)) != nil, Date() < deadline { usleep(50_000) } // wait until perl holds it

        #expect(throws: InstanceLock.LockError.alreadyRunning(pid: holder.processIdentifier)) {
            try InstanceLock.takeOver(path: path, timeout: 0.2)
        }
        #expect(holder.isRunning)
        #expect(!InstanceLock.isZwiftClickV2(holder.processIdentifier))
    }
}
