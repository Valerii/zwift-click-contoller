import CryptoKit
import CryptoSwift
import Foundation

// Click v1 encryption ("ZAP"), ported unchanged from the v1 app, where it works on real hardware:
// 1. We send "RideOn" 01 02 + our P-256 public key (64 bytes, X||Y) to sync-rx.
// 2. The Click answers on sync-tx with "RideOn" 01 03 + its public key.
// 3. ECDH shared secret -> HKDF-SHA256 (salt = device key + our key) -> 32-byte AES key + 4-byte IV prefix.
// 4. Every async packet is counter(4) + ciphertext + tag(4), AES-CCM with nonce = IV prefix + counter.

/// One Click v1 key exchange. Create a new one for every connection.
public struct ZapKeyExchange {
    private let privateKey = P256.KeyAgreement.PrivateKey()

    static let requestHeader: [UInt8] = Array("RideOn".utf8) + [0x01, 0x02]
    static let responseHeader: [UInt8] = Array("RideOn".utf8) + [0x01, 0x03]
    static let publicKeyLength = 64

    public init() {}

    /// Our public key without the 0x04 prefix, as the Click expects it.
    var publicKeyWire: [UInt8] { Array(privateKey.publicKey.x963Representation.dropFirst()) }

    /// The handshake to write to sync-rx.
    public var request: [UInt8] { ZapKeyExchange.requestHeader + publicKeyWire }

    /// True if `bytes` looks like the Click's handshake response (header and length).
    public static func isResponse(_ bytes: [UInt8]) -> Bool {
        bytes.count == responseHeader.count + publicKeyLength && bytes.starts(with: responseHeader)
    }

    /// Derives the session keys from the Click's handshake response.
    public func crypto(fromResponse bytes: [UInt8]) throws -> ZapCrypto {
        guard ZapKeyExchange.isResponse(bytes) else { throw ZapCrypto.Err.badHandshake }
        let devicePublicKeyWire = Array(bytes.dropFirst(ZapKeyExchange.responseHeader.count))
        let devicePublicKey = try P256.KeyAgreement.PublicKey(x963Representation: Data([0x04] + devicePublicKeyWire))
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: devicePublicKey)
        return try ZapCrypto(sharedSecret: sharedSecret.withUnsafeBytes { Array($0) },
                             devPubWire: devicePublicKeyWire,
                             ourPubWire: publicKeyWire)
    }
}

/// Session keys for one Click v1 connection.
public struct ZapCrypto {
    let aesKey: [UInt8]
    let ivPrefix: [UInt8]

    public enum Err: Error { case tooShort, badHandshake }

    init(sharedSecret: [UInt8], devPubWire: [UInt8], ourPubWire: [UInt8]) throws {
        let derived = try HKDF(password: sharedSecret,
                               salt: devPubWire + ourPubWire,
                               info: [], keyLength: 36,
                               variant: .sha2(.sha256)).calculate()
        aesKey = Array(derived[0..<32])
        ivPrefix = Array(derived[32..<36])
    }

    /// Decrypts one async packet. Throws if it is too short or fails authentication.
    public func decrypt(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count > 8 else { throw Err.tooShort }
        let counter = Array(data[0..<4])
        let ciphertextAndTag = Array(data[4...])
        let ciphertext = Array(ciphertextAndTag.dropLast(4))
        return try AES(key: aesKey,
                       blockMode: CCM(iv: ivPrefix + counter, tagLength: 4, messageLength: ciphertext.count),
                       padding: .noPadding).decrypt(ciphertextAndTag)
    }
}
