import CoreBluetooth
import Foundation

// Zwift Click v2 BLE protocol, as observed on firmware 1.0.2:
// - Two separate peripherals ("pucks"), both named "Zwift Click", advertising service FC82.
// - Manufacturer data `4a 09 <type> ...`: company 0x094A (Zwift), type 0x0B = left, 0x0A = right.
// - Unencrypted: write "RideOn" 02 03 to sync-rx (write-without-response); the puck echoes it on sync-tx.
// - Button events on async: 0x23 + protobuf, field 1 = button bitmap where a 0 bit means "pressed".
// - The left puck also relays the right puck's button bits (~20-30 ms later).
//
// Zwift Click v1 (one device, + and - buttons), as used by the v1 app on real hardware:
// - Named "Zwift Click", advertising service 00000001-19CA-..., manufacturer type 0x09.
// - Encrypted: ECDH key exchange on sync-rx/sync-tx, then AES-CCM packets on async (see ZapCrypto).
// - Decrypted button message: 0x37 + protobuf, field 1 = plus, field 2 = minus, 0 = pressed.

public enum ZwiftUUID {
    public static let service = CBUUID(string: "FC82")
    public static let serviceV1 = CBUUID(string: "00000001-19CA-4651-86E5-FA29DCDD09D1")
    public static let async   = CBUUID(string: "00000002-19CA-4651-86E5-FA29DCDD09D1")
    public static let syncRx  = CBUUID(string: "00000003-19CA-4651-86E5-FA29DCDD09D1")
    public static let syncTx  = CBUUID(string: "00000004-19CA-4651-86E5-FA29DCDD09D1")
}

public enum Side: String, CaseIterable, Sendable {
    case left, right

    public static let zwiftCompanyID: UInt16 = 0x094A

    /// Identifies a Click v2 puck from its BLE manufacturer data (company ID is little-endian).
    public init?(manufacturerData: Data) {
        let b = [UInt8](manufacturerData)
        guard b.count >= 3, UInt16(b[0]) | UInt16(b[1]) << 8 == Side.zwiftCompanyID else { return nil }
        switch b[2] {
        case 0x0B: self = .left
        case 0x0A: self = .right
        default:   return nil
        }
    }

    /// The five physical buttons on this puck.
    public var buttons: [Button] { Button.allCases.filter { $0.side == self } }
}

/// A connectable Zwift controller. A Click v1 and both Click v2 pucks can be connected at once.
public enum DeviceKind: String, CaseIterable, Sendable {
    case clickV1, clickV2Left, clickV2Right

    static let deviceName = "Zwift Click"

    /// Identifies a controller from its advertisement. Zwift manufacturer data decides when present,
    /// so other Zwift devices (Play, Ride, Hub) are never picked up. Without it, falls back to what the
    /// v1 app matched on: the v1 service plus the "Zwift Click" name.
    public init?(manufacturerData: Data?, serviceUUIDs: [CBUUID], name: String?) {
        if let data = manufacturerData {
            let b = [UInt8](data)
            if b.count >= 3, UInt16(b[0]) | UInt16(b[1]) << 8 == Side.zwiftCompanyID {
                switch b[2] {
                case 0x09: self = .clickV1
                case 0x0B: self = .clickV2Left
                case 0x0A: self = .clickV2Right
                default:   return nil
                }
                return
            }
        }
        guard serviceUUIDs.contains(ZwiftUUID.serviceV1), name == DeviceKind.deviceName else { return nil }
        self = .clickV1
    }

    /// The v2 puck side, or nil for the Click v1.
    public var side: Side? {
        switch self {
        case .clickV1:      return nil
        case .clickV2Left:  return .left
        case .clickV2Right: return .right
        }
    }

    public var service: CBUUID { self == .clickV1 ? ZwiftUUID.serviceV1 : ZwiftUUID.service }

    public var buttons: [Button] { side?.buttons ?? [.plus, .minus] }

    /// Human-readable name for log messages. Always says v1 or v2, so logs show which controller acted.
    public var displayName: String {
        switch self {
        case .clickV1:      return "Click v1"
        case .clickV2Left:  return "Click v2 left puck"
        case .clickV2Right: return "Click v2 right puck"
        }
    }

    /// Controller version as written in the config's `controllers` list.
    public var version: String { self == .clickV1 ? "v1" : "v2" }

    /// The kinds a `controllers` entry stands for ("v2" = both pucks), or nil if unknown.
    public static func kinds(forVersion name: String) -> Set<DeviceKind>? {
        let kinds = Set(allCases.filter { $0.version == name.lowercased() })
        return kinds.isEmpty ? nil : kinds
    }

    /// e.g. "Click v2 only" or "Click v1 + Click v2", for the startup log.
    public static func summary(of kinds: Set<DeviceKind>) -> String {
        let versions = Set(kinds.map(\.version)).sorted().map { "Click \($0)" }
        return versions.count == 1 ? "\(versions[0]) only" : versions.joined(separator: " + ")
    }

    /// Short prefix for per-button log lines, e.g. "[Click v2 right] plus tap -> k".
    public var logTag: String {
        switch self {
        case .clickV1:      return "[Click v1]"
        case .clickV2Left:  return "[Click v2 left]"
        case .clickV2Right: return "[Click v2 right]"
        }
    }
}

public enum Button: String, CaseIterable, Codable, Sendable {
    // Left puck
    case up, down, left, right, minus
    // Right puck
    case y, z, b, a, plus

    /// Bit in the 0x23 button bitmap. The bit is 0 while the button is pressed.
    public var bit: UInt32 {
        switch self {
        case .left:  return 0x0001
        case .up:    return 0x0002
        case .right: return 0x0004
        case .down:  return 0x0008
        case .a:     return 0x0010
        case .b:     return 0x0020
        case .y:     return 0x0040
        case .z:     return 0x0080
        case .minus: return 0x0100
        case .plus:  return 0x1000
        }
    }

    public var side: Side {
        switch self {
        case .up, .down, .left, .right, .minus: return .left
        case .y, .z, .b, .a, .plus:             return .right
        }
    }
}

public enum Message: Equatable, Sendable {
    /// The puck echoed our "RideOn" handshake.
    case handshakeEcho
    /// Raw button bitmap (0 bit = pressed).
    case buttons(UInt32)
    /// Click v1: the buttons pressed right now (decrypted 0x37 message).
    case pressed(Set<Button>)
    /// Battery level in percent.
    case battery(Int)
    /// Any other message type (debug log text, pairing data, ...).
    case other(UInt8)
}

public enum ZwiftProtocol {
    public static let handshake: [UInt8] = Array("RideOn".utf8) + [0x02, 0x03]
    static let rideOnPrefix: [UInt8] = Array("RideOn".utf8)
    static let buttonMessageType: UInt8 = 0x23
    static let batteryMessageType: UInt8 = 0x19
    static let v1ButtonMessageType: UInt8 = 0x37

    /// Parses one notification. Returns nil for empty or malformed messages.
    public static func parse(_ bytes: [UInt8]) -> Message? {
        guard let type = bytes.first else { return nil }
        if bytes.starts(with: rideOnPrefix) { return .handshakeEcho }
        let body = bytes.dropFirst()
        switch type {
        case buttonMessageType:
            // A missing field 1 would decode as 0 (= every button pressed), so treat it as malformed.
            guard let map = varintFields(body)?[1] else { return nil }
            return .buttons(UInt32(truncatingIfNeeded: map))
        case batteryMessageType:
            guard let level = varintFields(body)?[2] else { return nil }
            return .battery(Int(clamping: level))
        default:
            return .other(type)
        }
    }

    /// Parses one decrypted Click v1 message. Returns nil for empty or malformed messages.
    public static func parseV1(plaintext bytes: [UInt8]) -> Message? {
        guard let type = bytes.first else { return nil }
        let body = bytes.dropFirst()
        switch type {
        case v1ButtonMessageType:
            // Both fields are required: a missing one would otherwise decode as 0 (= pressed).
            guard let fields = varintFields(body), let plus = fields[1], let minus = fields[2] else { return nil }
            var pressed: Set<Button> = []
            if plus == 0 { pressed.insert(.plus) }
            if minus == 0 { pressed.insert(.minus) }
            return .pressed(pressed)
        case batteryMessageType:
            guard let level = varintFields(body)?[2] else { return nil }
            return .battery(Int(clamping: level))
        default:
            return .other(type)
        }
    }

    /// Buttons of `side` that are pressed in `map`. Bits belonging to the other side are ignored,
    /// which is what drops the left puck's relayed copies of right-puck presses.
    public static func pressed(map: UInt32, side: Side) -> Set<Button> {
        Set(side.buttons.filter { map & $0.bit == 0 })
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Reads the varint (wire type 0) fields of a protobuf message, skipping other wire types.
    /// Returns nil if the message is truncated or malformed.
    static func varintFields(_ bytes: ArraySlice<UInt8>) -> [Int: UInt64]? {
        var fields: [Int: UInt64] = [:]
        var i = bytes.startIndex

        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while i < bytes.endIndex {
                let byte = bytes[i]
                i += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        while i < bytes.endIndex {
            guard let key = readVarint() else { return nil }
            let field = Int(key >> 3)
            switch key & 0x7 {
            case 0:
                guard let value = readVarint() else { return nil }
                fields[field] = value
            case 1:
                i += 8
            case 2:
                guard let length = readVarint(), length <= UInt64(bytes.endIndex - i) else { return nil }
                i += Int(length)
            case 5:
                i += 4
            default:
                return nil
            }
            if i > bytes.endIndex { return nil }
        }
        return fields
    }
}
