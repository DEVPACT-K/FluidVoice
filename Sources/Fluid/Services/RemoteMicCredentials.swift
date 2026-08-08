import Foundation
import Security
import CryptoKit

/// `cmd` is default-deny for every remote device; nothing in this build flips it.
struct RemoteMicDeviceCapabilities: Codable, Equatable {
    var cmd: Bool = false
}

/// `parentID`/`kind` MUST stay Optional: synthesized `Codable` uses `decodeIfPresent` for Optionals,
/// so records stored before v3.2 (missing both keys) still decode instead of wiping the whole list.
struct RemoteMicPairedDevice: Codable, Equatable, Identifiable {
    let id: String // deviceID (UUID string)
    var name: String
    var peerIP: String
    var pairedAt: Date
    var capabilities: RemoteMicDeviceCapabilities
    var parentID: String?
    var kind: String?
}

/// The Keychain token is a MASTER: each paired device gets its own HKDF-derived token.
final class RemoteMicCredentials {
    static let shared = RemoteMicCredentials()


    private static let keychainService = "FluidVoice Remote Mic"
    private static let keychainAccount = "shared-token"
    private static let pairedDevicesDefaultsKey = "RemoteMicPairedDevicesV31"

    private struct StoredCredential: Codable {
        let t: String // base64url token
        let e: Int // epoch
    }

    private let lock = NSLock()
    private var cached: StoredCredential?

    private init() {}

    var token: String {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.currentLocked().t
    }

    var epoch: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.currentLocked().e
    }

    @discardableResult
    func regenerate() -> (token: String, epoch: Int) {
        self.lock.lock()
        let nextEpoch = self.currentLocked().e + 1
        let fresh = StoredCredential(t: Self.generateToken(), e: nextEpoch)
        self.storeLocked(fresh)
        self.cached = fresh
        let revokedIDs = Set(self.loadPairedDevicesLocked().map(\.id))
        self.storePairedDevicesLocked([])
        self.lock.unlock()
        self.postRevocation(revokedIDs)
        return (fresh.t, fresh.e)
    }

    var pairedDevices: [RemoteMicPairedDevice] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.loadPairedDevicesLocked()
    }

    /// One level only: `parentID` is kept only if it names an existing, parent-less device.
    func registerDevice(name: String, peerIP: String, parentID: String?, kind: String?) -> (deviceID: String, deviceToken: Data) {
        self.lock.lock()
        defer { self.lock.unlock() }
        var devices = self.loadPairedDevicesLocked()

        let resolvedParentID = parentID.flatMap { candidate -> String? in
            guard let parent = devices.first(where: { $0.id == candidate }), parent.parentID == nil else { return nil }
            return candidate
        }
        if let resolvedParentID {
            devices.removeAll { $0.parentID == resolvedParentID && $0.kind == kind }
        }

        let deviceID = UUID().uuidString
        devices.append(RemoteMicPairedDevice(
            id: deviceID,
            name: name,
            peerIP: peerIP,
            pairedAt: Date(),
            capabilities: RemoteMicDeviceCapabilities(cmd: false),
            parentID: resolvedParentID,
            kind: kind
        ))
        self.storePairedDevicesLocked(devices)
        let masterBytes = Self.tokenBytesLocked(self.currentLocked())
        let key = RemoteMicCrypto.deviceToken(masterTokenBytes: masterBytes, deviceID: deviceID)
        return (deviceID, key.withUnsafeBytes { Data($0) })
    }

    func revokeDevice(id: String) {
        self.lock.lock()
        var devices = self.loadPairedDevicesLocked()
        let revokedIDs = self.revokeDeviceLocked(id: id, devices: &devices)
        self.storePairedDevicesLocked(devices)
        self.lock.unlock()
        self.postRevocation(revokedIDs)
    }

    /// Call with `lock` held — recursing through the public `revokeDevice` self-deadlocks `NSLock`.
    @discardableResult
    private func revokeDeviceLocked(id: String, devices: inout [RemoteMicPairedDevice]) -> Set<String> {
        guard devices.contains(where: { $0.id == id }) else { return [] }
        let childIDs = devices.filter { $0.parentID == id }.map(\.id)
        devices.removeAll { $0.id == id }
        var revoked: Set<String> = [id]
        for childID in childIDs {
            revoked.formUnion(self.revokeDeviceLocked(id: childID, devices: &devices))
        }
        return revoked
    }

    /// Must be called with `lock` already released — a synchronous observer calling back into
    /// this class (e.g. `pairedDevices`) would otherwise deadlock the non-recursive `NSLock`.
    private func postRevocation(_ deviceIDs: Set<String>) {
        guard !deviceIDs.isEmpty else { return }
        NotificationCenter.default.post(
            name: .remoteMicDeviceRevoked,
            object: nil,
            userInfo: [RemoteMicSession.revokedDeviceIDsKey: deviceIDs]
        )
    }

    /// Only re-derives while the device is still listed, so revoke actually stops the AEAD opening.
    func deviceTokenBytes(deviceID: String) -> [UInt8]? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.loadPairedDevicesLocked().contains(where: { $0.id == deviceID }) else { return nil }
        let masterBytes = Self.tokenBytesLocked(self.currentLocked())
        let key = RemoteMicCrypto.deviceToken(masterTokenBytes: masterBytes, deviceID: deviceID)
        return key.withUnsafeBytes { Array($0) }
    }

    private func loadPairedDevicesLocked() -> [RemoteMicPairedDevice] {
        guard let data = UserDefaults.standard.data(forKey: Self.pairedDevicesDefaultsKey),
              let decoded = try? JSONDecoder().decode([RemoteMicPairedDevice].self, from: data)
        else { return [] }
        return decoded
    }

    private func storePairedDevicesLocked(_ devices: [RemoteMicPairedDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: Self.pairedDevicesDefaultsKey)
    }

    private static func tokenBytesLocked(_ credential: StoredCredential) -> [UInt8] {
        guard let data = base64URLDecode(credential.t), data.count == 32 else { return [UInt8](repeating: 0, count: 32) }
        return Array(data)
    }

    /// Fail-closed: nil unless the token is exactly 32 bytes. Callers must treat nil as "reject".
    var tokenBytes: [UInt8]? {
        guard let data = Self.base64URLDecode(self.token), data.count == 32 else { return nil }
        return Array(data)
    }

    private func currentLocked() -> StoredCredential {
        if let cached { return cached }
        if let loaded = self.loadLocked() {
            self.cached = loaded
            return loaded
        }
        let fresh = StoredCredential(t: Self.generateToken(), e: 1)
        self.storeLocked(fresh)
        self.cached = fresh
        return fresh
    }

    private func loadLocked() -> StoredCredential? {
        var query = Self.baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredCredential.self, from: data)
    }

    private func storeLocked(_ credential: StoredCredential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }

        var attributes = Self.baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateAttributes: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(Self.baseQuery() as CFDictionary, updateAttributes as CFDictionary)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func generateToken() -> String {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        return base64URLEncode(data)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}
