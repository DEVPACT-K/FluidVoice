import Combine
import Foundation

/// App-level owner of file-transcription state (issue #219).
///
/// The transcription service and batch coordinator used to be `@StateObject`s
/// of `MeetingTranscriptionView`, so switching sidebar pages destroyed the view
/// and silently killed any in-flight transcription. Owning them here keeps
/// batches running while the user navigates; the view re-attaches on return.
@MainActor
final class FileTranscriptionSession {
    static let shared = FileTranscriptionSession()

    /// Set once `shared` is first touched. Lets the dictation path check batch
    /// state without lazily constructing the session (and the ASR service).
    private static var sharedIfCreated: FileTranscriptionSession?

    /// True while a batch is actively transcribing. Dictation must not start
    /// concurrently: both paths drive the same shared ASR model, and
    /// concurrent inference corrupts output.
    static var isBatchTranscribing: Bool {
        self.sharedIfCreated?.batchHolder.coordinator?.isRunning == true
    }

    let service: MeetingTranscriptionService
    let batchHolder: BatchCoordinatorHolder

    private init() {
        let service = MeetingTranscriptionService(asrService: AppServices.shared.asr)
        self.service = service
        self.batchHolder = BatchCoordinatorHolder(transcribe: { url in
            // Batch-vs-dictation arbitration: if the user is dictating, wait for
            // the live session to finish before running this item through the
            // shared model. Cancellation still interrupts the wait.
            while AppServices.shared.asr.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            return try await service.transcribeFile(url)
        })
        Self.sharedIfCreated = self
    }
}

/// Wraps the batch coordinator so a finished batch can be cleared and a fresh
/// one lazily created, while republshing the inner coordinator's changes.
@MainActor
final class BatchCoordinatorHolder: ObservableObject {
    @Published var coordinator: BatchTranscriptionCoordinator?

    private let transcribe: @MainActor (URL) async throws -> TranscriptionResult
    private var forwarder: AnyCancellable?

    init(transcribe: @escaping @MainActor (URL) async throws -> TranscriptionResult) {
        self.transcribe = transcribe
    }

    func enqueue(_ requests: [BatchTranscriptionCoordinator.Request]) {
        if self.coordinator == nil {
            let coordinator = BatchTranscriptionCoordinator(transcribe: self.transcribe)
            self.forwarder = coordinator.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
            self.coordinator = coordinator
        }
        self.coordinator?.enqueue(requests)
    }

    func clear() {
        // Never orphan a running batch: without this, dropping the coordinator
        // would leave it transcribing invisibly with no way to reach it.
        self.coordinator?.cancel()
        self.forwarder?.cancel()
        self.forwarder = nil
        self.coordinator = nil
    }
}
