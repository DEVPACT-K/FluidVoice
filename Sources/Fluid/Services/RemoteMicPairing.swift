#if DEBUG
import Combine
import CryptoKit
import Foundation

/// Numeric-comparison pairing modelled on Bluetooth SSP: a commitment round plus a mandatory
/// Mac-side human confirm. That click and the user-opened window are the only things between an
/// open LAN and a token grant. Touched from `controlQueue` and MainActor, so all state — including
/// `onStateChange` — is lock-guarded.
final class RemoteMicPairing: @unchecked Sendable {
    static let shared = RemoteMicPairing()

    static let windowDuration: TimeInterval = 2 * 60
    private static let attemptDuration: TimeInterval = 60
    private static let maxHellosPerIPPerWindow = 3

    enum State: Equatable {
        case closed
        case waitingForDevice(until: Date)
        case awaitingReveal(deviceName: String, peerIP: String)
        case awaitingComparison(digits: String, deviceName: String, peerIP: String)
        case localConfirmed(digits: String, deviceName: String, peerIP: String)
        case paired(deviceName: String)
        case failed(String)
    }

    enum HelloOutcome {
        case ok(macPublicKey: Data, commitment: Data)
        case rejected
    }

    enum ConfirmOutcome {
        case pending
        case granted(Data)
        case peerMismatch
        case rejected
    }

    enum RevealOutcome {
        case ok(macNonce: Data)
        case peerMismatch
        case rejected
    }

    private let lock = NSLock()
    private var state: State = .closed
    private var version: UInt64 = 0
    private var windowExpiry: Date?
    private var helloCountsByPeerIP: [String: Int] = [:]

    private var attemptDeadline: Date?
    private var attemptDeviceName: String?
    private var attemptPeerIP: String?
    private var attemptKind: String?
    private var attemptParentID: String?
    private var attemptMacPublicKey: Data?
    private var attemptPhonePublicKey: Data?
    private var attemptMacNonce: Data?
    private var attemptSharedSecret: SharedSecret?
    private var attemptDigits: String?
    private var attemptPairKey: SymmetricKey?
    private var attemptLocallyConfirmed = false

    private var onStateChangeLocked: ((State, UInt64) -> Void)?
    var onStateChange: ((State, UInt64) -> Void)? {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.onStateChangeLocked
        }
        set {
            self.lock.lock()
            self.onStateChangeLocked = newValue
            self.lock.unlock()
        }
    }

    private init() {}

    var currentState: State {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.expireIfNeededLocked()
    }

    /// The poll path needs the version, else it can be overwritten by a late older callback.
    var currentStateAndVersion: (state: State, version: UInt64) {
        self.lock.lock()
        defer { self.lock.unlock() }
        let state = self.expireIfNeededLocked()
        return (state, self.version)
    }

    func openWindow() {
        self.lock.lock()
        let expiry = Date().addingTimeInterval(Self.windowDuration)
        self.windowExpiry = expiry
        self.helloCountsByPeerIP.removeAll()
        self.clearAttemptLocked()
        let result = self.transitionLocked(to: .waitingForDevice(until: expiry))
        self.lock.unlock()
        self.invoke(result)
    }

    func closeWindow() {
        self.lock.lock()
        self.windowExpiry = nil
        self.helloCountsByPeerIP.removeAll()
        self.clearAttemptLocked()
        let result = self.transitionLocked(to: .closed)
        self.lock.unlock()
        self.invoke(result)
    }

    /// Step 1 (`/pair/hello`). Commits to `Nm` without revealing it — the point of the round.
    /// `kind`/`parentID` are unauthenticated here; the human confirm still gates the grant.
    func beginAttempt(phonePublicKey: Data, deviceName: String, peerIP: String, kind: String, parentID: String?) -> HelloOutcome {
        self.lock.lock()

        guard case .waitingForDevice = self.expireIfNeededLocked() else {
            self.lock.unlock()
            return .rejected
        }

        let count = (self.helloCountsByPeerIP[peerIP] ?? 0) + 1
        self.helloCountsByPeerIP[peerIP] = count
        guard count <= Self.maxHellosPerIPPerWindow else {
            DebugLogger.shared.error(
                "Remote mic pairing: rate-limited /pair/hello from \(peerIP)",
                source: "RemoteMicPairing"
            )
            // Reject only this peer; the global state machine (and window) stays usable for others.
            self.lock.unlock()
            return .rejected
        }

        guard phonePublicKey.count == 32, !Self.isLowOrderOrIdentity(phonePublicKey) else {
            DebugLogger.shared.error(
                "Remote mic pairing: rejected low-order/identity public key from \(peerIP)",
                source: "RemoteMicPairing"
            )
            self.lock.unlock()
            return .rejected
        }
        guard let phoneKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phonePublicKey) else {
            self.lock.unlock()
            return .rejected
        }

        let macPrivate = Curve25519.KeyAgreement.PrivateKey()
        let macPublicKey = macPrivate.publicKey.rawRepresentation
        guard let shared = try? macPrivate.sharedSecretFromKeyAgreement(with: phoneKey) else {
            self.lock.unlock()
            return .rejected
        }

        var macNonceBytes = Data(count: 16)
        macNonceBytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        let commitment = RemoteMicCrypto.commitment(
            macNonce: macNonceBytes,
            macPublicKey: macPublicKey,
            phonePublicKey: phonePublicKey
        )

        self.attemptDeviceName = deviceName
        self.attemptPeerIP = peerIP
        self.attemptKind = kind
        self.attemptParentID = parentID
        self.attemptMacPublicKey = macPublicKey
        self.attemptPhonePublicKey = phonePublicKey
        self.attemptMacNonce = macNonceBytes
        self.attemptSharedSecret = shared
        self.attemptDeadline = min(
            Date().addingTimeInterval(Self.attemptDuration),
            self.windowExpiry ?? Date().addingTimeInterval(Self.attemptDuration)
        )

        let result = self.transitionLocked(to: .awaitingReveal(deviceName: deviceName, peerIP: peerIP))
        self.lock.unlock()
        self.invoke(result)
        return .ok(macPublicKey: macPublicKey, commitment: commitment)
    }

    /// Step 2 (`/pair/reveal`): contributions are locked, so `Nm` can be revealed. Same peer only,
    /// else a LAN host can consume the reveal step and break the legitimate pairing.
    func reveal(phoneNonce: Data, peerIP: String) -> RevealOutcome {
        self.lock.lock()
        guard case let .awaitingReveal(deviceName, expectedPeerIP) = self.expireIfNeededLocked() else {
            self.lock.unlock()
            return .rejected
        }
        guard peerIP == expectedPeerIP else {
            self.lock.unlock()
            return .peerMismatch
        }
        guard phoneNonce.count == 16,
              let phonePublicKey = self.attemptPhonePublicKey,
              let macPublicKey = self.attemptMacPublicKey,
              let macNonce = self.attemptMacNonce,
              let shared = self.attemptSharedSecret
        else {
            self.lock.unlock()
            return .rejected
        }

        let transcript = RemoteMicCrypto.transcript(
            phonePublicKey: phonePublicKey,
            macPublicKey: macPublicKey,
            phoneNonce: phoneNonce,
            macNonce: macNonce
        )
        let digits = RemoteMicCrypto.pairingDigits(sharedSecret: shared, transcript: transcript)
        let pairKey = RemoteMicCrypto.pairKey(sharedSecret: shared, transcript: transcript)

        self.attemptDigits = digits
        self.attemptPairKey = pairKey

        let result = self.transitionLocked(
            to: .awaitingComparison(digits: digits, deviceName: deviceName, peerIP: expectedPeerIP)
        )
        self.lock.unlock()
        self.invoke(result)
        return .ok(macNonce: macNonce)
    }

    /// The human at the Mac clicked "Numbers Match". Must never be satisfiable remotely.
    func confirmLocally() {
        self.lock.lock()
        guard case let .awaitingComparison(digits, deviceName, peerIP) = self.expireIfNeededLocked() else {
            self.lock.unlock()
            return
        }
        self.attemptLocallyConfirmed = true
        let result = self.transitionLocked(
            to: .localConfirmed(digits: digits, deviceName: deviceName, peerIP: peerIP)
        )
        self.lock.unlock()
        self.invoke(result)
    }

    /// Step 3 (`/pair/confirm`). A valid seal proves the phone derived the same `K_pair`, but it
    /// only becomes a grant once the Mac user has clicked; otherwise it is `.pending`.
    func completeAttempt(sealedConfirmation: Data, peerIP: String) -> ConfirmOutcome {
        self.lock.lock()
        let state = self.expireIfNeededLocked()

        let digits: String?
        let deviceName: String?
        switch state {
        case let .awaitingComparison(d, name, _): digits = d; deviceName = name
        case let .localConfirmed(d, name, _): digits = d; deviceName = name
        default: digits = nil; deviceName = nil
        }

        guard let digits, let deviceName else {
            self.lock.unlock()
            return .rejected
        }
        guard peerIP == self.attemptPeerIP else {
            self.lock.unlock()
            return .peerMismatch
        }

        guard let key = self.attemptPairKey,
              let plaintext = try? RemoteMicCrypto.open(
                  wireBody: sealedConfirmation,
                  key: key,
                  domain: .pairConfirm,
                  counter: 0,
                  aad: Data(digits.utf8)
              ),
              String(data: plaintext, encoding: .utf8) == "confirm"
        else {
            self.lock.unlock()
            return .rejected
        }

        guard case .localConfirmed = state else {
            self.lock.unlock()
            return .pending
        }

        let peerIP = self.attemptPeerIP ?? "unknown"
        let kind = self.attemptKind ?? "phone"
        let parentID = self.attemptParentID
        let (deviceID, deviceTokenData) = RemoteMicCredentials.shared.registerDevice(
            name: deviceName,
            peerIP: peerIP,
            parentID: parentID,
            kind: kind
        )
        let grant: [String: Any] = [
            "t": RemoteMicCredentials.base64URLEncode(deviceTokenData),
            "e": RemoteMicCredentials.shared.epoch,
            "d": deviceID,
            "c": ["cmd": false],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: grant, options: []),
              let sealed = try? RemoteMicCrypto.seal(
                  plaintext: payload,
                  key: key,
                  domain: .pairGrant,
                  counter: 0,
                  aad: Data(digits.utf8)
              )
        else {
            self.lock.unlock()
            return .rejected
        }

        self.windowExpiry = nil
        self.clearAttemptLocked()
        let result = self.transitionLocked(to: .paired(deviceName: deviceName))
        self.lock.unlock()
        self.invoke(result)
        return .granted(sealed)
    }

    @discardableResult
    private func expireIfNeededLocked() -> State {
        let now = Date()
        if let attemptDeadline, now >= attemptDeadline {
            self.clearAttemptLocked()
            if let windowExpiry, now < windowExpiry {
                _ = self.transitionLocked(to: .waitingForDevice(until: windowExpiry))
            } else {
                self.windowExpiry = nil
                _ = self.transitionLocked(to: .closed)
            }
        }
        if let windowExpiry, now >= windowExpiry, self.attemptDeadline == nil {
            self.windowExpiry = nil
            if self.state != .closed {
                _ = self.transitionLocked(to: .closed)
            }
        }
        return self.state
    }

    /// Assigns state + bumps `version` atomically. Call with `lock` held.
    private func transitionLocked(to newState: State) -> (State, UInt64) {
        self.state = newState
        self.version &+= 1
        return (newState, self.version)
    }

    private func invoke(_ result: (State, UInt64)) {
        self.onStateChange?(result.0, result.1)
    }

    private func clearAttemptLocked() {
        self.attemptDeadline = nil
        self.attemptDeviceName = nil
        self.attemptPeerIP = nil
        self.attemptKind = nil
        self.attemptParentID = nil
        self.attemptMacPublicKey = nil
        self.attemptPhonePublicKey = nil
        self.attemptMacNonce = nil
        self.attemptSharedSecret = nil
        self.attemptDigits = nil
        self.attemptPairKey = nil
        self.attemptLocallyConfirmed = false
    }

    /// X25519 small-order/identity points, whose ECDH result is attacker-predictable.
    private static let lowOrderBlacklist: [[UInt8]] = [
        [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        [0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3, 0xfa, 0xf1, 0x9f, 0xc4, 0x6a,
         0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32, 0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16, 0x5f, 0x49, 0xb8, 0x00],
        [0x5f, 0x9c, 0x95, 0xbc, 0xa3, 0x50, 0x8c, 0x24, 0xb1, 0xd0, 0xb1, 0x55, 0x9c, 0x83, 0xef, 0x5b,
         0x04, 0x44, 0x5c, 0xc4, 0x58, 0x1c, 0x8e, 0x86, 0xd8, 0x22, 0x4e, 0xdd, 0x09, 0xf1, 0x15, 0x7f],
        [0xec, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
         0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f],
        [0xed, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
         0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f],
        [0xee, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
         0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f],
    ]

    private static func isLowOrderOrIdentity(_ publicKey: Data) -> Bool {
        let bytes = Array(publicKey)
        return self.lowOrderBlacklist.contains(bytes)
    }
}

/// MainActor mirror. Drops callbacks older than the last applied version, so an out-of-order
/// `Task { @MainActor }` hop can never regress the displayed state.
@MainActor
final class RemoteMicPairingModel: ObservableObject {
    static let shared = RemoteMicPairingModel()

    @Published private(set) var state: RemoteMicPairing.State = .closed
    private var lastAppliedVersion: UInt64 = 0

    private init() {
        RemoteMicPairing.shared.onStateChange = { [weak self] newState, version in
            Task { @MainActor in self?.apply(newState, version: version) }
        }
    }

    private func apply(_ newState: RemoteMicPairing.State, version: UInt64) {
        guard version > self.lastAppliedVersion else { return }
        self.lastAppliedVersion = version
        self.state = newState
    }

    func refresh() {
        // Expiry is a deadline, not an event; the version stops a late callback overwriting this.
        let current = RemoteMicPairing.shared.currentStateAndVersion
        self.apply(current.state, version: current.version)
    }
}
#endif
