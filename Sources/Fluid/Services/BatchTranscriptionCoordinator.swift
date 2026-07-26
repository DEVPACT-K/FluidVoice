import Combine
import Foundation

/// Coordinates sequential transcription of a batch of audio files (issue #219).
///
/// The coordinator owns per-item state for multi-file transcription: strict sequential
/// processing in enqueue order, per-item success/failure/no-speech outcomes, cooperative
/// cancellation of the in-flight file, staging-directory cleanup after each item finishes,
/// and batch start/end hooks for dictation arbitration. All stored closures are invoked on
/// the main actor.
@MainActor
final class BatchTranscriptionCoordinator: ObservableObject {
    /// A transcription request for a single audio file.
    struct Request {
        let url: URL
        let stagingDir: URL?

        init(url: URL, stagingDir: URL? = nil) {
            self.url = url
            self.stagingDir = stagingDir
        }
    }

    /// Per-item transcription outcome.
    enum Status {
        case pending
        case transcribing
        case completed(TranscriptionResult)
        case noSpeech
        case failed(String)
        case cancelled
    }

    /// Tracked state for a single enqueued file.
    struct Item: Identifiable {
        let id: UUID
        let url: URL
        let stagingDir: URL?
        var status: Status
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning: Bool = false

    private let transcribe: @MainActor (URL) async throws -> TranscriptionResult
    private let onBatchStart: @MainActor () -> Void
    private let onBatchEnd: @MainActor () -> Void

    private var batchTask: Task<Void, Never>?
    /// Published so the UI can show a "Cancelling…" state: pending items stop
    /// immediately, but the in-flight item may run to completion (the native
    /// provider transcription has no interruption point).
    @Published private(set) var isCancelRequested: Bool = false

    private var isCancelled: Bool = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        transcribe: @escaping @MainActor (URL) async throws -> TranscriptionResult,
        onBatchStart: @escaping @MainActor () -> Void = {},
        onBatchEnd: @escaping @MainActor () -> Void = {}
    ) {
        self.transcribe = transcribe
        self.onBatchStart = onBatchStart
        self.onBatchEnd = onBatchEnd
    }

    // MARK: - Enqueue

    /// Append requests and start a sequential processing batch if idle. Enqueuing while a
    /// batch is running appends to the live batch.
    func enqueue(_ requests: [Request]) {
        for request in requests {
            self.items.append(
                Item(
                    id: UUID(),
                    url: request.url,
                    stagingDir: request.stagingDir,
                    status: .pending
                )
            )
        }

        if self.batchTask == nil {
            self.startBatch()
        }
    }

    // MARK: - Cancellation

    /// Cancel the in-flight transcription and every still-pending item. No-op when idle.
    func cancel() {
        guard self.batchTask != nil else { return }

        self.isCancelled = true
        self.isCancelRequested = true

        for index in 0..<self.items.count {
            if case .pending = self.items[index].status {
                self.items[index].status = .cancelled
                self.removeStagingDir(for: index)
            }
        }

        self.batchTask?.cancel()
    }

    // MARK: - Idle wait

    /// Returns when no batch is processing. Used by tests and callers that need to await
    /// the full run.
    func waitUntilIdle() async {
        if !self.isRunning { return }

        await withCheckedContinuation { continuation in
            self.idleWaiters.append(continuation)
        }
    }

    // MARK: - Summary

    var completedCount: Int {
        self.items.reduce(into: 0) { count, item in
            if case .completed = item.status { count += 1 }
        }
    }

    var failedCount: Int {
        self.items.reduce(into: 0) { count, item in
            if case .failed = item.status { count += 1 }
        }
    }

    var noSpeechCount: Int {
        self.items.reduce(into: 0) { count, item in
            if case .noSpeech = item.status { count += 1 }
        }
    }

    // MARK: - Batch processing

    private func startBatch() {
        self.isCancelled = false
        self.isCancelRequested = false
        self.isRunning = true

        self.batchTask = Task { @MainActor [weak self] in
            guard let self else { return }

            self.onBatchStart()
            await self.processBatch()
            self.onBatchEnd()

            self.isRunning = false
            self.batchTask = nil
            self.resumeIdleWaiters()
        }
    }

    private func processBatch() async {
        var index = 0
        while index < self.items.count {
            if self.isCancelled { return }
            await self.processItem(at: index)
            index += 1
        }
    }

    private func processItem(at index: Int) async {
        self.items[index].status = .transcribing

        let url = self.items[index].url

        do {
            let result = try await self.transcribe(url)

            if self.isCancelled {
                self.items[index].status = .cancelled
            } else if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.items[index].status = .noSpeech
            } else {
                self.items[index].status = .completed(result)
            }
        } catch is CancellationError {
            self.items[index].status = .cancelled
        } catch {
            if self.isCancelled {
                self.items[index].status = .cancelled
            } else {
                self.items[index].status = .failed(error.localizedDescription)
            }
        }

        // Staging dirs are owned by the coordinator and removed only after the item has
        // finished transcribing (success, failure, or cancellation) — never before/during.
        self.removeStagingDir(for: index)
    }

    private func removeStagingDir(for index: Int) {
        guard let stagingDir = self.items[index].stagingDir else { return }
        try? FileManager.default.removeItem(at: stagingDir)

        // Per-item staging dirs live inside a drop-session root (see
        // PromiseDropSupport.StagingSession). Once the last item dir is gone,
        // remove the now-empty session root so drops don't leak temp shells.
        let parent = stagingDir.deletingLastPathComponent()
        guard parent.lastPathComponent.hasPrefix(PromiseDropSupport.stagingRootPrefix),
              let remaining = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
              remaining.isEmpty else { return }
        try? FileManager.default.removeItem(at: parent)
    }

    private func resumeIdleWaiters() {
        let waiters = self.idleWaiters
        self.idleWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}
