#if DEBUG
import AppKit
import Combine
import Foundation
import Network

extension Notification.Name {
    static let remoteMicSettingsDidChange = Notification.Name("com.fluidvoice.remoteMicSettingsDidChange")
}

/// Owns auto-off policy for the DEBUG-only remote mic listener. `isActive` is the single authority
/// `ASRService` gates on. Computed fresh rather than cached so a missed timer fails closed.
@MainActor
final class RemoteMicController: ObservableObject {
    static let shared = RemoteMicController()

    private static let hardCapDuration: TimeInterval = 12 * 60 * 60
    private static let periodicRecheckInterval: TimeInterval = 30
    private static let pendingTeardownPollInterval: TimeInterval = 5
    /// Sized above `stopFinalizeFailsafe` (150s): a hung `/stop` fires no handler to release the poll.
    /// `onAbnormalDisconnect` nor the finalize handler, so nothing else would release the poll.
    private static let forceTeardownGraceAfterExpiry: TimeInterval = 5 * 60
    /// The legacy loopback-only flag would bind wildcard with no deadline; force a one-time disable.
    /// wildcard with no deadline. Presence of this key forces a one-time disable.
    private static let legacyAllowLANDefaultsKey = "RemoteMicAllowLAN"

    @Published private(set) var isListenerBound: Bool = false
    @Published private(set) var bindError: String?

    /// `ContinuousClock` advances during sleep; expiry fires on whichever clock passes first.
    /// whichever clock passes first. In memory only, re-derived at launch.
    private var idleDeadlineMonotonic: ContinuousClock.Instant?
    private var hardCapDeadlineMonotonic: ContinuousClock.Instant?

    private(set) var pendingTeardown = false
    private var expiredAt: Date?

    private var expiryTimer: Timer?
    private var periodicRecheckTimer: Timer?
    private var pendingTeardownTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var enabledNetworkIdentity: NetworkIdentity?

    /// Closures rather than a delegate, to avoid a retain cycle with the `ASRService` singleton.
    private var sessionInFlightProvider: (() -> Bool)?
    private var forceTeardownHandler: (() async -> Void)?

    private init() {}

    /// Only the primary interface identifies the network. Virtual interfaces that churn in normal
    /// use (`awdl0` AirDrop, `utun*` VPN, `llw*`) are filtered out so they can't fire a false disable.
    /// interfaces that churn constantly during normal use — AirDrop/Handoff's `awdl0`, VPN `utun*`,
    struct NetworkIdentity: Equatable {
        let primaryInterfaceIdentity: String

        private static func isChurnyVirtualInterface(_ name: String) -> Bool {
            name == "awdl0" || name.hasPrefix("utun") || name.hasPrefix("llw")
        }

        init(path: NWPath) {
            let real = path.availableInterfaces.first { !Self.isChurnyVirtualInterface($0.name) }
            self.primaryInterfaceIdentity = real.map { "\($0.type)|\($0.name)" } ?? "none"
        }
    }

    var isActive: Bool {
        SettingsStore.shared.remoteMicEnabled && !self.isExpired
    }

    private var isExpired: Bool {
        guard SettingsStore.shared.remoteMicEnabled else { return true }

        if SettingsStore.shared.remoteMicIdleTimeout == .never {
            return false
        }

        let now = Date()
        if let wallIdle = SettingsStore.shared.remoteMicIdleDeadline, now >= wallIdle { return true }
        if let wallHard = SettingsStore.shared.remoteMicHardCapDeadline, now >= wallHard { return true }
        if let monoIdle = self.idleDeadlineMonotonic, ContinuousClock.now >= monoIdle { return true }
        if let monoHard = self.hardCapDeadlineMonotonic, ContinuousClock.now >= monoHard { return true }

        if SettingsStore.shared.remoteMicIdleDeadline == nil, SettingsStore.shared.remoteMicHardCapDeadline == nil {
            return true
        }
        return false
    }

    /// Must run before `ASRService` builds a listener, so an expired `enabled=true` never reconciles.
    /// from a previous run never reaches the reconcile.
    func performLaunchSequence(
        sessionInFlightProvider: @escaping () -> Bool,
        forceTeardown: @escaping () async -> Void
    ) {
        self.sessionInFlightProvider = sessionInFlightProvider
        self.forceTeardownHandler = forceTeardown
        self.registerWakeObserver()

        self.runLegacyMigrationIfNeeded()

        guard SettingsStore.shared.remoteMicEnabled else { return }

        if SettingsStore.shared.remoteMicIdleTimeout != .never {
            let now = Date()
            if let wallIdle = SettingsStore.shared.remoteMicIdleDeadline {
                let remaining = max(0, wallIdle.timeIntervalSince(now))
                self.idleDeadlineMonotonic = ContinuousClock.now.advanced(by: .seconds(Int(remaining.rounded(.up))))
            }
            if let wallHard = SettingsStore.shared.remoteMicHardCapDeadline {
                let remaining = max(0, wallHard.timeIntervalSince(now))
                self.hardCapDeadlineMonotonic = ContinuousClock.now.advanced(by: .seconds(Int(remaining.rounded(.up))))
            }
        }

        self.checkExpiry()

        guard SettingsStore.shared.remoteMicEnabled else { return }
        self.enabledNetworkIdentity = nil
        self.startNetworkMonitoring()
        self.startPeriodicRecheckIfNeeded()
        self.rescheduleExpiryTimer()
    }

    private func runLegacyMigrationIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.legacyAllowLANDefaultsKey) != nil else { return }

        DebugLogger.shared.info(
            "Remote mic: legacy 'RemoteMicAllowLAN' key found; forcing disabled and clearing deadlines (one-time migration)",
            source: "RemoteMicController"
        )
        SettingsStore.shared.remoteMicEnabled = false
        SettingsStore.shared.remoteMicIdleDeadline = nil
        SettingsStore.shared.remoteMicHardCapDeadline = nil
        defaults.removeObject(forKey: Self.legacyAllowLANDefaultsKey)
    }

    /// Idempotent: resetting deadlines here would let a re-evaluated SwiftUI binding defeat the cap.
    func enable() {
        guard !self.isActive else { return }

        self.pendingTeardown = false
        self.expiredAt = nil
        self.pendingTeardownTimer?.invalidate()
        self.pendingTeardownTimer = nil

        let timeout = SettingsStore.shared.remoteMicIdleTimeout
        let now = Date()
        if let minutes = timeout.minutes {
            let idleWall = now.addingTimeInterval(TimeInterval(minutes * 60))
            let hardCapWall = now.addingTimeInterval(Self.hardCapDuration)
            SettingsStore.shared.remoteMicIdleDeadline = idleWall
            SettingsStore.shared.remoteMicHardCapDeadline = hardCapWall
            self.idleDeadlineMonotonic = ContinuousClock.now.advanced(by: .seconds(minutes * 60))
            self.hardCapDeadlineMonotonic = ContinuousClock.now.advanced(by: .seconds(Int(Self.hardCapDuration)))
        } else {
            SettingsStore.shared.remoteMicIdleDeadline = nil
            SettingsStore.shared.remoteMicHardCapDeadline = nil
            self.idleDeadlineMonotonic = nil
            self.hardCapDeadlineMonotonic = nil
        }

        SettingsStore.shared.remoteMicEnabled = true

        self.enabledNetworkIdentity = nil
        self.startNetworkMonitoring()
        self.startPeriodicRecheckIfNeeded()
        self.rescheduleExpiryTimer()
        self.postSettingsChanged()
    }

    func disable() {
        guard SettingsStore.shared.remoteMicEnabled else { return }
        self.beginExpiryTeardown()
    }

    /// Recomputes deadlines from now. Without this a picker change would leave stale deadlines —
    func updateIdleTimeout(_ newValue: SettingsStore.RemoteMicIdleTimeout) {
        SettingsStore.shared.remoteMicIdleTimeout = newValue
        guard SettingsStore.shared.remoteMicEnabled else { return }

        if let minutes = newValue.minutes {
            let now = Date()
            let hardCapWall = SettingsStore.shared.remoteMicHardCapDeadline
                ?? now.addingTimeInterval(Self.hardCapDuration)
            let hardCapMono = self.hardCapDeadlineMonotonic
                ?? ContinuousClock.now.advanced(by: .seconds(Int(Self.hardCapDuration)))

            SettingsStore.shared.remoteMicHardCapDeadline = hardCapWall
            SettingsStore.shared.remoteMicIdleDeadline = min(
                now.addingTimeInterval(TimeInterval(minutes * 60)),
                hardCapWall
            )
            self.hardCapDeadlineMonotonic = hardCapMono
            self.idleDeadlineMonotonic = min(
                ContinuousClock.now.advanced(by: .seconds(minutes * 60)),
                hardCapMono
            )
        } else {
            SettingsStore.shared.remoteMicIdleDeadline = nil
            SettingsStore.shared.remoteMicHardCapDeadline = nil
            self.idleDeadlineMonotonic = nil
            self.hardCapDeadlineMonotonic = nil
        }

        self.rescheduleExpiryTimer()
        self.postSettingsChanged()
    }

    func noteSessionArmed() {
        guard SettingsStore.shared.remoteMicEnabled else { return }
        guard let minutes = SettingsStore.shared.remoteMicIdleTimeout.minutes else { return }

        let now = Date()
        let newIdleWall = now.addingTimeInterval(TimeInterval(minutes * 60))
        let hardCapWall = SettingsStore.shared.remoteMicHardCapDeadline ?? newIdleWall
        SettingsStore.shared.remoteMicIdleDeadline = min(newIdleWall, hardCapWall)

        let newIdleMono = ContinuousClock.now.advanced(by: .seconds(minutes * 60))
        if let hardCapMono = self.hardCapDeadlineMonotonic {
            self.idleDeadlineMonotonic = min(newIdleMono, hardCapMono)
        } else {
            self.idleDeadlineMonotonic = newIdleMono
        }

        self.rescheduleExpiryTimer()
    }

    func reportListenerBindResult(bound: Bool, error: String?) {
        self.isListenerBound = bound
        self.bindError = error
    }

    func invalidateAll() {
        self.expiryTimer?.invalidate()
        self.expiryTimer = nil
        self.periodicRecheckTimer?.invalidate()
        self.periodicRecheckTimer = nil
        self.pendingTeardownTimer?.invalidate()
        self.pendingTeardownTimer = nil
        self.stopNetworkMonitoring()
        if let observer = self.wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.wakeObserver = nil
        }
    }

    private func rescheduleExpiryTimer() {
        self.expiryTimer?.invalidate()
        self.expiryTimer = nil

        guard SettingsStore.shared.remoteMicEnabled else { return }
        guard SettingsStore.shared.remoteMicIdleTimeout != .never else { return }

        let deadlines = [
            SettingsStore.shared.remoteMicIdleDeadline,
            SettingsStore.shared.remoteMicHardCapDeadline,
        ].compactMap { $0 }
        guard let nextDeadline = deadlines.min() else { return }

        let interval = max(0.05, nextDeadline.timeIntervalSinceNow)
        self.expiryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkExpiry() }
        }
    }

    private func startPeriodicRecheckIfNeeded() {
        guard self.periodicRecheckTimer == nil else { return }
        self.periodicRecheckTimer = Timer.scheduledTimer(
            withTimeInterval: Self.periodicRecheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkExpiry() }
        }
    }

    private func stopPeriodicRecheck() {
        self.periodicRecheckTimer?.invalidate()
        self.periodicRecheckTimer = nil
    }

    private func registerWakeObserver() {
        guard self.wakeObserver == nil else { return }
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkExpiry() }
        }
    }

    private func checkExpiry() {
        guard SettingsStore.shared.remoteMicEnabled else {
            self.stopPeriodicRecheck()
            return
        }
        if self.isExpired {
            self.beginExpiryTeardown()
        } else {
            self.rescheduleExpiryTimer()
        }
    }

    private func beginExpiryTeardown() {
        if self.expiredAt == nil {
            self.expiredAt = Date()
            DebugLogger.shared.info("Remote mic expired; pending teardown", source: "RemoteMicController")
        }
        self.pendingTeardown = true

        let sessionInFlight = self.sessionInFlightProvider?() ?? false
        if sessionInFlight {
            self.schedulePendingTeardownPollIfNeeded()
        } else {
            self.finalizeTeardown()
        }
    }

    private func schedulePendingTeardownPollIfNeeded() {
        guard self.pendingTeardownTimer == nil else { return }
        self.pendingTeardownTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pendingTeardownPollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.pollPendingTeardown() }
        }
    }

    private func pollPendingTeardown() {
        guard self.pendingTeardown, let expiredAt = self.expiredAt else {
            self.pendingTeardownTimer?.invalidate()
            self.pendingTeardownTimer = nil
            return
        }

        let sessionInFlight = self.sessionInFlightProvider?() ?? false
        if !sessionInFlight {
            self.finalizeTeardown()
            return
        }

        if Date().timeIntervalSince(expiredAt) >= Self.forceTeardownGraceAfterExpiry {
            DebugLogger.shared.error(
                "Remote mic force teardown after grace period; session still in flight",
                source: "RemoteMicController"
            )
            let forceTeardownHandler = self.forceTeardownHandler
            Task { @MainActor in
                await forceTeardownHandler?()
                guard self.pendingTeardown else { return }
                self.finalizeTeardown()
            }
        }
    }

    private func finalizeTeardown() {
        self.pendingTeardownTimer?.invalidate()
        self.pendingTeardownTimer = nil
        self.expiryTimer?.invalidate()
        self.expiryTimer = nil
        self.stopPeriodicRecheck()
        self.stopNetworkMonitoring()

        self.pendingTeardown = false
        self.expiredAt = nil
        self.idleDeadlineMonotonic = nil
        self.hardCapDeadlineMonotonic = nil

        SettingsStore.shared.remoteMicEnabled = false
        SettingsStore.shared.remoteMicIdleDeadline = nil
        SettingsStore.shared.remoteMicHardCapDeadline = nil

        self.postSettingsChanged()
    }

    private func startNetworkMonitoring() {
        self.pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let identity = NetworkIdentity(path: path)
            Task { @MainActor in self?.handlePathUpdate(identity) }
        }
        monitor.start(queue: DispatchQueue(label: "remote-mic-path-monitor"))
        self.pathMonitor = monitor
    }

    private func stopNetworkMonitoring() {
        self.pathMonitor?.cancel()
        self.pathMonitor = nil
    }

    private func handlePathUpdate(_ identity: NetworkIdentity) {
        guard SettingsStore.shared.remoteMicEnabled else { return }
        guard let baseline = self.enabledNetworkIdentity else {
            self.enabledNetworkIdentity = identity
            return
        }
        guard identity != baseline else { return }

        DebugLogger.shared.info(
            "Remote mic: network identity changed (was \(baseline.primaryInterfaceIdentity), now \(identity.primaryInterfaceIdentity)); disabling",
            source: "RemoteMicController"
        )
        self.enabledNetworkIdentity = identity
        self.disable()
    }

    private func postSettingsChanged() {
        NotificationCenter.default.post(name: .remoteMicSettingsDidChange, object: nil)
    }
}
#endif
