@testable import FluidVoice_Debug
import Foundation
import XCTest

final class PrivateAIIdleUnloadCoordinatorTests: XCTestCase {
    // MARK: - (a) Fires after the idle deadline

    func testFiresAfterDeadline() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000))
        let interval = FakeInterval(5)
        let scheduler = FakeIdleScheduler()
        let recorder = UnloadRecorder()
        let coordinator = makeCoordinator(
            clock: clock,
            interval: interval,
            scheduler: scheduler,
            recorder: recorder
        )

        coordinator.noteActivity()
        XCTAssertNotNil(scheduler.lastScheduledDelay)
        XCTAssertEqual(scheduler.lastScheduledDelay, 300)

        clock.advance(301)
        scheduler.fire()

        let reason = await recorder.waitForReason()
        XCTAssertEqual(reason, PrivateAIIdleUnloadReason.idleTimeout)
    }

    // MARK: - (b) noteActivity resets the deadline

    func testNoteActivityResetsDeadline() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000))
        let interval = FakeInterval(5)
        let scheduler = FakeIdleScheduler()
        let recorder = UnloadRecorder()
        let coordinator = makeCoordinator(
            clock: clock,
            interval: interval,
            scheduler: scheduler,
            recorder: recorder
        )

        coordinator.noteActivity() // deadline = t0 + 300
        clock.advance(240)
        coordinator.noteActivity() // deadline = t0 + 240 + 300 = t0 + 540

        clock.advance(120) // now = t0 + 360, before the reset deadline
        scheduler.fire()
        let noUnload = await recorder.waitForReason(timeoutSeconds: 0.2)
        XCTAssertNil(noUnload, "Unload should not fire before the reset deadline")

        clock.advance(200) // now = t0 + 560, past the reset deadline
        scheduler.fire()
        let reason = await recorder.waitForReason()
        XCTAssertEqual(reason, PrivateAIIdleUnloadReason.idleTimeout)
    }

    // MARK: - (c) Does not fire while in-flight; re-arms after endRequest

    func testDoesNotFireWhileInFlightAndRearmsAfterEndRequest() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000))
        let interval = FakeInterval(5)
        let scheduler = FakeIdleScheduler()
        let recorder = UnloadRecorder()
        let coordinator = makeCoordinator(
            clock: clock,
            interval: interval,
            scheduler: scheduler,
            recorder: recorder
        )

        coordinator.noteActivity() // deadline = t0 + 300
        await coordinator.beginRequest()

        clock.advance(301) // past the deadline, but a request is in flight
        scheduler.fire()
        let noUnload = await recorder.waitForReason(timeoutSeconds: 0.2)
        XCTAssertNil(noUnload, "Unload must not fire while a request is in flight")

        coordinator.endRequest() // counter -> 0, re-arm deadline = t0 + 301 + 300
        clock.advance(301) // past the re-armed deadline
        scheduler.fire()
        let reason = await recorder.waitForReason()
        XCTAssertEqual(reason, PrivateAIIdleUnloadReason.idleTimeout)
    }

    // MARK: - (d) Throw/cancellation still balances the counter

    func testBeginAndDeferEndBalancesCounter() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000))
        let interval = FakeInterval(5)
        let scheduler = FakeIdleScheduler()
        let recorder = UnloadRecorder()
        let coordinator = makeCoordinator(
            clock: clock,
            interval: interval,
            scheduler: scheduler,
            recorder: recorder
        )

        coordinator.noteActivity()
        // Simulate a throwing/cancelled provider call: begin, then the deferred
        // end runs without a successful completion.
        await coordinator.beginRequest()
        coordinator.endRequest() // the `defer { endRequest() }` path

        // If the counter were not balanced, the fire below would skip as
        // in-flight. Because it unloads, the counter must be 0.
        clock.advance(301)
        scheduler.fire()
        let reason = await recorder.waitForReason()
        XCTAssertEqual(reason, PrivateAIIdleUnloadReason.idleTimeout)
    }

    // MARK: - (e) 0 / Never never fires

    func testNeverIntervalNeverFires() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000))
        let interval = FakeInterval(0)
        let scheduler = FakeIdleScheduler()
        let recorder = UnloadRecorder()
        let coordinator = makeCoordinator(
            clock: clock,
            interval: interval,
            scheduler: scheduler,
            recorder: recorder
        )

        coordinator.noteActivity()
        XCTAssertFalse(scheduler.hasPendingFire, "Never must not schedule an idle fire")
        XCTAssertEqual(scheduler.scheduleCount, 0)

        clock.advance(3_600)
        scheduler.fire() // nothing scheduled; fire is a no-op
        coordinator.handleMemoryPressure()
        coordinator.handleSystemSleep()

        let noUnload = await recorder.waitForReason(timeoutSeconds: 0.2)
        XCTAssertNil(noUnload, "Never must suppress all automatic unload triggers")
    }

    // MARK: - (f) Unload cancels, and a subsequent load re-arms

    func testUnloadCancelsAndSubsequentLoadRearms() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000))
        let interval = FakeInterval(5)
        let scheduler = FakeIdleScheduler()
        let recorder = UnloadRecorder()
        let coordinator = makeCoordinator(
            clock: clock,
            interval: interval,
            scheduler: scheduler,
            recorder: recorder
        )

        coordinator.noteActivity()
        clock.advance(301)
        scheduler.fire() // idle unload -> onUnload cancels the coordinator
        let first = await recorder.waitForReason()
        XCTAssertEqual(first, PrivateAIIdleUnloadReason.idleTimeout)
        await Task.yield()
        XCTAssertFalse(scheduler.hasPendingFire, "Unload must disarm the idle timer")

        // Simulate a new load: begin + noteActivity re-arms despite the prior cancel.
        await coordinator.beginRequest()
        coordinator.noteActivity()
        XCTAssertTrue(scheduler.hasPendingFire, "A load must re-arm the idle timer")
        coordinator.endRequest()

        clock.advance(301)
        scheduler.fire()
        let second = await recorder.waitForReason()
        XCTAssertEqual(second, PrivateAIIdleUnloadReason.idleTimeout)
        XCTAssertEqual(recorder.recordedReasons.count, 2)
    }

    // MARK: - (g) Memory pressure invokes unload immediately when idle

    func testMemoryPressureUnloadsImmediatelyWhenIdle() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000))
        let interval = FakeInterval(5)
        let scheduler = FakeIdleScheduler()
        let recorder = UnloadRecorder()
        let coordinator = makeCoordinator(
            clock: clock,
            interval: interval,
            scheduler: scheduler,
            recorder: recorder
        )

        coordinator.noteActivity() // deadline = t0 + 5
        // Do NOT advance the clock: memory pressure fires regardless of timer.
        coordinator.handleMemoryPressure()
        let reason = await recorder.waitForReason()
        XCTAssertEqual(reason, PrivateAIIdleUnloadReason.memoryPressure)
    }

    func testMemoryPressureSkipsWhileInFlight() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000))
        let interval = FakeInterval(5)
        let scheduler = FakeIdleScheduler()
        let recorder = UnloadRecorder()
        let coordinator = makeCoordinator(
            clock: clock,
            interval: interval,
            scheduler: scheduler,
            recorder: recorder
        )

        coordinator.noteActivity()
        await coordinator.beginRequest()
        coordinator.handleMemoryPressure()
        let noUnload = await recorder.waitForReason(timeoutSeconds: 0.2)
        XCTAssertNil(noUnload, "Memory pressure must not unload while a request is in flight")
        coordinator.endRequest()
    }

    // MARK: - Mutual exclusion: beginRequest waits for an in-progress unload

    func testBeginRequestWaitsForInProgressUnload() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000))
        let interval = FakeInterval(5)
        let scheduler = FakeIdleScheduler()
        let recorder = UnloadRecorder()
        let gate = AsyncGate()
        let coordinator = makeCoordinator(
            clock: clock,
            interval: interval,
            scheduler: scheduler,
            recorder: recorder,
            onUnload: { reason in
                await recorder.record(reason)
                await gate.wait() // hold the unload open so isUnloading stays true
            }
        )

        coordinator.noteActivity()
        clock.advance(301)
        scheduler.fire() // idle unload -> onUnload records then parks at the gate

        let first = await recorder.waitForReason()
        XCTAssertEqual(first, PrivateAIIdleUnloadReason.idleTimeout)

        // A new request arriving mid-unload must wait, not interleave.
        let began = Flag()
        let beginTask = Task {
            await coordinator.beginRequest()
            began.set()
        }
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(began.isSet, "beginRequest must wait while an unload is in progress")

        gate.signal() // release the unload; performUnload clears isUnloading
        await beginTask.value
        XCTAssertTrue(began.isSet, "beginRequest resumes after the unload completes")
        coordinator.endRequest()
    }

    // MARK: - Helpers

    private func makeCoordinator(
        clock: FakeClock,
        interval: FakeInterval,
        scheduler: FakeIdleScheduler,
        recorder: UnloadRecorder,
        onUnload: (@Sendable (String) async -> Void)? = nil
    ) -> PrivateAIIdleUnloadCoordinator {
        let ref = CoordinatorRef()
        let unload: @Sendable (String) async -> Void
        if let onUnload {
            unload = onUnload
        } else {
            // Mirror the real wiring: unloadCachedRuntime cancels the coordinator
            // before delegating, so the test callback cancels first too.
            unload = { reason in
                ref.coordinator?.cancel()
                await recorder.record(reason)
            }
        }
        let coordinator = PrivateAIIdleUnloadCoordinator(
            now: { clock.now() },
            intervalProvider: { interval.value },
            onUnload: unload,
            scheduler: scheduler,
            installSystemMonitors: false
        )
        ref.coordinator = coordinator
        return coordinator
    }
}

// MARK: - Test doubles

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        self.current = date
    }

    func advance(_ seconds: TimeInterval) {
        self.lock.lock()
        self.current = self.current.addingTimeInterval(seconds)
        self.lock.unlock()
    }

    func now() -> Date {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.current
    }
}

private final class FakeInterval: @unchecked Sendable {
    private let lock = NSLock()
    private var minutes: Int

    init(_ minutes: Int) {
        self.minutes = minutes
    }

    var value: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.minutes
    }

    func set(_ minutes: Int) {
        self.lock.lock()
        self.minutes = minutes
        self.lock.unlock()
    }
}

private final class FakeIdleScheduler: PrivateAIIdleUnloadScheduling {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private(set) var lastScheduledDelay: TimeInterval?
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0

    func scheduleIdleFire(after delay: TimeInterval, action: @escaping @Sendable () -> Void) {
        self.lock.lock()
        self.action = action
        self.lastScheduledDelay = delay
        self.scheduleCount += 1
        self.lock.unlock()
    }

    func cancelIdleFire() {
        self.lock.lock()
        self.action = nil
        self.cancelCount += 1
        self.lock.unlock()
    }

    var hasPendingFire: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.action != nil
    }

    /// Invoke the currently scheduled fire once (consumes the action).
    func fire() {
        self.lock.lock()
        let action = self.action
        self.action = nil
        self.lock.unlock()
        action?()
    }
}

private final class UnloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [String] = []
    private var generation = 0
    private var pending: (generation: Int, continuation: CheckedContinuation<String?, Never>)?

    func record(_ reason: String) async {
        let waiter = self.appendAndDequeue(reason)
        if let waiter {
            waiter.continuation.resume(returning: reason)
        }
    }

    var recordedReasons: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.reasons
    }

    var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.reasons.count
    }

    /// Await the next recorded unload reason, or `nil` if none arrives within
    /// `timeoutSeconds`.
    func waitForReason(timeoutSeconds: TimeInterval = 5) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            self.lock.lock()
            self.generation += 1
            let generation = self.generation
            self.pending = (generation, continuation)
            self.lock.unlock()

            Task { @Sendable [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                self?.timeoutResume(generation: generation, continuation: continuation)
            }
        }
    }

    private func appendAndDequeue(_ reason: String) -> (generation: Int, continuation: CheckedContinuation<String?, Never>)? {
        self.lock.lock()
        self.reasons.append(reason)
        let waiter = self.pending
        self.pending = nil
        self.lock.unlock()
        return waiter
    }

    private func timeoutResume(generation: Int, continuation: CheckedContinuation<String?, Never>) {
        self.lock.lock()
        let shouldResume: Bool
        if let pending = self.pending, pending.generation == generation {
            self.pending = nil
            shouldResume = true
        } else {
            shouldResume = false
        }
        self.lock.unlock()
        if shouldResume {
            continuation.resume(returning: nil)
        }
    }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isSignalled = false

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if self.isSignalled {
                self.isSignalled = false
                self.lock.unlock()
                cont.resume()
                return
            }
            self.continuation = cont
            self.lock.unlock()
        }
    }

    func signal() {
        self.lock.lock()
        let cont = self.continuation
        self.continuation = nil
        if cont == nil {
            self.isSignalled = true
        }
        self.lock.unlock()
        cont?.resume()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        self.lock.lock()
        self.value = true
        self.lock.unlock()
    }

    var isSet: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }
}

/// Weak holder so the default `onUnload` can cancel the coordinator it is
/// handed to (mirroring production, where `unloadCachedRuntime` cancels first).
private final class CoordinatorRef: @unchecked Sendable {
    weak var coordinator: PrivateAIIdleUnloadCoordinator?
}
