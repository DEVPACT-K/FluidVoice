import Foundation

/// Posted by `RemoteMicCredentials` on revoke/regenerate so a listener can terminate any armed
/// session belonging to the affected device(s) instead of letting it ride out the session cap.
extension Notification.Name {
    static let remoteMicDeviceRevoked = Notification.Name("com.fluidvoice.remoteMicDeviceRevoked")
}

/// Session-lifecycle contract between `RemoteAudioHTTPIngest` (transport) and `ASRService` (owner).
enum RemoteMicSession {
    /// `userInfo` key for `.remoteMicDeviceRevoked`; value is a `Set<String>` of revoked deviceIDs.
    static let revokedDeviceIDsKey = "deviceIDs"

    enum ArmOutcome {
        case armed(generation: UInt64, ingest: @Sendable ([Float], Double, UInt64, Int64) -> Void)
        case rejected(reason: String)
    }

    /// No value beyond `.dictate` is accepted in v3.2 — edit/command mode are out of scope.
    enum StopMode: String {
        case dictate
    }

    struct StopRequest {
        let mode: StopMode
        let aiRequested: Bool
    }

    struct Handlers {
        let onStartRequested: () async -> ArmOutcome
        let onStopRequested: (StopRequest) async -> Bool
        let onAbnormalDisconnect: () async -> Void
    }

    /// A remote device may only reduce the Mac's own AI gate decision, never expand it.
    static func acceptedAI(macAllows: Bool, requested: Bool) -> Bool {
        macAllows && requested
    }
}
