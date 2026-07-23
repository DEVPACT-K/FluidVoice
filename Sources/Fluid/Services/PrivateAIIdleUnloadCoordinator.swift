import AppKit
import Foundation

/// Reasons reported by `PrivateAIIdleUnloadCoordinator` when it requests an unload.
nonisolated enum PrivateAIIdleUnloadReason {
    static let idleTimeout = "idle_timeout"
    static let memoryPressure = "memory_pressure"
    static let systemSleep = "system_sleep"
}

/// Abstracts the one-shot idle timer so the coordinator's deadline logic is
/// unit-testable without waiting on real wall-clock time. Production uses a
/// `DispatchSource` timer; tests inject a fake that fires on demand.
protocol PrivateAIIdleUnloadScheduling: Sendable {
    /// Schedule a single fire after `delay` seconds, cancelling any prior fire.
    func scheduleIdleFire(after delay: TimeInterval, action: @escaping @Sendable () -> Void)
    /// Cancel any pending fire.
    func cancelIdleFire()
}

/// Production idle scheduler backed by a one-shot `DispatchSource` timer on a
/// private serial queue.
final nonisolated class DispatchTimerIdleScheduler: PrivateAIIdleUnloadScheduling {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    init(queueLabel: String = "app.fluidvoice.private-ai-idle-unload.timer") {
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
    }

    func scheduleIdleFire(after delay: TimeInterval, action: @escaping @Sendable () -> Void) {
        self.lock.lock()
        self.timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: self.queue)
        source.schedule(deadline: .now() + max(delay, 0))
        source.setEventHandler(handler: action)
        source.resume()
        self.timer = source
        self.lock.unlock()
    }

    func cancelIdleFire() {
        self.lock.lock()
        self.timer?.cancel()
        self.timer = nil
        self.lock.unlock()
    }
}

/// Coordinates idle, memory-pressure, and system-sleep driven unloads of the
/// Fluid-1 post-processing runtime (issue #548).
///
/// The ~3.3 GB Fluid-1 runtime lives in a child helper process owned by the
/// private bridge. `PrivateAIIntegrationService.unloadCachedRuntime(reason:)`
/// fully tears the helper down, so this coordinator invokes that on the owning
/// actor when the runtime has been idle past a wall-clock deadline, under
/// memory pressure, or just before system sleep.
///
/// Mutual exclusion is enforced on this side (the bridge's concurrency contract
/// is not relied upon):
/// - The idle timer only fires the unload when no request is in flight; if it
///   fires mid-request it logs `skipped(in-flight)` and re-arms.
/// - `beginRequest()` awaits any in-progress unload before registering a new
///   request, so a provider call can never interleave with a running unload.
///
/// `endRequest()`, `noteActivity()`, and `cancel()` are synchronous so callers
/// can balance the in-flight counter with `defer { endRequest() }` across
/// throw/cancellation paths. `beginRequest()` is async because it may wait for
/// an unload to drain.
///
/// The idle deadline is tracked in wall-clock `Date` (not a monotonic clock) so
/// idle time accumulated across system sleep is honoured on wake; the sleep
/// observer additionally unloads immediately on `willSleepNotification`.
final nonisolated class PrivateAIIdleUnloadCoordinator: @unchecked Sendable {
    private static let logSource = "PrivateAIIdleUnload"
    private static let secondsPerMinute: TimeInterval = 60

    private let now: @Sendable () -> Date
    private let intervalProvider: @Sendable () -> Int
    private let onUnload: @Sendable (String) async -> Void
    private let scheduler: PrivateAIIdleUnloadScheduling
    private let monitorQueue = DispatchQueue(
        label: "app.fluidvoice.private-ai-idle-unload.monitor",
        qos: .utility
    )

    private let lock = NSLock()
    private var inFlightCount: Int = 0
    private var idleDeadline: Date?
    private var isUnloading = false
    private var isCancelled = false
    private var waiters: [@Sendable () -> Void] = []

    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var sleepObserverToken: NSObjectProtocol?

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        intervalProvider: @escaping @Sendable () -> Int = {
            SettingsStore.shared.privateAIIdleUnloadMinutes
        },
        onUnload: @escaping @Sendable (String) async -> Void,
        scheduler: PrivateAIIdleUnloadScheduling = DispatchTimerIdleScheduler(),
        installSystemMonitors: Bool = true
    ) {
        self.now = now
        self.intervalProvider = intervalProvider
        self.onUnload = onUnload
        self.scheduler = scheduler
        if installSystemMonitors {
            self.installMemoryPressureSource()
            self.installSleepObserver()
        }
    }

    deinit {
        self.memoryPressureSource?.cancel()
        if let token = self.sleepObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    // MARK: - Request lifecycle

    /// Register the start of a provider request. Awaits any in-progress unload
    /// so the provider call cannot interleave with `onUnload`. Always paired
    /// with `endRequest()` (typically via `defer`).
    func beginRequest() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if self.isUnloading {
                self.waiters.append(continuation.resume)
                self.lock.unlock()
                return
            }
            self.inFlightCount += 1
            self.lock.unlock()
            continuation.resume()
        }
    }

    /// Register the end of a provider request. When the last in-flight request
    /// ends, the idle countdown restarts.
    func endRequest() {
        let now = self.now()
        self.lock.lock()
        if self.inFlightCount > 0 {
            self.inFlightCount -= 1
        }
        if self.inFlightCount == 0, !self.isUnloading, !self.isCancelled {
            let interval = self.intervalSecondsLocked()
            self.rearmLocked(now: now, interval: interval)
            if interval > 0 {
                DebugLogger.shared.info(
                    "scheduled idle unload in \(self.minuteText(interval)) after last request",
                    source: Self.logSource
                )
            }
        }
        self.lock.unlock()
    }

    /// Re-arm the idle deadline from the current time. Called at the start of
    /// every load/enhance/prewarm so settings unload→reload sequences always
    /// restart the countdown. Also clears any prior `cancel()`.
    func noteActivity() {
        let now = self.now()
        self.lock.lock()
        self.isCancelled = false
        let interval = self.intervalSecondsLocked()
        self.rearmLocked(now: now, interval: interval)
        self.lock.unlock()
        if interval > 0 {
            DebugLogger.shared.info(
                "scheduled idle unload in \(self.minuteText(interval))",
                source: Self.logSource
            )
        }
    }

    /// Disarm the idle timer and suppress further automatic triggers until the
    /// next `noteActivity()`. Used by unload and termination paths so an unload
    /// cannot race with itself or fire during shutdown.
    func cancel() {
        self.lock.lock()
        self.isCancelled = true
        self.disarmLocked()
        self.lock.unlock()
        DebugLogger.shared.info("cancelled", source: Self.logSource)
    }

    // MARK: - Trigger entry points (timer / memory pressure / sleep)

    /// Invoked by the idle scheduler when the timer fires. Performs the
    /// deadline + in-flight check and, if idle, triggers the unload.
    func fireIdleDeadline() {
        let now = self.now()
        var shouldUnload = false

        self.lock.lock()
        if self.isCancelled || self.isUnloading {
            self.lock.unlock()
            return
        }
        let interval = self.intervalSecondsLocked()
        if interval <= 0 {
            self.disarmLocked()
            self.lock.unlock()
            return
        }
        if self.inFlightCount > 0 {
            self.rearmLocked(now: now, interval: interval)
            DebugLogger.shared.info(
                "skipped(in-flight) reason=\(PrivateAIIdleUnloadReason.idleTimeout) inFlight=\(self.inFlightCount)",
                source: Self.logSource
            )
            self.lock.unlock()
            return
        }
        guard let deadline = self.idleDeadline else {
            self.disarmLocked()
            self.lock.unlock()
            return
        }
        if now < deadline {
            // Early fire (clock skew or scheduler leeway): reschedule to the
            // remaining wall-clock gap rather than unloading prematurely.
            self.scheduler.scheduleIdleFire(after: deadline.timeIntervalSince(now)) { [weak self] in
                self?.fireIdleDeadline()
            }
            self.lock.unlock()
            return
        }
        self.isUnloading = true
        shouldUnload = true
        self.lock.unlock()

        guard shouldUnload else { return }
        DebugLogger.shared.info(
            "fired reason=\(PrivateAIIdleUnloadReason.idleTimeout)",
            source: Self.logSource
        )
        Task { [weak self] in
            await self?.performUnload(reason: PrivateAIIdleUnloadReason.idleTimeout)
        }
    }

    /// Invoked by the memory-pressure dispatch source. Fires regardless of the
    /// idle timer state, but still respects the in-flight guard and the
    /// "Never" (0 minute) opt-out.
    func handleMemoryPressure() {
        self.attemptSystemUnload(reason: PrivateAIIdleUnloadReason.memoryPressure)
    }

    /// Invoked by `NSWorkspace.willSleepNotification`. Unloads immediately when
    /// idle so the helper's memory is released before sleep.
    func handleSystemSleep() {
        self.attemptSystemUnload(reason: PrivateAIIdleUnloadReason.systemSleep)
    }

    // MARK: - Private

    private func attemptSystemUnload(reason: String) {
        self.lock.lock()
        if self.isCancelled || self.isUnloading || self.intervalSecondsLocked() <= 0 {
            self.lock.unlock()
            return
        }
        if self.inFlightCount > 0 {
            DebugLogger.shared.info(
                "skipped(in-flight) reason=\(reason) inFlight=\(self.inFlightCount)",
                source: Self.logSource
            )
            self.lock.unlock()
            return
        }
        self.isUnloading = true
        self.lock.unlock()

        DebugLogger.shared.info("fired reason=\(reason)", source: Self.logSource)
        Task { [weak self] in
            await self?.performUnload(reason: reason)
        }
    }

    private func performUnload(reason: String) async {
        await self.onUnload(reason)

        self.lock.lock()
        self.isUnloading = false
        let waitersToResume = self.waiters
        self.inFlightCount += waitersToResume.count
        self.waiters.removeAll()
        // The runtime is gone; clear any stale deadline until the next
        // noteActivity() restarts the countdown.
        self.disarmLocked()
        self.lock.unlock()

        for resume in waitersToResume {
            resume()
        }
    }

    private func rearmLocked(now: Date, interval: TimeInterval) {
        if interval <= 0 {
            self.disarmLocked()
            return
        }
        self.idleDeadline = now.addingTimeInterval(interval)
        self.scheduler.scheduleIdleFire(after: interval) { [weak self] in
            self?.fireIdleDeadline()
        }
    }

    private func disarmLocked() {
        self.idleDeadline = nil
        self.scheduler.cancelIdleFire()
    }

    private func intervalSecondsLocked() -> TimeInterval {
        let minutes = max(0, self.intervalProvider())
        return TimeInterval(minutes) * Self.secondsPerMinute
    }

    private func minuteText(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / Self.secondsPerMinute).rounded())
        return "\(minutes) min"
    }

    private func installMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: self.monitorQueue
        )
        source.setEventHandler { [weak self] in
            self?.handleMemoryPressure()
        }
        source.resume()
        self.memoryPressureSource = source
    }

    private func installSleepObserver() {
        self.sleepObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleSystemSleep()
        }
    }
}
