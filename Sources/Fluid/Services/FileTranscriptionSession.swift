import Combine
import Foundation

/// App-level owner of file-transcription state, so switching sidebar pages (which
/// destroys `MeetingTranscriptionView`) doesn't silently kill an in-flight batch;
/// the view re-attaches on return.
@MainActor
final class FileTranscriptionSession {
    static let shared = FileTranscriptionSession()

    /// Set once `shared` is first touched, so the dictation path can check batch state
    /// without force-creating the session (and the ASR service).
    private static var sharedIfCreated: FileTranscriptionSession?

    /// Dictation must not start while true: both paths drive the same shared ASR model,
    /// and concurrent inference corrupts output.
    static var isBatchTranscribing: Bool {
        self.sharedIfCreated?.batchHolder.coordinator?.isRunning == true
    }

    /// True from just before a dictation/prompt/command/rewrite recording starts until
    /// the session ends. The "intent to dictate" half of the single-model arbiter shared
    /// with the batch transcribe closure: set synchronously before any `await`, closing
    /// the TOCTOU window where the batch's `asr.isRunning` check could pass right before
    /// dictation flips `isRunning` true.
    ///
    /// Readers use `sharedIfCreated` to avoid force-creating the session/ASR service;
    /// `beginDictationIntent()` is the one path allowed to force-create.
    private(set) var dictationIntent: Bool = false

    let service: MeetingTranscriptionService
    let batchHolder: BatchCoordinatorHolder

    private init() {
        let service = MeetingTranscriptionService(asrService: AppServices.shared.asr)
        self.service = service
        self.batchHolder = BatchCoordinatorHolder(transcribe: { url in
            // Single-model arbitration: at most one of dictation, single-file, and batch
            // transcription may drive the shared ASR model at once. Waits on dictation
            // intent, live dictation, and any in-flight single-file transcription;
            // cancellation still interrupts the wait.
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

    /// Releases the flag without force-creating the session, for teardown paths.
    static func endDictationIntentIfCreated() {
        self.sharedIfCreated?.endDictationIntent()
    }
}

/// Wraps the batch coordinator so a finished batch can be cleared and a fresh one lazily
/// created, republishing the inner coordinator's changes.
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
        // Never orphan a running batch: dropping it without cancelling would leave it
        // transcribing invisibly with no way to reach it.
        self.coordinator?.cancel()
        self.forwarder?.cancel()
        self.forwarder = nil
        self.coordinator = nil
    }
}
