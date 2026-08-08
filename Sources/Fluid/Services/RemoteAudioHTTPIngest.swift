#if DEBUG
import Foundation
import Network
import CryptoKit

/// Hand-rolled HTTP/1.1 server on 52010; watchOS is TN3135-gated off raw TCP, so URLSession only.
/// `controlQueue` owns the network and all session state; `ingestQueue` is serial and only decodes.
/// Handlers are invoked via `Task` and never run on `controlQueue`.
final class RemoteAudioHTTPIngest {
    static let bonjourServiceType = "_fluidvoice-mic._tcp"
    private static let discoveryProtocolVersion = 1
    private static let sampleRate: Double = 16_000.0
    private static let maxHeldChunks = 16
    private static let gapSkipMs: Double = 400
    private static let stopGraceMs = 800
    private static let stopGraceTickMs = 20
    private static let idleTimeout: TimeInterval = 30
    private static let maxSessionDuration: TimeInterval = 15 * 60
    private static let headerBlockCap = 8 * 1024
    private static let bodyCap = 64 * 1024
    private static let maxConnections = 8
    private static let requestTimeout: TimeInterval = 30
    private static let stopFinalizeFailsafe: TimeInterval = 150
    private static let maxInFlightIngest = 32
    private static let startReplayWindowSeconds: TimeInterval = 60
    /// Must outlast the full ±ts acceptance span, or a nonce ages out while still acceptable.
    private static let startNonceCacheRetention: TimeInterval = startReplayWindowSeconds * 4
    private static let clientNonceByteCount = 16
    /// Far above any real chunk count, far below where the drain cursor could overflow.
    private static let maxPlausibleSeq = Int(sampleRate * maxSessionDuration)

    private let port: UInt16
    private let handlers: RemoteMicSession.Handlers
    /// Real bind outcome; `startListening()` returning is not proof the listener came up.
    private let listenerStateHandler: (Bool, String?) -> Void

    private let controlQueue = DispatchQueue(label: "remote-audio-http-control")
    /// Decode + synchronous ingest only; handlers here would deadlock.
    private let ingestQueue = DispatchQueue(label: "remote-audio-http-ingest")

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    private var currentSessionID: String?
    /// Lets a revoke terminate the armed session instead of waiting out the session cap.
    private var currentDeviceID: String?
    private var arming = false
    private var armed = false
    /// Gates `onAbnormalDisconnect` so a stale arm attempt never tears down a session it
    /// doesn't own.
    private var hasOpenSession = false
    private var stopInProgress = false
    private var generation: UInt64 = 0
    private var ingestClosure: (@Sendable ([Float], Double, UInt64, Int64) -> Void)?
    private var sessionKey: SymmetricKey?
    private var sampleOffset: Int64 = 0
    private var reorder: [Int: Data] = [:]
    private var lastForwarded = -1
    private var gapSince: DispatchTime?

    /// Cross-queue live-audio accept flag: flipped false by stop-finalize/quiesce/teardown and
    /// checked on `ingestQueue` before the ingest call. Only field touched off `controlQueue`.
    private let stateLock = NSLock()
    private var sessionActive = false
    private var ingestInFlight = 0

    private var idleTimer: DispatchSourceTimer?
    private var maxSessionTimer: DispatchSourceTimer?
    private var stopGraceTimer: DispatchSourceTimer?
    private var stopFailsafeTimer: DispatchSourceTimer?

    /// `/start` replay cache (spec §5), keyed by raw client nonce and pruned lazily.
    private var seenStartNonces: [Data: Date] = [:]

    /// Throttle for `sendForbidden`'s log line (Low#15) — an unauthenticated peer can otherwise
    /// drive unbounded log growth by hammering any 403 route.
    private var lastForbiddenLogAt: Date?
    private var suppressedForbiddenCount = 0
    private static let forbiddenLogMinInterval: TimeInterval = 1.0

    private final class HTTPConnection {
        let nw: NWConnection
        var buffer = Data()
        var draining = false
        var awaitingDeferredResponse = false
        var closed = false
        var requestTimer: DispatchSourceTimer?
        init(_ nw: NWConnection) { self.nw = nw }
    }

    init(port: UInt16, handlers: RemoteMicSession.Handlers, listenerStateHandler: @escaping (Bool, String?) -> Void) {
        self.port = port
        self.handlers = handlers
        self.listenerStateHandler = listenerStateHandler
    }

    /// Revoked/regenerated devices stop streaming at once rather than riding out the session cap.
    func terminateSessionIfOwned(byAny deviceIDs: Set<String>) {
        controlQueue.async {
            guard let owner = self.currentDeviceID, deviceIDs.contains(owner) else { return }
            self.clearSessionFieldsLocked(fireAbnormal: true)
        }
    }

    func startListening() throws {
        try controlQueue.sync {
            if self.listener != nil { return }

            guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
                throw RemoteAudioHTTPIngestError.invalidPort(self.port)
            }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters, on: nwPort)
            listener.service = NWListener.Service(
                name: nil,
                type: Self.bonjourServiceType,
                txtRecord: Self.makeTXTRecordData(port: self.port, protocolVersion: Self.discoveryProtocolVersion)
            )

            listener.newConnectionHandler = { [weak self] newConnection in
                self?.handleNewConnection(newConnection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }

            self.listener = listener
            listener.start(queue: self.controlQueue)
        }
    }

    private static func makeTXTRecordData(port: UInt16, protocolVersion: Int) -> Data {
        var data = Data()
        func appendEntry(_ key: String, _ value: String) {
            let bytes = Array("\(key)=\(value)".utf8.prefix(255))
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        appendEntry("port", "\(port)")
        appendEntry("v", "\(protocolVersion)")
        return data
    }

    func stopListening() {
        stateLock.lock()
        sessionActive = false
        stateLock.unlock()

        controlQueue.sync {
            self.cancelIdleTimer()
            self.cancelMaxSessionTimer()
            self.cancelStopGraceTimer()
            self.cancelStopFailsafeTimer()
            self.listener?.cancel()
            self.listener = nil
            for conn in self.connections.values {
                conn.closed = true
                conn.nw.cancel()
            }
            self.connections.removeAll()
            // Residual risk: this instance is rebuilt on every network reconcile, so the replay
            // cache does not survive teardown — a captured /start could replay across a reconcile.
            self.seenStartNonces.removeAll()
            self.clearSessionFieldsLocked(fireAbnormal: false)
        }
        ingestQueue.sync {}
    }

    /// Flip accept off, then barrier on the ingest queue until any in-flight ingest returns.
    /// Must not invoke handlers, hold no lock across the barrier, and nothing on `ingestQueue` may hop
    /// synchronously to MainActor. Safe to call from MainActor (ASRService teardown).
    func quiesceCurrentSession() {
        stateLock.lock()
        sessionActive = false
        stateLock.unlock()
        ingestQueue.sync {}
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            DebugLogger.shared.info(
                "Remote audio HTTP listening on 0.0.0.0:\(self.port)",
                source: "RemoteAudioHTTPIngest"
            )
            self.listenerStateHandler(true, nil)
        case let .failed(error):
            DebugLogger.shared.error(
                "Remote audio HTTP listener failed: \(error.localizedDescription)",
                source: "RemoteAudioHTTPIngest"
            )
            self.listener?.cancel()
            self.listener = nil
            self.listenerStateHandler(false, error.localizedDescription)
        case .cancelled:
            self.listener = nil
            self.listenerStateHandler(false, nil)
        default:
            break
        }
    }

    private func handleNewConnection(_ newConnection: NWConnection) {
        guard self.connections.count < Self.maxConnections else {
            newConnection.cancel()
            return
        }

        let conn = HTTPConnection(newConnection)
        self.connections[ObjectIdentifier(conn)] = conn
        self.armRequestTimer(conn)
        newConnection.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .failed, .cancelled:
                self.removeConnection(conn)
            default:
                break
            }
        }
        newConnection.start(queue: self.controlQueue)
        self.receiveLoop(conn)
    }

    private func removeConnection(_ conn: HTTPConnection) {
        conn.closed = true
        conn.requestTimer?.setEventHandler {}
        conn.requestTimer?.cancel()
        conn.requestTimer = nil
        conn.nw.cancel()
        self.connections.removeValue(forKey: ObjectIdentifier(conn))
    }

    private func armRequestTimer(_ conn: HTTPConnection) {
        conn.requestTimer?.setEventHandler {}
        conn.requestTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: self.controlQueue)
        timer.schedule(deadline: .now() + Self.requestTimeout, repeating: .never)
        timer.setEventHandler { [weak self, weak conn] in
            guard let self, let conn, !conn.closed else { return }
            if conn.draining || conn.awaitingDeferredResponse {
                self.armRequestTimer(conn)
                return
            }
            self.removeConnection(conn)
        }
        conn.requestTimer = timer
        timer.resume()
    }

    private func receiveLoop(_ conn: HTTPConnection) {
        conn.nw.receive(minimumIncompleteLength: 1, maximumLength: Self.bodyCap + Self.headerBlockCap) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, !conn.closed else { return }

            if error != nil {
                self.removeConnection(conn)
                return
            }

            if let data, !data.isEmpty {
                if conn.draining {
                } else {
                    conn.buffer.append(data)
                    if conn.awaitingDeferredResponse {
                        if conn.buffer.count > Self.headerBlockCap + Self.bodyCap {
                            _ = self.protocolViolation(conn)
                            return
                        }
                    } else if !self.processBuffer(conn) {
                        return
                    }
                }
            }

            if isComplete {
                self.removeConnection(conn)
                return
            }

            self.receiveLoop(conn)
        }
    }

    @discardableResult
    private func processBuffer(_ conn: HTTPConnection) -> Bool {
        while true {
            guard let headerEnd = Self.findHeaderEnd(conn.buffer) else {
                if conn.buffer.count > Self.headerBlockCap {
                    return self.protocolViolation(conn)
                }
                return true
            }
            if headerEnd - 4 > Self.headerBlockCap {
                return self.protocolViolation(conn)
            }

            guard let request = self.parseRequest(Data(conn.buffer.prefix(headerEnd))) else {
                return self.protocolViolation(conn)
            }
            if request.headers["transfer-encoding"] != nil {
                return self.protocolViolation(conn)
            }
            guard let clString = request.headers["content-length"],
                  let contentLength = Int(clString), contentLength >= 0 else {
                return self.protocolViolation(conn)
            }
            if contentLength > Self.bodyCap {
                return self.protocolViolation(conn)
            }

            let bodyEnd = headerEnd + contentLength
            guard conn.buffer.count >= bodyEnd else { return true } // await full body

            let body = conn.buffer.subdata(in: headerEnd..<bodyEnd)
            conn.buffer = Data(conn.buffer[bodyEnd...])

            guard request.method == "POST" else { return self.protocolViolation(conn) }
            self.dispatch(conn, path: request.path, headers: request.headers, body: body)
            self.armRequestTimer(conn)

            if conn.closed { return false }
            if conn.draining { return true }
            if conn.awaitingDeferredResponse { return true }
        }
    }

    private static func findHeaderEnd(_ data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = bytes.count
            while i + 3 < n {
                if bytes[i] == 13, bytes[i + 1] == 10, bytes[i + 2] == 13, bytes[i + 3] == 10 {
                    return i + 4
                }
                i += 1
            }
            return nil
        }
    }

    private func parseRequest(_ headerData: Data) -> (method: String, path: String, headers: [String: String])? {
        guard let text = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "content-length", let existing = headers[key], existing != value {
                return nil
            }
            headers[key] = value
        }
        let path = target.split(separator: "?").first.map(String.init) ?? target
        return (method, path, headers)
    }

    /// Rate-limited: the cause strings leak nothing, but an unauthenticated peer could spam them.
    private func sendForbidden(_ conn: HTTPConnection, cause: String) {
        let now = Date()
        if let last = self.lastForbiddenLogAt, now.timeIntervalSince(last) < Self.forbiddenLogMinInterval {
            self.suppressedForbiddenCount += 1
        } else {
            let suffix = self.suppressedForbiddenCount > 0 ? " (+\(self.suppressedForbiddenCount) suppressed)" : ""
            DebugLogger.shared.info(
                "Remote mic: rejected request (403, \(cause))\(suffix)",
                source: "RemoteAudioHTTPIngest"
            )
            self.lastForbiddenLogAt = now
            self.suppressedForbiddenCount = 0
        }
        self.sendResponse(conn, status: 403, reason: "Forbidden", json: ["error": "forbidden"])
    }

    private static func peerIP(_ connection: NWConnection) -> String {
        guard case let .hostPort(host, _) = connection.endpoint else { return "unknown" }
        switch host {
        case let .ipv4(address): return "\(address)"
        case let .ipv6(address): return "\(address)"
        default: return "\(host)"
        }
    }

    private func dispatch(_ conn: HTTPConnection, path: String, headers: [String: String], body: Data) {
        switch path {
        case "/start":
            self.handleStartRequest(conn, headers: headers, body: body)
        case "/chunk":
            self.handleChunkRequest(conn, headers: headers, body: body)
        case "/stop":
            self.handleStopRequest(conn, headers: headers, body: body)
        case "/pair/hello":
            self.handlePairHelloRequest(conn, body: body)
        case "/pair/reveal":
            self.handlePairRevealRequest(conn, body: body)
        case "/pair/confirm":
            self.handlePairConfirmRequest(conn, body: body)
        case "/device/revoke":
            self.handleDeviceRevokeRequest(conn, headers: headers, body: body)
        default:
            self.sendResponse(conn, status: 404, reason: "Not Found", json: ["error": "not found"])
        }
    }

    /// Pairing predates the token, so these routes aren't AEAD-gated; the window bounds them.
    private func handlePairHelloRequest(_ conn: HTTPConnection, body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let phoneKeyB64 = obj["pk"] as? String,
              let phonePublicKey = RemoteMicCredentials.base64URLDecode(phoneKeyB64),
              phonePublicKey.count == 32
        else {
            self.sendForbidden(conn, cause: "/pair/hello malformed public key")
            return
        }

        let deviceName = (obj["name"] as? String).map { String($0.prefix(64)) } ?? "device"
        // Allowlist: absent -> "phone"; anything outside {"phone", "watch"} is refused outright.
        let kind = (obj["kind"] as? String) ?? "phone"
        guard kind == "phone" || kind == "watch" else {
            self.sendForbidden(conn, cause: "/pair/hello unsupported kind")
            return
        }
        let parentID = obj["parent"] as? String
        let peerIP = Self.peerIP(conn.nw)
        switch RemoteMicPairing.shared.beginAttempt(
            phonePublicKey: phonePublicKey,
            deviceName: deviceName,
            peerIP: peerIP,
            kind: kind,
            parentID: parentID
        ) {
        case let .ok(macPublicKey, commitment):
            self.sendResponse(
                conn,
                status: 200,
                reason: "OK",
                json: [
                    "pk": RemoteMicCredentials.base64URLEncode(macPublicKey),
                    "commit": RemoteMicCredentials.base64URLEncode(commitment),
                ]
            )
        case .rejected:
            self.sendForbidden(conn, cause: "/pair/hello rejected (no open window, rate-limited, or bad key)")
        }
    }

    private func handlePairRevealRequest(_ conn: HTTPConnection, body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let phoneNonceB64 = obj["np"] as? String,
              let phoneNonce = RemoteMicCredentials.base64URLDecode(phoneNonceB64),
              phoneNonce.count == 16
        else {
            self.sendForbidden(conn, cause: "/pair/reveal malformed nonce or wrong state")
            return
        }
        let peerIP = Self.peerIP(conn.nw)
        switch RemoteMicPairing.shared.reveal(phoneNonce: phoneNonce, peerIP: peerIP) {
        case let .ok(macNonce):
            self.sendResponse(
                conn,
                status: 200,
                reason: "OK",
                json: ["nm": RemoteMicCredentials.base64URLEncode(macNonce)]
            )
        case .peerMismatch:
            self.sendForbidden(conn, cause: "/pair/reveal from unexpected peer")
        case .rejected:
            self.sendForbidden(conn, cause: "/pair/reveal malformed nonce or wrong state")
        }
    }

    private func handlePairConfirmRequest(_ conn: HTTPConnection, body: Data) {
        let peerIP = Self.peerIP(conn.nw)
        switch RemoteMicPairing.shared.completeAttempt(sealedConfirmation: body, peerIP: peerIP) {
        case .pending:
            self.sendResponse(conn, status: 202, reason: "Accepted", json: ["pending": true])
        case let .granted(sealedGrant):
            DebugLogger.shared.info("Remote mic: device paired", source: "RemoteAudioHTTPIngest")
            self.sendResponse(
                conn,
                status: 200,
                reason: "OK",
                json: ["grant": RemoteMicCredentials.base64URLEncode(sealedGrant)]
            )
        case .peerMismatch:
            self.sendForbidden(conn, cause: "/pair/confirm from unexpected peer")
        case .rejected:
            self.sendForbidden(conn, cause: "/pair/confirm failed to open (digits mismatch or expired)")
        }
    }

    /// Auth mirrors `/start`. The response is plaintext: sealing it under a client-nonce-derived
    /// key would reuse a (key, nonce) pair.
    private func handleDeviceRevokeRequest(_ conn: HTTPConnection, headers: [String: String], body: Data) {
        guard
            let nonceB64 = headers["x-nonce"],
            let clientNonce = RemoteMicCredentials.base64URLDecode(nonceB64),
            clientNonce.count == Self.clientNonceByteCount
        else {
            self.sendForbidden(conn, cause: "malformed or missing X-Nonce")
            return
        }

        let credentials = RemoteMicCredentials.shared
        guard let deviceID = headers["x-device-id"] else {
            self.sendForbidden(conn, cause: "/device/revoke missing X-Device-ID")
            return
        }
        guard let tokenBytes = credentials.deviceTokenBytes(deviceID: deviceID) else {
            self.sendForbidden(conn, cause: "/device/revoke unknown or already-revoked deviceID")
            return
        }
        let requestKey = RemoteMicCrypto.startKey(tokenBytes: tokenBytes, clientNonce: clientNonce)
        guard
            let plaintext = try? RemoteMicCrypto.open(
                wireBody: body,
                key: requestKey,
                domain: .revoke,
                counter: 0,
                aad: Data()
            ),
            let obj = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
            let ts = (obj["ts"] as? NSNumber)?.doubleValue
        else {
            self.sendForbidden(conn, cause: "/device/revoke AEAD open failed (token mismatch or corrupt body)")
            return
        }
        guard let bodyDeviceID = obj["d"] as? String, bodyDeviceID == deviceID else {
            self.sendForbidden(conn, cause: "/device/revoke deviceID header/body mismatch")
            return
        }
        guard abs(Date().timeIntervalSince1970 - ts) <= Self.startReplayWindowSeconds else {
            self.sendForbidden(conn, cause: "/device/revoke outside replay window (client clock skew?)")
            return
        }
        self.pruneStartNonces()
        guard self.seenStartNonces[clientNonce] == nil else {
            self.sendForbidden(conn, cause: "/device/revoke replayed client nonce")
            return
        }
        self.seenStartNonces[clientNonce] = Date()

        credentials.revokeDevice(id: deviceID)
        DebugLogger.shared.info("Remote mic: device revoked via /device/revoke", source: "RemoteAudioHTTPIngest")
        self.sendResponse(conn, status: 200, reason: "OK", json: ["revoked": true])
    }

    private func handleStartRequest(_ conn: HTTPConnection, headers: [String: String], body: Data) {
        // Auth before the busy check, so a bad credential can't probe whether a session is armed.
        guard
            let nonceB64 = headers["x-nonce"],
            let clientNonce = RemoteMicCredentials.base64URLDecode(nonceB64),
            clientNonce.count == Self.clientNonceByteCount
        else {
            self.sendForbidden(conn, cause: "malformed or missing X-Nonce")
            return
        }

        let credentials = RemoteMicCredentials.shared
        // Every client must name a device (spec §4): the master token is a derivation secret, never
        // a usable credential, so a revoked or unlisted device has no way in.
        guard let deviceID = headers["x-device-id"] else {
            self.sendForbidden(conn, cause: "/start missing X-Device-ID; re-pair this device")
            return
        }
        guard let tokenBytes = credentials.deviceTokenBytes(deviceID: deviceID) else {
            self.sendForbidden(conn, cause: "/start unknown or revoked deviceID")
            return
        }
        let startKey = RemoteMicCrypto.startKey(tokenBytes: tokenBytes, clientNonce: clientNonce)
        guard
            let plaintext = try? RemoteMicCrypto.open(
                wireBody: body,
                key: startKey,
                domain: .start,
                counter: 0,
                aad: Data()
            ),
            let obj = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
            let ts = (obj["ts"] as? NSNumber)?.doubleValue,
            let requestEpoch = (obj["e"] as? NSNumber)?.intValue
        else {
            self.sendForbidden(conn, cause: "/start AEAD open failed (token mismatch or corrupt body)")
            return
        }
        // Binds header key-selection to the authenticated body. The body must now carry `d`: a
        // missing one would leave the cleartext header unauthenticated.
        guard let bodyDeviceID = obj["d"] as? String, bodyDeviceID == deviceID else {
            self.sendForbidden(conn, cause: "/start deviceID header/body mismatch")
            return
        }

        guard abs(Date().timeIntervalSince1970 - ts) <= Self.startReplayWindowSeconds else {
            self.sendForbidden(conn, cause: "/start outside replay window (client clock skew?)")
            return
        }
        guard requestEpoch == credentials.epoch else {
            DebugLogger.shared.info(
                "Remote mic: rejected /start (403, stale epoch \(requestEpoch) vs \(credentials.epoch)); client must re-pair",
                source: "RemoteAudioHTTPIngest"
            )
            self.sendResponse(conn, status: 403, reason: "Forbidden", json: ["error": "stale-credentials"])
            return
        }
        self.pruneStartNonces()
        guard self.seenStartNonces[clientNonce] == nil else {
            self.sendForbidden(conn, cause: "/start replayed client nonce")
            return
        }

        if self.currentSessionID != nil {
            self.sendResponse(conn, status: 409, reason: "Conflict", json: ["error": "busy"])
            return
        }

        // Recorded only once accepted: a client retrying the identical sealed /start after a 409
        // must not be permanently locked out by its own earlier attempt.
        self.seenStartNonces[clientNonce] = Date()

        let sessionID = UUID().uuidString
        self.currentSessionID = sessionID
        self.currentDeviceID = deviceID
        self.sessionKey = RemoteMicCrypto.sessionKey(tokenBytes: tokenBytes, sessionID: sessionID)
        self.arming = true
        self.armed = false
        self.hasOpenSession = false
        self.stopInProgress = false
        self.generation = 0
        self.ingestClosure = nil
        self.sampleOffset = 0
        self.reorder.removeAll(keepingCapacity: true)
        self.lastForwarded = -1
        self.gapSince = nil
        stateLock.lock()
        self.sessionActive = false
        stateLock.unlock()

        self.armIdleTimer()
        conn.awaitingDeferredResponse = true

        let handlers = self.handlers
        Task {
            let outcome = await handlers.onStartRequested()
            self.controlQueue.async {
                self.handleArmOutcome(outcome, sessionID: sessionID, conn: conn)
            }
        }
    }

    private func handleArmOutcome(_ outcome: RemoteMicSession.ArmOutcome, sessionID: String, conn: HTTPConnection) {
        let isCurrent = self.currentSessionID == sessionID && self.arming
        guard isCurrent else {
            if case .armed = outcome {
                let handlers = self.handlers
                Task { await handlers.onAbnormalDisconnect() }
            }
            self.resolveDeferredResponse(conn, status: 409, reason: "Conflict", json: ["error": "invalidated"])
            return
        }

        switch outcome {
        case let .armed(generation, ingest):
            self.generation = generation
            self.ingestClosure = ingest
            self.hasOpenSession = true
            self.arming = false
            self.armed = true
            stateLock.lock()
            self.sessionActive = true
            stateLock.unlock()
            self.startMaxSessionTimer()
            self.armIdleTimer()
            self.resolveDeferredResponse(conn, status: 200, reason: "OK", json: ["armed": true, "session": sessionID])

        case let .rejected(reason):
            self.clearSessionFieldsLocked(fireAbnormal: false)
            // "expired" is terminal (the Mac turned Remote Mic off / it timed out) — 410 Gone tells
            // the client to stop retrying and surface "Remote Mic is off", instead of the 409
            // "busy, try again" a client would otherwise reasonably retry.
            if reason == "expired" {
                self.resolveDeferredResponse(conn, status: 410, reason: "Gone", json: ["error": reason])
            } else {
                self.resolveDeferredResponse(conn, status: 409, reason: "Conflict", json: ["error": reason])
            }
        }
    }

    private func resolveDeferredResponse(_ conn: HTTPConnection, status: Int, reason: String, json: [String: Any]) {
        conn.awaitingDeferredResponse = false
        self.sendResponse(conn, status: status, reason: reason, json: json)
        if !conn.closed, !conn.draining, !conn.buffer.isEmpty {
            _ = self.processBuffer(conn)
        }
    }

    private func handleChunkRequest(_ conn: HTTPConnection, headers: [String: String], body: Data) {
        if let session = headers["x-session"], session != self.currentSessionID {
            self.sendResponse(conn, status: 200, reason: "OK", json: ["ok": true])
            return
        }
        guard self.currentSessionID != nil, self.armed, let sessionKey = self.sessionKey else {
            self.sendResponse(conn, status: 200, reason: "OK", json: ["ok": true])
            return
        }

        let seq = Int(headers["x-seq"] ?? "") ?? -1
        guard seq >= 0, seq <= Self.maxPlausibleSeq else {
            self.sendForbidden(conn, cause: "/chunk implausible X-Seq")
            return
        }
        // A decrypt failure (bad/missing seq, tampered body, wrong token) rejects only this
        // chunk — the session is NOT torn down, so one corrupt chunk can't kill dictation.
        guard
            let sessionID = self.currentSessionID,
            let plaintext = try? RemoteMicCrypto.open(
                wireBody: body,
                key: sessionKey,
                domain: .chunk,
                counter: UInt64(seq),
                aad: Data(sessionID.utf8)
            )
        else {
            self.sendForbidden(conn, cause: "/chunk AEAD open failed or no armed session")
            return
        }

        self.sendResponse(conn, status: 200, reason: "OK", json: ["ok": true])

        if !self.stopInProgress {
            self.armIdleTimer()
        }

        var pcm = plaintext
        if pcm.count % 2 != 0 {
            pcm = pcm.subdata(in: 0..<(pcm.count - 1))
        }
        guard !pcm.isEmpty else { return }
        if seq <= self.lastForwarded { return } // dup / stale

        self.reorder[seq] = pcm
        self.drainLocked()

        if !self.reorder.isEmpty {
            if self.gapSince == nil { self.gapSince = DispatchTime.now() }
            let overCap = self.reorder.count > Self.maxHeldChunks
            let staleGap = Self.elapsedMs(since: self.gapSince) > Self.gapSkipMs
            if overCap || staleGap {
                self.skipGapLocked()
                self.drainLocked()
            }
        }
    }

    /// controlQueue ONLY: decides order and computes `sampleOffset` synchronously, handing
    /// `ingestQueue` a precomputed offset. The async block never touches session state.
    private func drainLocked() {
        var next = self.lastForwarded &+ 1
        var advanced = false
        while let pcm = self.reorder[next] {
            // Backpressure: leave saturated chunks in the (bounded) reorder buffer and resume later.
            self.stateLock.lock()
            let inFlight = self.ingestInFlight
            self.stateLock.unlock()
            if inFlight >= Self.maxInFlightIngest { break }

            self.reorder.removeValue(forKey: next)
            let sampleCount = pcm.count / 2
            let offset = self.sampleOffset
            self.sampleOffset = offset + Int64(sampleCount)
            let generation = self.generation
            let ingest = self.ingestClosure
            self.stateLock.lock()
            self.ingestInFlight += 1
            self.stateLock.unlock()
            self.ingestQueue.async { [weak self] in
                guard let self else { return }
                defer {
                    self.stateLock.lock()
                    self.ingestInFlight -= 1
                    self.stateLock.unlock()
                }
                let samples = Self.convertInt16LEToFloat(pcm)
                guard !samples.isEmpty else { return }
                self.stateLock.lock()
                let accept = self.sessionActive
                self.stateLock.unlock()
                guard accept else { return }
                ingest?(samples, Self.sampleRate, generation, offset)
            }
            self.lastForwarded = next
            next &+= 1
            advanced = true
        }
        if self.reorder.isEmpty {
            self.gapSince = nil
        } else if advanced {
            self.gapSince = DispatchTime.now()
        }
    }

    private func skipGapLocked() {
        guard let smallest = self.reorder.keys.min() else { return }
        self.lastForwarded = smallest &- 1 // skip the permanently-missing seq(s)
        self.gapSince = nil
    }

    private func handleStopRequest(_ conn: HTTPConnection, headers: [String: String], body: Data) {
        if let session = headers["x-session"], session != self.currentSessionID {
            self.sendResponse(conn, status: 200, reason: "OK", json: ["didType": false])
            return
        }
        guard self.currentSessionID != nil, !self.stopInProgress else {
            self.sendResponse(conn, status: 200, reason: "OK", json: ["didType": false])
            return
        }

        guard
            let sessionKey = self.sessionKey,
            let sessionID = self.currentSessionID,
            let plaintext = try? RemoteMicCrypto.open(
                wireBody: body,
                key: sessionKey,
                domain: .stop,
                counter: 0,
                aad: Data(sessionID.utf8)
            )
        else {
            self.sendForbidden(conn, cause: "/stop AEAD open failed or no armed session")
            return
        }

        let (lastSeq, stopRequest) = Self.parseStopBody(plaintext)

        // Cancel both watchdogs BEFORE awaiting: `onStopRequested` can run ~120 s with no traffic,
        // and a racing abnormal stop would crack the remote finalization window.
        self.cancelIdleTimer()
        self.cancelMaxSessionTimer()

        self.stopInProgress = true
        conn.draining = true
        conn.buffer.removeAll(keepingCapacity: false)

        if !self.armed {
            self.clearSessionFieldsLocked(fireAbnormal: false)
            conn.draining = false
            self.sendResponse(conn, status: 200, reason: "OK", json: ["didType": false])
            return
        }

        self.startStopGrace(lastSeq: lastSeq, request: stopRequest, conn: conn)
    }

    private func startStopGrace(lastSeq: Int?, request: RemoteMicSession.StopRequest, conn: HTTPConnection) {
        self.cancelStopGraceTimer()
        let deadline = DispatchTime.now() + .milliseconds(Self.stopGraceMs)
        let timer = DispatchSource.makeTimerSource(queue: self.controlQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(Self.stopGraceTickMs),
            repeating: .milliseconds(Self.stopGraceTickMs)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.drainLocked()
            let satisfied = lastSeq == nil || self.lastForwarded >= lastSeq!
            if satisfied || DispatchTime.now() >= deadline {
                self.cancelStopGraceTimer()
                self.finalizeStop(request: request, conn: conn)
            }
        }
        self.stopGraceTimer = timer
        timer.resume()
    }

    private func finalizeStop(request: RemoteMicSession.StopRequest, conn: HTTPConnection) {
        while !self.reorder.isEmpty {
            self.skipGapLocked()
            self.drainLocked()
        }
        self.ingestQueue.sync {}

        stateLock.lock()
        self.sessionActive = false
        stateLock.unlock()
        self.hasOpenSession = false

        let finalizingSessionID = self.currentSessionID
        self.startStopFailsafeTimer(sessionID: finalizingSessionID, conn: conn)

        let handlers = self.handlers
        Task {
            let didType = await handlers.onStopRequested(request)
            self.controlQueue.async {
                self.sendResponse(conn, status: 200, reason: "OK", json: ["didType": didType])
                conn.draining = false
                guard self.currentSessionID == finalizingSessionID else { return }
                self.cancelStopFailsafeTimer()
                self.currentSessionID = nil
                self.currentDeviceID = nil
                self.arming = false
                self.armed = false
                self.stopInProgress = false
                self.ingestClosure = nil
                self.sessionKey = nil
                self.generation = 0
                self.sampleOffset = 0
                self.reorder.removeAll(keepingCapacity: false)
                self.lastForwarded = -1
                self.gapSince = nil
            }
        }
    }

    private func startStopFailsafeTimer(sessionID: String?, conn: HTTPConnection) {
        self.cancelStopFailsafeTimer()
        let timer = DispatchSource.makeTimerSource(queue: self.controlQueue)
        timer.schedule(deadline: .now() + Self.stopFinalizeFailsafe, repeating: .never)
        timer.setEventHandler { [weak self, weak conn] in
            guard let self, self.stopInProgress, self.currentSessionID == sessionID else { return }
            DebugLogger.shared.error(
                "Remote audio HTTP stop finalization timed out; releasing session",
                source: "RemoteAudioHTTPIngest"
            )
            if let conn {
                self.sendResponse(conn, status: 200, reason: "OK", json: ["didType": false])
                conn.draining = false
                self.removeConnection(conn)
            }
            self.clearSessionFieldsLocked(fireAbnormal: false)
        }
        self.stopFailsafeTimer = timer
        timer.resume()
    }

    private func cancelStopFailsafeTimer() {
        self.stopFailsafeTimer?.setEventHandler {}
        self.stopFailsafeTimer?.cancel()
        self.stopFailsafeTimer = nil
    }

    /// Clears session state. Fires `onAbnormalDisconnect` only when this source owns the session.
    private func clearSessionFieldsLocked(fireAbnormal: Bool) {
        self.cancelIdleTimer()
        self.cancelMaxSessionTimer()
        self.cancelStopGraceTimer()
        self.cancelStopFailsafeTimer()

        let shouldFire = fireAbnormal && self.hasOpenSession
        self.hasOpenSession = false
        stateLock.lock()
        self.sessionActive = false
        stateLock.unlock()

        self.currentSessionID = nil
        self.currentDeviceID = nil
        self.arming = false
        self.armed = false
        self.stopInProgress = false
        self.ingestClosure = nil
        self.sessionKey = nil
        self.generation = 0
        self.sampleOffset = 0
        self.reorder.removeAll(keepingCapacity: false)
        self.lastForwarded = -1
        self.gapSince = nil

        if shouldFire {
            let handlers = self.handlers
            Task { await handlers.onAbnormalDisconnect() }
        }
    }

    private func sendResponse(_ conn: HTTPConnection, status: Int, reason: String, json: [String: Any], close: Bool = false) {
        guard let body = try? JSONSerialization.data(withJSONObject: json, options: []) else { return }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(close ? "close" : "keep-alive")\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.nw.send(content: out, completion: .contentProcessed { [weak self, weak conn] _ in
            guard let conn else { return }
            if close {
                self?.removeConnection(conn)
            }
        })
    }

    private func protocolViolation(_ conn: HTTPConnection) -> Bool {
        self.sendResponse(conn, status: 400, reason: "Bad Request", json: ["error": "bad request"])
        self.removeConnection(conn)
        return false
    }

    private func armIdleTimer() {
        self.cancelIdleTimer()
        let timer = DispatchSource.makeTimerSource(queue: self.controlQueue)
        timer.schedule(deadline: .now() + Self.idleTimeout, repeating: .never)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DebugLogger.shared.info("Remote audio HTTP idle timeout; discarding session", source: "RemoteAudioHTTPIngest")
            self.clearSessionFieldsLocked(fireAbnormal: true)
        }
        self.idleTimer = timer
        timer.resume()
    }

    private func cancelIdleTimer() {
        self.idleTimer?.setEventHandler {}
        self.idleTimer?.cancel()
        self.idleTimer = nil
    }

    private func startMaxSessionTimer() {
        self.cancelMaxSessionTimer()
        let timer = DispatchSource.makeTimerSource(queue: self.controlQueue)
        timer.schedule(deadline: .now() + Self.maxSessionDuration, repeating: .never)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DebugLogger.shared.info("Remote audio HTTP max session reached; discarding session", source: "RemoteAudioHTTPIngest")
            self.clearSessionFieldsLocked(fireAbnormal: true)
        }
        self.maxSessionTimer = timer
        timer.resume()
    }

    private func cancelMaxSessionTimer() {
        self.maxSessionTimer?.setEventHandler {}
        self.maxSessionTimer?.cancel()
        self.maxSessionTimer = nil
    }

    private func cancelStopGraceTimer() {
        self.stopGraceTimer?.setEventHandler {}
        self.stopGraceTimer?.cancel()
        self.stopGraceTimer = nil
    }

    private func pruneStartNonces() {
        let cutoff = Date().addingTimeInterval(-Self.startNonceCacheRetention)
        self.seenStartNonces = self.seenStartNonces.filter { $0.value >= cutoff }
    }

    private static func elapsedMs(since time: DispatchTime?) -> Double {
        guard let time else { return 0 }
        let now = DispatchTime.now()
        guard now > time else { return 0 }
        return Double(now.uptimeNanoseconds - time.uptimeNanoseconds) / 1_000_000
    }

    /// Absent/unknown `m` -> `.dictate`; absent `ai` -> `false`. Both preserve today's behaviour
    /// exactly when the fields are missing, so older clients are unaffected. Internal (not
    /// private) so the `/stop` body matrix can be unit-tested directly.
    static func parseStopBody(_ body: Data) -> (lastSeq: Int?, request: RemoteMicSession.StopRequest) {
        guard !body.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return (nil, RemoteMicSession.StopRequest(mode: .dictate, aiRequested: false))
        }
        let lastSeq = (obj["lastSeq"] as? NSNumber)?.intValue
        let mode = (obj["m"] as? String).flatMap(RemoteMicSession.StopMode.init(rawValue:)) ?? .dictate
        let aiRequested = (obj["ai"] as? NSNumber)?.boolValue ?? false
        return (lastSeq, RemoteMicSession.StopRequest(mode: mode, aiRequested: aiRequested))
    }

    private static func convertInt16LEToFloat(_ data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        var result = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { raw in
            for i in 0..<sampleCount {
                let value = UInt16(
                    littleEndian: raw.loadUnaligned(
                        fromByteOffset: i * MemoryLayout<Int16>.size,
                        as: UInt16.self
                    )
                )
                result[i] = Float(Int16(bitPattern: value)) / 32_768.0
            }
        }
        return result
    }

}

private enum RemoteAudioHTTPIngestError: Error, LocalizedError {
    case invalidPort(UInt16)

    var errorDescription: String? {
        switch self {
        case let .invalidPort(port):
            return "Invalid remote audio HTTP port: \(port)"
        }
    }
}
#endif
