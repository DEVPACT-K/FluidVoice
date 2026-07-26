@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Contract tests for BatchTranscriptionCoordinator (issue #219 batch transcription).
/// The coordinator owns per-item state for multi-file transcription: sequential
/// processing, per-item success/failure, cancellation, staging-dir cleanup, and
/// batch start/end hooks for dictation arbitration.
@MainActor
final class BatchTranscriptionCoordinatorTests: XCTestCase {
    private func makeResult(text: String, fileName: String = "test.m4a") -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            confidence: 0.9,
            duration: 1.0,
            processingTime: 0.1,
            fileName: fileName
        )
    }

    private func tempAudioURL(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    // MARK: - Sequential processing & ordering

    func testProcessesFilesSequentiallyInOrder() async {
        var transcribedPaths: [String] = []
        var concurrent = 0
        var maxConcurrent = 0

        let coordinator = BatchTranscriptionCoordinator(transcribe: { url in
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
            try? await Task.sleep(nanoseconds: 20_000_000)
            transcribedPaths.append(url.lastPathComponent)
            concurrent -= 1
            return self.makeResult(text: "text for \(url.lastPathComponent)", fileName: url.lastPathComponent)
        })

        let urls = ["a.m4a", "b.m4a", "c.m4a"].map { self.tempAudioURL(name: $0) }
        coordinator.enqueue(urls.map { BatchTranscriptionCoordinator.Request(url: $0) })
        await coordinator.waitUntilIdle()

        XCTAssertEqual(transcribedPaths, ["a.m4a", "b.m4a", "c.m4a"], "files must process in enqueue order")
        XCTAssertEqual(maxConcurrent, 1, "batch must never transcribe two files concurrently")
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(coordinator.items.count, 3)
        for item in coordinator.items {
            guard case let .completed(result) = item.status else {
                return XCTFail("expected .completed, got \(item.status)")
            }
            XCTAssertEqual(result.text, "text for \(item.url.lastPathComponent)")
        }
    }

    func testIsRunningTrueWhileProcessing() async {
        let gate = AsyncGate()
        let coordinator = BatchTranscriptionCoordinator(transcribe: { url in
            await gate.wait()
            return self.makeResult(text: "done", fileName: url.lastPathComponent)
        })

        coordinator.enqueue([.init(url: self.tempAudioURL(name: "a.m4a"))])
        // Let the processing task start.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(coordinator.isRunning)
        if case .transcribing = coordinator.items[0].status {} else {
            XCTFail("expected first item to be .transcribing, got \(coordinator.items[0].status)")
        }

        gate.open()
        await coordinator.waitUntilIdle()
        XCTAssertFalse(coordinator.isRunning)
    }

    // MARK: - Per-item failure isolation

    func testFailedItemDoesNotStopBatch() async {
        let coordinator = BatchTranscriptionCoordinator(transcribe: { url in
            if url.lastPathComponent == "bad.m4a" {
                throw MeetingTranscriptionService.TranscriptionError.transcriptionFailed("decode blew up")
            }
            return self.makeResult(text: "ok", fileName: url.lastPathComponent)
        })

        coordinator.enqueue([
            .init(url: self.tempAudioURL(name: "good1.m4a")),
            .init(url: self.tempAudioURL(name: "bad.m4a")),
            .init(url: self.tempAudioURL(name: "good2.m4a")),
        ])
        await coordinator.waitUntilIdle()

        guard case .completed = coordinator.items[0].status else {
            return XCTFail("item 0 should complete, got \(coordinator.items[0].status)")
        }
        guard case let .failed(message) = coordinator.items[1].status else {
            return XCTFail("item 1 should fail, got \(coordinator.items[1].status)")
        }
        XCTAssertTrue(message.contains("decode blew up"), "failure must preserve the underlying error message")
        guard case .completed = coordinator.items[2].status else {
            return XCTFail("item 2 should still complete after a failure, got \(coordinator.items[2].status)")
        }
    }

    // MARK: - Empty transcription

    func testEmptyTranscriptionMarksNoSpeech() async {
        let coordinator = BatchTranscriptionCoordinator(transcribe: { url in
            self.makeResult(text: "   ", fileName: url.lastPathComponent)
        })

        coordinator.enqueue([.init(url: self.tempAudioURL(name: "silent.m4a"))])
        await coordinator.waitUntilIdle()

        guard case .noSpeech = coordinator.items[0].status else {
            return XCTFail("whitespace-only transcription must surface as .noSpeech, got \(coordinator.items[0].status)")
        }
    }

    // MARK: - Cancellation

    func testCancelStopsCurrentItemAndPendingItems() async {
        let started = AsyncGate()
        let coordinator = BatchTranscriptionCoordinator(transcribe: { url in
            started.open()
            // Simulate a long transcription that honors Task cancellation.
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return self.makeResult(text: "should never finish", fileName: url.lastPathComponent)
        })

        coordinator.enqueue([
            .init(url: self.tempAudioURL(name: "current.m4a")),
            .init(url: self.tempAudioURL(name: "pending1.m4a")),
            .init(url: self.tempAudioURL(name: "pending2.m4a")),
        ])
        await started.wait()
        coordinator.cancel()
        await coordinator.waitUntilIdle()

        XCTAssertFalse(coordinator.isRunning)
        guard case .cancelled = coordinator.items[0].status else {
            return XCTFail("in-flight item must be .cancelled, not \(coordinator.items[0].status)")
        }
        guard case .cancelled = coordinator.items[1].status else {
            return XCTFail("pending items must be .cancelled, not \(coordinator.items[1].status)")
        }
        guard case .cancelled = coordinator.items[2].status else {
            return XCTFail("pending items must be .cancelled, not \(coordinator.items[2].status)")
        }
    }

    func testEnqueueAfterCancelStartsFreshBatch() async {
        let coordinator = BatchTranscriptionCoordinator(transcribe: { url in
            self.makeResult(text: "ok", fileName: url.lastPathComponent)
        })
        coordinator.cancel() // cancel with nothing running must be a no-op

        coordinator.enqueue([.init(url: self.tempAudioURL(name: "after.m4a"))])
        await coordinator.waitUntilIdle()

        guard case .completed = coordinator.items.last!.status else {
            return XCTFail("batch must run normally after a cancel, got \(coordinator.items.last!.status)")
        }
    }

    // MARK: - Staging directory cleanup

    func testStagingDirRemovedAfterItemFinishes() async throws {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let audioURL = stagingDir.appendingPathComponent("memo.m4a")
        try Data([0x00]).write(to: audioURL)

        var existedDuringTranscription = false
        let coordinator = BatchTranscriptionCoordinator(transcribe: { url in
            existedDuringTranscription = fm.fileExists(atPath: url.path)
            return self.makeResult(text: "ok", fileName: url.lastPathComponent)
        })

        coordinator.enqueue([.init(url: audioURL, stagingDir: stagingDir)])
        await coordinator.waitUntilIdle()

        XCTAssertTrue(existedDuringTranscription, "staged file must exist for the whole transcription")
        XCTAssertFalse(fm.fileExists(atPath: stagingDir.path), "staging dir must be deleted after the item finishes")
    }

    func testStagingDirRemovedEvenWhenItemFails() async throws {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let audioURL = stagingDir.appendingPathComponent("memo.m4a")
        try Data([0x00]).write(to: audioURL)

        let coordinator = BatchTranscriptionCoordinator(transcribe: { _ in
            throw MeetingTranscriptionService.TranscriptionError.transcriptionFailed("nope")
        })

        coordinator.enqueue([.init(url: audioURL, stagingDir: stagingDir)])
        await coordinator.waitUntilIdle()

        XCTAssertFalse(fm.fileExists(atPath: stagingDir.path), "staging dir must be deleted even on failure")
    }

    func testEmptySessionRootPrunedAfterLastItemCleanup() async throws {
        let fm = FileManager.default
        let sessionRoot = fm.temporaryDirectory.appendingPathComponent("PromiseDrop-\(UUID().uuidString)", isDirectory: true)
        let stagingDir = sessionRoot.appendingPathComponent("item-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let audioURL = stagingDir.appendingPathComponent("memo.m4a")
        try Data([0x00]).write(to: audioURL)

        let coordinator = BatchTranscriptionCoordinator(transcribe: { url in
            self.makeResult(text: "ok", fileName: url.lastPathComponent)
        })

        coordinator.enqueue([.init(url: audioURL, stagingDir: stagingDir)])
        await coordinator.waitUntilIdle()

        XCTAssertFalse(
            fm.fileExists(atPath: sessionRoot.path),
            "an empty PromiseDrop- session root must be pruned once its last item dir is cleaned"
        )
    }

    func testNonPromiseParentDirectoryIsNotPruned() async throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent("user-folder-\(UUID().uuidString)", isDirectory: true)
        let stagingDir = parent.appendingPathComponent("item-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let audioURL = stagingDir.appendingPathComponent("memo.m4a")
        try Data([0x00]).write(to: audioURL)
        defer { try? fm.removeItem(at: parent) }

        let coordinator = BatchTranscriptionCoordinator(transcribe: { url in
            self.makeResult(text: "ok", fileName: url.lastPathComponent)
        })

        coordinator.enqueue([.init(url: audioURL, stagingDir: stagingDir)])
        await coordinator.waitUntilIdle()

        XCTAssertTrue(
            fm.fileExists(atPath: parent.path),
            "only PromiseDrop- session roots may be pruned; other parent dirs must be left alone"
        )
    }

    func testNonStagedFileIsNeverDeleted() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("user-files-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let audioURL = dir.appendingPathComponent("user-owned.m4a")
        try Data([0x00]).write(to: audioURL)
        defer { try? fm.removeItem(at: dir) }

        let coordinator = BatchTranscriptionCoordinator(transcribe: { url in
            self.makeResult(text: "ok", fileName: url.lastPathComponent)
        })

        coordinator.enqueue([.init(url: audioURL)]) // no stagingDir: user's own file
        await coordinator.waitUntilIdle()

        XCTAssertTrue(fm.fileExists(atPath: audioURL.path), "files without a stagingDir belong to the user and must never be deleted")
    }

    // MARK: - Enqueue while running

    func testEnqueueWhileRunningAppendsToSameBatch() async {
        let firstStarted = AsyncGate()
        let releaseFirst = AsyncGate()
        var order: [String] = []

        let coordinator = BatchTranscriptionCoordinator(transcribe: { url in
            if url.lastPathComponent == "first.m4a" {
                firstStarted.open()
                await releaseFirst.wait()
            }
            order.append(url.lastPathComponent)
            return self.makeResult(text: "ok", fileName: url.lastPathComponent)
        })

        coordinator.enqueue([.init(url: self.tempAudioURL(name: "first.m4a"))])
        await firstStarted.wait()
        coordinator.enqueue([.init(url: self.tempAudioURL(name: "second.m4a"))])
        releaseFirst.open()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(order, ["first.m4a", "second.m4a"])
        XCTAssertEqual(coordinator.items.count, 2)
        XCTAssertFalse(coordinator.isRunning)
    }

    // MARK: - Batch lifecycle hooks (dictation arbitration)

    func testBatchStartAndEndHooksWrapTheWholeRun() async {
        var events: [String] = []
        let coordinator = BatchTranscriptionCoordinator(
            transcribe: { url in
                events.append("transcribe \(url.lastPathComponent)")
                return self.makeResult(text: "ok", fileName: url.lastPathComponent)
            },
            onBatchStart: { events.append("start") },
            onBatchEnd: { events.append("end") }
        )

        coordinator.enqueue([
            .init(url: self.tempAudioURL(name: "a.m4a")),
            .init(url: self.tempAudioURL(name: "b.m4a")),
        ])
        await coordinator.waitUntilIdle()

        XCTAssertEqual(
            events,
            ["start", "transcribe a.m4a", "transcribe b.m4a", "end"],
            "start/end hooks must fire exactly once around the whole batch, not per item"
        )
    }

    func testBatchEndHookFiresOnCancel() async {
        var endCount = 0
        let started = AsyncGate()
        let coordinator = BatchTranscriptionCoordinator(
            transcribe: { url in
                started.open()
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return self.makeResult(text: "ok", fileName: url.lastPathComponent)
            },
            onBatchEnd: { endCount += 1 }
        )

        coordinator.enqueue([.init(url: self.tempAudioURL(name: "a.m4a"))])
        await started.wait()
        coordinator.cancel()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(endCount, 1, "the end hook must fire even when the batch is cancelled, or dictation stays blocked forever")
    }

    // MARK: - Summary

    func testSummaryCountsReflectOutcomes() async {
        let coordinator = BatchTranscriptionCoordinator(transcribe: { url in
            switch url.lastPathComponent {
            case "bad.m4a": throw MeetingTranscriptionService.TranscriptionError.transcriptionFailed("x")
            case "silent.m4a": return self.makeResult(text: "", fileName: url.lastPathComponent)
            default: return self.makeResult(text: "ok", fileName: url.lastPathComponent)
            }
        })

        coordinator.enqueue([
            .init(url: self.tempAudioURL(name: "good.m4a")),
            .init(url: self.tempAudioURL(name: "bad.m4a")),
            .init(url: self.tempAudioURL(name: "silent.m4a")),
        ])
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.completedCount, 1)
        XCTAssertEqual(coordinator.failedCount, 1)
        XCTAssertEqual(coordinator.noSpeechCount, 1)
    }
}

/// Minimal async gate for coordinating fake transcriptions in tests.
@MainActor
private final class AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func open() {
        self.isOpen = true
        let waiters = self.continuations
        self.continuations = []
        for c in waiters { c.resume() }
    }

    func wait() async {
        if self.isOpen { return }
        await withCheckedContinuation { self.continuations.append($0) }
    }
}
