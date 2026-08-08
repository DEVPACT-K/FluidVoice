@testable import FluidVoice_Debug
import XCTest

#if DEBUG
/// v3.2 spec Part 1: `parentID`/`kind` storage compatibility and parenting rules.
final class RemoteMicPairedDeviceV32Tests: XCTestCase {
    /// A record stored before v3.2 (no `parentID`/`kind` keys) must still decode, or an upgrade
    /// wipes every paired device with a bare 403 (see `RemoteMicPairedDevice` doc comment).
    func testDecodesRecordMissingV32Keys() throws {
        let json = """
        [{"id":"abc","name":"iPhone","peerIP":"10.0.0.5","pairedAt":0,"capabilities":{"cmd":false}}]
        """
        let decoded = try JSONDecoder().decode([RemoteMicPairedDevice].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].parentID)
        XCTAssertNil(decoded[0].kind)
    }
}

final class RemoteMicCredentialsPairingRulesTests: XCTestCase {
    private static let devicesKey = "RemoteMicPairedDevicesV31"
    private var savedDevices: Data?

    /// The test host IS the app, so this store is the user's real one. `regenerate()` here would
    /// rotate the master token and unpair every real device — snapshot and restore instead.
    override func setUp() {
        super.setUp()
        self.savedDevices = UserDefaults.standard.data(forKey: Self.devicesKey)
        UserDefaults.standard.removeObject(forKey: Self.devicesKey)
    }

    override func tearDown() {
        if let savedDevices {
            UserDefaults.standard.set(savedDevices, forKey: Self.devicesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.devicesKey)
        }
        super.tearDown()
    }

    func testChildCannotParent() {
        let phone = RemoteMicCredentials.shared.registerDevice(name: "Phone", peerIP: "1.1.1.1", parentID: nil, kind: "phone")
        let watch = RemoteMicCredentials.shared.registerDevice(name: "Watch", peerIP: "1.1.1.1", parentID: phone.deviceID, kind: "watch")
        let grandchild = RemoteMicCredentials.shared.registerDevice(name: "Other", peerIP: "1.1.1.1", parentID: watch.deviceID, kind: "watch")

        let devices = RemoteMicCredentials.shared.pairedDevices
        XCTAssertEqual(devices.first { $0.id == watch.deviceID }?.parentID, phone.deviceID)
        XCTAssertNil(devices.first { $0.id == grandchild.deviceID }?.parentID)
    }

    func testSameKindReplacesExistingChild() {
        let phone = RemoteMicCredentials.shared.registerDevice(name: "Phone", peerIP: "1.1.1.1", parentID: nil, kind: "phone")
        let watch1 = RemoteMicCredentials.shared.registerDevice(name: "Watch1", peerIP: "1.1.1.1", parentID: phone.deviceID, kind: "watch")
        let watch2 = RemoteMicCredentials.shared.registerDevice(name: "Watch2", peerIP: "1.1.1.1", parentID: phone.deviceID, kind: "watch")

        let devices = RemoteMicCredentials.shared.pairedDevices
        XCTAssertNil(devices.first { $0.id == watch1.deviceID })
        XCTAssertNotNil(devices.first { $0.id == watch2.deviceID })
        XCTAssertEqual(devices.filter { $0.parentID == phone.deviceID }.count, 1)
    }

    func testRevokeCascadesRecursivelyToChildren() {
        let phone = RemoteMicCredentials.shared.registerDevice(name: "Phone", peerIP: "1.1.1.1", parentID: nil, kind: "phone")
        let watch = RemoteMicCredentials.shared.registerDevice(name: "Watch", peerIP: "1.1.1.1", parentID: phone.deviceID, kind: "watch")

        RemoteMicCredentials.shared.revokeDevice(id: phone.deviceID)

        let devices = RemoteMicCredentials.shared.pairedDevices
        XCTAssertTrue(devices.isEmpty)
        XCTAssertNil(devices.first { $0.id == watch.deviceID })
    }

    func testUnrelatedDeviceSurvivesRevoke() {
        let phone = RemoteMicCredentials.shared.registerDevice(name: "Phone", peerIP: "1.1.1.1", parentID: nil, kind: "phone")
        _ = RemoteMicCredentials.shared.registerDevice(name: "Watch", peerIP: "1.1.1.1", parentID: phone.deviceID, kind: "watch")
        let otherPhone = RemoteMicCredentials.shared.registerDevice(name: "OtherPhone", peerIP: "2.2.2.2", parentID: nil, kind: "phone")

        RemoteMicCredentials.shared.revokeDevice(id: phone.deviceID)

        let devices = RemoteMicCredentials.shared.pairedDevices
        XCTAssertEqual(devices.map(\.id), [otherPhone.deviceID])
    }
}

/// v3.2 spec Part 2: `/stop` body matrix — `m`/`ai` parsing and the AI-can-only-reduce policy.
final class RemoteMicStopBodyV32Tests: XCTestCase {
    private func body(_ json: String) -> Data { Data(json.utf8) }

    func testAbsentModeAndAIDefaultToDictateAndFalse() {
        let (lastSeq, request) = RemoteAudioHTTPIngest.parseStopBody(self.body("{}"))
        XCTAssertNil(lastSeq)
        XCTAssertEqual(request.mode, .dictate)
        XCTAssertFalse(request.aiRequested)
    }

    func testUnknownModeFallsBackToDictate() {
        let (_, request) = RemoteAudioHTTPIngest.parseStopBody(self.body(#"{"m":"command"}"#))
        XCTAssertEqual(request.mode, .dictate)
    }

    func testExplicitDictateModeAndAITrueParse() {
        let (lastSeq, request) = RemoteAudioHTTPIngest.parseStopBody(self.body(#"{"lastSeq":7,"m":"dictate","ai":true}"#))
        XCTAssertEqual(lastSeq, 7)
        XCTAssertEqual(request.mode, .dictate)
        XCTAssertTrue(request.aiRequested)
    }

    func testAIFalseParses() {
        let (_, request) = RemoteAudioHTTPIngest.parseStopBody(self.body(#"{"ai":false}"#))
        XCTAssertFalse(request.aiRequested)
    }

    /// Remote may only reduce, never expand, the Mac's own AI gate decision.
    func testAcceptedAIMatrix() {
        XCTAssertFalse(RemoteMicSession.acceptedAI(macAllows: false, requested: false))
        XCTAssertFalse(RemoteMicSession.acceptedAI(macAllows: false, requested: true))
        XCTAssertFalse(RemoteMicSession.acceptedAI(macAllows: true, requested: false))
        XCTAssertTrue(RemoteMicSession.acceptedAI(macAllows: true, requested: true))
    }
}
#endif
