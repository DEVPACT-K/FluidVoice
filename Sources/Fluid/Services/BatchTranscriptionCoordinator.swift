import Combine
import Foundation

/// Sequentially transcribes a batch of audio files. All stored closures run on the main actor.
@MainActor
final class BatchTranscriptionCoordinator: ObservableObject {
    struct Request {
        let url: URL
        let stagingDir: URL? // exclusively owned by this item; deleted when it finishes, never shared

        init(url: URL, stagingDir: URL? = nil) {
            self.url = url
            self.stagingDir = stagingDir
        }
    }

    enum Status {
        case pending
        case transcribing
        case completed(TranscriptionResult)
        case noSpeech
        case failed(String)
        case cancelled
    }

    struct Item: Identifiable {
        let id: UUID
        let url: URL
        let stagingDir: URL? // exclusively owned by this item; deleted when it finishes, never shared
        var status: Status
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning: Bool = false

    private let transcribe: @MainActor (URL) async throws -> TranscriptionResult
    private let onBatchStart: @MainActor () -> Void
    private let onBatchEnd: @MainActor () -> Void

    private var batchTask: Task<Void, Never>?
    @Published private(set) var isCancelRequested: Bool = false // "Cancelling…" state: the in-flight item may still run to completion

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

    /// starts a sequential batch if idle, else appends to the live one
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

    /// cancels the in-flight transcription and every still-pending item; no-op when idle
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

            // Self-draining: items enqueued during cancellation/finish are still .pending and were missed above.
            if self.items.contains(where: { if case .pending = $0.status { return true } else { return false } }) {
                self.startBatch()
            } else {
                self.resumeIdleWaiters()
            }
        }
    }

    private func processBatch() async {
        while let index = self.nextPendingIndex() {
            if self.isCancelled { return }
            await self.processItem(at: index)
        }
    }

    private func nextPendingIndex() -> Int? {
        self.items.firstIndex { if case .pending = $0.status { return true } else { return false } }
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

        self.removeStagingDir(for: index) // only after the item finishes (success, failure, or cancellation)
    }

    private func removeStagingDir(for index: Int) {
        guard let stagingDir = self.items[index].stagingDir else { return }
        try? FileManager.default.removeItem(at: stagingDir)

        let parent = stagingDir.deletingLastPathComponent() // prune the now-empty drop-session root so drops don't leak temp shells
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
