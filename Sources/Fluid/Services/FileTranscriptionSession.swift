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

    /// True from the moment a dictation/prompt/command/rewrite recording is about to
    /// start until the session ends. This is the "intent to dictate" half of the
    /// single-model arbiter shared with the batch transcribe closure below: it is set
    /// synchronously on the main actor before any `await`, closing the TOCTOU window
    /// where the batch closure's `AppServices.shared.asr.isRunning` check could pass
    /// right before dictation flips `isRunning` true.
    ///
    /// Uses `sharedIfCreated` (not `shared`) so callers that only need to *read* the
    /// flag never force-create the session/ASR service. `beginDictationIntent()` is the
    /// one path allowed to force-create, since it's only called from the app's own
    /// recording start path where creating the session is expected anyway.
    private(set) var dictationIntent: Bool = false

    let service: MeetingTranscriptionService
    let batchHolder: BatchCoordinatorHolder

    private init() {
        let service = MeetingTranscriptionService(asrService: AppServices.shared.asr)
        self.service = service
        self.batchHolder = BatchCoordinatorHolder(transcribe: { url in
            // Single-model arbitration: at most one of dictation, single-file
            // transcription, and batch transcription may drive the shared ASR model at
            // once. Wait for dictation intent (covers the TOCTOU window before
            // AppServices.shared.asr.isRunning flips true), live dictation, and any
            // in-flight single-file transcription. Cancellation still interrupts the wait.
            while AppServices.shared.asr.isRunning
                || FileTranscriptionSession.shared.dictationIntent
                || service.isTranscribing {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            return try await service.transcribeFile(url)
        })
        Self.sharedIfCreated = self
    }

    /// Signal that a dictation-family recording (dictate/prompt/command/rewrite) is
    /// about to start. Must be called synchronously before any `await` in the caller.
    func beginDictationIntent() {
        self.dictationIntent = true
    }

    /// Signal that the dictation-family recording session has ended (stopped,
    /// cancelled, or failed to start).
    func endDictationIntent() {
        self.dictationIntent = false
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
