import CryptoKit
@testable import FluidVoice_Debug
import XCTest

/// Fixed vector for the v3.1 pairing crypto (spec §5, Med#9). Three hand-copied implementations
/// (Mac, phone, watch) exist for this math with no shared test suite — this is what keeps them
/// identical. The iOS/watch repos assert against these exact values; do not change any of them
/// without updating all three.
#if DEBUG
final class RemoteMicCryptoV31Tests: XCTestCase {
    private let phonePrivateKeyBytes = Data((0..<32).map { UInt8($0) })
    private let macPrivateKeyBytes = Data((0..<32).map { UInt8($0 + 32) })
    private let np = Data((0..<16).map { UInt8($0) })
    private let nm = Data(repeating: 0xBB, count: 16)

    private static let expectedPhonePublicKeyB64 = "j0DFrbaPJWJK5bIU6nZ6bslNgp09e14a0bpvPiE4KF8"
    private static let expectedMacPublicKeyB64 = "NYBy1jZYgNGu6jKa35EhODhR7SGijjt16WXQ0s0WYlQ"
    private static let expectedCommitmentB64 = "m8NQ9LVXdqowusTMvXUgUMG3QUnUsYTAI8ywSo4Ta_c"
    private static let expectedDigits = "810247"
    private static let expectedKPairHex = "aa7e01c4198293e74ae94cb008e524d9c019bc6507f2f65c4c7d264c382d8ffd"
    private static let expectedSealedConfirmB64 = "JyvS8vPJ5FgdH11yCPcmVwV82Q8WFzM"

    func testVectorMatchesFrozenSpec() throws {
        let phonePrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: self.phonePrivateKeyBytes)
        let macPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: self.macPrivateKeyBytes)
        let phonePublicKey = phonePrivate.publicKey.rawRepresentation
        let macPublicKey = macPrivate.publicKey.rawRepresentation

        XCTAssertEqual(RemoteMicCredentials.base64URLEncode(phonePublicKey), Self.expectedPhonePublicKeyB64)
        XCTAssertEqual(RemoteMicCredentials.base64URLEncode(macPublicKey), Self.expectedMacPublicKeyB64)

        let shared = try macPrivate.sharedSecretFromKeyAgreement(with: phonePrivate.publicKey)

        let commitment = RemoteMicCrypto.commitment(macNonce: self.nm, macPublicKey: macPublicKey, phonePublicKey: phonePublicKey)
        XCTAssertEqual(RemoteMicCredentials.base64URLEncode(commitment), Self.expectedCommitmentB64)

        let transcript = RemoteMicCrypto.transcript(
            phonePublicKey: phonePublicKey,
            macPublicKey: macPublicKey,
            phoneNonce: self.np,
            macNonce: self.nm
        )
        XCTAssertEqual(transcript.count, 96)

        let digits = RemoteMicCrypto.pairingDigits(sharedSecret: shared, transcript: transcript)
        XCTAssertEqual(digits, Self.expectedDigits)

        let pairKey = RemoteMicCrypto.pairKey(sharedSecret: shared, transcript: transcript)
        let pairKeyHex = pairKey.withUnsafeBytes { bytes in bytes.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(pairKeyHex, Self.expectedKPairHex)

        let sealed = try RemoteMicCrypto.seal(
            plaintext: Data("confirm".utf8),
            key: pairKey,
            domain: .pairConfirm,
            counter: 0,
            aad: Data(digits.utf8)
        )
        XCTAssertEqual(RemoteMicCredentials.base64URLEncode(sealed), Self.expectedSealedConfirmB64)

        // Phone-side reveal check (spec §2): the phone independently verifies the Mac's nonce
        // against the earlier commitment before trusting it.
        XCTAssertEqual(RemoteMicCrypto.commitment(macNonce: self.nm, macPublicKey: macPublicKey, phonePublicKey: phonePublicKey), commitment)
    }
}
#endif
