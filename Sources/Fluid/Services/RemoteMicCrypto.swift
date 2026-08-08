import Foundation
import CryptoKit

/// AES-GCM wire format for v2 sessions and v3.1 pairing. Every constant is a locked wire value.
enum RemoteMicCrypto {
    static let startKeyInfo = "fvmic-v2-start"
    static let sessionKeyInfo = "fvmic-v2-session"
    static let pairKeyInfo = "fvmic-v31-pair"
    static let pairDigitsInfo = "fvmic-v31-digits"
    static let deviceTokenInfo = "fvmic-v31-device"

    enum NonceDomain: UInt32 {
        case start = 0x0000_0000
        case chunk = 0x0000_0001
        case stop = 0x0000_0002
        case pairConfirm = 0x0000_0003
        case pairGrant = 0x0000_0004
        case revoke = 0x0000_0005
    }

    /// `SHA256(Nm || macPub || phonePub)`, sent before the Mac sees `Np` — this is what removes
    /// the attacker's last-mover advantage. Do not reorder the concatenation.
    static func commitment(macNonce: Data, macPublicKey: Data, phonePublicKey: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: macNonce)
        hasher.update(data: macPublicKey)
        hasher.update(data: phonePublicKey)
        return Data(hasher.finalize())
    }

    static func transcript(phonePublicKey: Data, macPublicKey: Data, phoneNonce: Data, macNonce: Data) -> Data {
        phonePublicKey + macPublicKey + phoneNonce + macNonce
    }

    static func pairKey(sharedSecret: SharedSecret, transcript: Data) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data(pairKeyInfo.utf8),
            outputByteCount: 32
        )
    }

    static func pairingDigits(sharedSecret: SharedSecret, transcript: Data) -> String {
        let material = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data(pairDigitsInfo.utf8),
            outputByteCount: 4
        )
        let bytes = material.withUnsafeBytes { Array($0) }
        var value: UInt32 = 0
        for byte in bytes {
            value = (value << 8) | UInt32(byte)
        }
        return String(format: "%06u", value % 1_000_000)
    }

    static func deviceToken(masterTokenBytes: [UInt8], deviceID: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterTokenBytes),
            salt: Data(deviceID.utf8),
            info: Data(deviceTokenInfo.utf8),
            outputByteCount: 32
        )
    }

    static func seal(
        plaintext: Data,
        key: SymmetricKey,
        domain: NonceDomain,
        counter: UInt64,
        aad: Data
    ) throws -> Data {
        let nonce = try self.nonce(domain: domain, counter: counter)
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return sealedBox.ciphertext + sealedBox.tag
    }

    enum CryptoError: Error {
        case invalidTokenLength
        case invalidNonceInput
        case openFailed
    }

    static func startKey(tokenBytes: [UInt8], clientNonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: tokenBytes),
            salt: clientNonce,
            info: Data(startKeyInfo.utf8),
            outputByteCount: 32
        )
    }

    static func sessionKey(tokenBytes: [UInt8], sessionID: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: tokenBytes),
            salt: Data(sessionID.utf8),
            info: Data(sessionKeyInfo.utf8),
            outputByteCount: 32
        )
    }

    /// `[4-byte domain BE][8-byte counter BE]`. Never transmitted; both sides re-derive it.
    static func nonce(domain: NonceDomain, counter: UInt64) throws -> AES.GCM.Nonce {
        var bytes = [UInt8]()
        bytes.reserveCapacity(12)
        let domainBE = domain.rawValue.bigEndian
        withUnsafeBytes(of: domainBE) { bytes.append(contentsOf: $0) }
        let counterBE = counter.bigEndian
        withUnsafeBytes(of: counterBE) { bytes.append(contentsOf: $0) }
        guard bytes.count == 12 else { throw CryptoError.invalidNonceInput }
        return try AES.GCM.Nonce(data: bytes)
    }

    static func open(
        wireBody: Data,
        key: SymmetricKey,
        domain: NonceDomain,
        counter: UInt64,
        aad: Data
    ) throws -> Data {
        guard wireBody.count >= 16 else { throw CryptoError.openFailed }
        let tagStart = wireBody.index(wireBody.endIndex, offsetBy: -16)
        let ciphertext = wireBody[wireBody.startIndex..<tagStart]
        let tag = wireBody[tagStart...]
        let nonce = try self.nonce(domain: domain, counter: counter)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        do {
            return try AES.GCM.open(sealedBox, using: key, authenticating: aad)
        } catch {
            throw CryptoError.openFailed
        }
    }
}
